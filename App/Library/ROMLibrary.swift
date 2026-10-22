import Foundation
import Combine

// MARK: - Entries

/// One ROM file in Documents/ROMs as shown in the library list.
struct ROMEntry: Identifiable, Hashable {
    let url: URL
    let fileSize: Int64
    /// Slot-0 auto-suspend state exists, so launching resumes where the player left off.
    let hasSuspendState: Bool
    /// A battery save (.srm) exists.
    let hasSRAM: Bool
    /// Console the ROM is for; nil if it can't be told (e.g. a zip with no known ROM inside).
    let system: GameSystem?
    /// When the game was last started from the library, if ever.
    var lastPlayed: Date? = nil

    var id: URL { url }
    /// Identity for the Recently Played section, so a game listed there and in the full list
    /// isn't two rows with one id.
    var recentID: String { "recent:" + url.path }
    var fileName: String { url.lastPathComponent }
    var title: String { ROMEntry.cleanTitle(for: url) }
    var fileExtension: String { url.pathExtension.uppercased() }

    /// File name without extension and without GoodTools-style dump tags such as "[!]" or
    /// "[h1C]". Region / language tags in parentheses, e.g. "(USA)", are kept.
    static func cleanTitle(for url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        name = name.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: "_", with: " ")
        name = name.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? url.deletingPathExtension().lastPathComponent : name
    }
}

// MARK: - Library

/// Owns the ROM list: scanning, importing, deleting and renaming files under GamePaths.
/// Main-thread only. Watches the ROMs folder so files added through the Files app or Finder
/// appear without a manual refresh.
final class ROMLibrary: ObservableObject {
    struct ImportReport {
        var imported: [URL] = []
        var duplicates: [String] = []
        var unsupported: [String] = []
        var failed: [String] = []
        /// Cue sheets whose track files weren't imported alongside them.
        var missingTracks: [String] = []

        /// Human-readable summary, or nil when everything imported cleanly.
        var problemSummary: String? {
            var lines: [String] = []
            if !unsupported.isEmpty {
                lines.append("Not supported ROMs (\(GamePaths.romExtensions.sorted().joined(separator: ", ")) only): "
                             + unsupported.joined(separator: ", "))
            }
            if !duplicates.isEmpty {
                lines.append("Already in library: " + duplicates.joined(separator: ", "))
            }
            if !failed.isEmpty {
                lines.append("Couldn't copy: " + failed.joined(separator: ", "))
            }
            if !missingTracks.isEmpty {
                lines.append("Missing CD tracks (select the .cue together with its .bin files): "
                             + missingTracks.joined(separator: "; "))
            }
            return lines.isEmpty ? nil : lines.joined(separator: "\n\n")
        }
    }

    enum LibraryError: LocalizedError {
        case invalidName
        case nameTaken(String)

        var errorDescription: String? {
            switch self {
            case .invalidName: "Names can't be empty or contain \"/\" or \":\"."
            case .nameTaken(let name): "A ROM named \"\(name)\" already exists."
            }
        }
    }

    @Published private(set) var entries: [ROMEntry] = []

    /// One console's games, alphabetical.
    struct SystemFolder: Hashable {
        var system: GameSystem
        var entries: [ROMEntry]
    }

    /// A manufacturer's consoles, in release order; empty consoles are omitted.
    struct MakerFolder: Hashable {
        var name: String
        var systems: [SystemFolder]
        var gameCount: Int { systems.reduce(0) { $0 + $1.entries.count } }
    }

    /// Manufacturers alphabetically (Nintendo, Sega), each with its consoles.
    var makers: [MakerFolder] {
        let bySystem = Dictionary(grouping: entries.filter { $0.system != nil }) { $0.system! }
        let systems = GameSystem.allCases
            .filter { bySystem[$0] != nil }
            .sorted { $0.releaseYear < $1.releaseYear }
        return Dictionary(grouping: systems, by: \.manufacturer)
            .map { name, systems in
                MakerFolder(name: name, systems: systems.map { SystemFolder(system: $0, entries: bySystem[$0] ?? []) })
            }
            .sorted { $0.name < $1.name }
    }

    /// Up to `limit` of `entries` that have been played, most recent first.
    static func recent(_ entries: [ROMEntry], limit: Int = 5) -> [ROMEntry] {
        entries.filter { $0.lastPlayed != nil }
            .sorted { $0.lastPlayed! > $1.lastPlayed! }
            .prefix(limit).map { $0 }
    }

    /// Records a launch and refreshes so the game moves to the top of Recently Played.
    func markPlayed(_ entry: ROMEntry) {
        RecentlyPlayed.mark(entry.fileName)
        refresh()
    }

    /// ROMs whose console can't be told (e.g. a zip without a known ROM inside).
    var unknownEntries: [ROMEntry] { entries.filter { $0.system == nil } }

    private var watcher: DispatchSourceFileSystemObject?
    private var pendingRefresh: DispatchWorkItem?

    init() {
        GamePaths.ensureDirectories()
        refresh()
        startWatching()
    }

    deinit { watcher?.cancel() }

    // MARK: Scanning

    func refresh() {
        GamePaths.ensureDirectories()
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        let urls = (try? fm.contentsOfDirectory(at: GamePaths.roms, includingPropertiesForKeys: keys,
                                                options: [.skipsHiddenFiles])) ?? []
        let played = RecentlyPlayed.dates()
        // .bin files a cue sheet points at are CD tracks, not Genesis cartridges.
        let tracks = Set(urls.filter { $0.pathExtension.lowercased() == "cue" }
            .flatMap { CueSheet.trackFiles(of: $0) }.map { $0.lowercased() })
        let found = urls.compactMap { url -> ROMEntry? in
            guard ROMLibrary.isROM(url), !tracks.contains(url.lastPathComponent.lowercased()) else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile ?? true else { return nil }
            // Detected once here: for zips this reads the archive's directory.
            let system = GameSystem.of(rom: url)
            let suspendState = GamePaths.state(for: url, slot: 0, system: system).path
            // Games played before launches were recorded: the auto-resume save is written
            // when leaving a game, so its date stands in.
            let lastPlayed = played[url.lastPathComponent]
                ?? (try? fm.attributesOfItem(atPath: suspendState))?[.modificationDate] as? Date
            return ROMEntry(url: url.standardizedFileURL,
                            fileSize: Int64(values?.fileSize ?? 0),
                            hasSuspendState: fm.fileExists(atPath: suspendState),
                            hasSRAM: fm.fileExists(atPath: GamePaths.sram(for: url, system: system).path),
                            system: system,
                            lastPlayed: lastPlayed)
        }
        .sorted { lhs, rhs in
            let order = lhs.title.localizedStandardCompare(rhs.title)
            return order == .orderedSame ? lhs.fileName < rhs.fileName : order == .orderedAscending
        }
        if found != entries { entries = found }
        // The folder may have been deleted and recreated from the Files app.
        if watcher == nil { startWatching() }
    }

    static func isROM(_ url: URL) -> Bool {
        GamePaths.romExtensions.contains(url.pathExtension.lowercased())
    }

    /// Watches the ROMs directory inode for adds / removes / renames and debounces a refresh.
    private func startWatching() {
        watcher?.cancel()
        watcher = nil
        let fd = open(GamePaths.roms.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                               eventMask: [.write, .delete, .rename, .link],
                                                               queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            if !source.data.isDisjoint(with: [.delete, .rename]) {
                // The folder itself went away; drop the stale descriptor and re-arm on refresh.
                source.cancel()
                if self.watcher === source { self.watcher = nil }
            }
            self.scheduleRefresh()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    /// Coalesces bursts of file events (a large copy fires many) into one rescan.
    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // MARK: Import

    /// Copies picked / shared files into the ROMs folder. Handles security-scoped URLs,
    /// coordinated reads (iCloud Drive / providers), duplicates and name collisions.
    @discardableResult
    func importFiles(_ urls: [URL]) -> ImportReport {
        GamePaths.ensureDirectories()
        var report = ImportReport()
        for source in urls {
            let name = source.lastPathComponent
            guard ROMLibrary.isROM(source) else {
                report.unsupported.append(name)
                continue
            }
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }

            var coordinationError: NSError?
            var result: Result<URL?, Error> = .success(nil)
            NSFileCoordinator().coordinate(readingItemAt: source, options: [.withoutChanges],
                                           error: &coordinationError) { readable in
                result = Result { try ROMLibrary.copyIntoLibrary(readable, preferredName: name) }
            }
            if coordinationError != nil {
                report.failed.append(name)
                continue
            }
            switch result {
            case .success(let dest?): report.imported.append(dest)
            case .success(nil): report.duplicates.append(name)
            case .failure: report.failed.append(name)
            }
        }
        for cue in report.imported where cue.pathExtension.lowercased() == "cue" {
            let missing = CueSheet.trackFiles(of: cue).filter {
                !FileManager.default.fileExists(atPath: cue.deletingLastPathComponent().appending(path: $0).path)
            }
            if !missing.isEmpty {
                report.missingTracks.append("\(cue.lastPathComponent) needs \(missing.joined(separator: ", "))")
            }
        }
        refresh()
        return report
    }

    /// Handles a URL delivered by the system (Open In / share sheet / Files "Open").
    /// Files the system staged in Documents/Inbox are moved, not copied, and the Inbox
    /// is cleaned up so it doesn't accumulate copies.
    @discardableResult
    func handleOpenURL(_ url: URL) -> ImportReport {
        guard url.isFileURL else { return ImportReport() }
        // Resolve symlinks on both sides: the system may hand us /private/var/... paths
        // while FileManager reports /var/....
        let file = url.resolvingSymlinksInPath()
        if file.deletingLastPathComponent().path == GamePaths.roms.resolvingSymlinksInPath().path {
            refresh()
            return ImportReport(imported: [file])
        }
        let report = importFiles([url])
        let inbox = GamePaths.documents.appending(path: "Inbox", directoryHint: .isDirectory)
            .resolvingSymlinksInPath()
        if file.path.hasPrefix(inbox.path + "/") {
            try? FileManager.default.removeItem(at: file)
            if let left = try? FileManager.default.contentsOfDirectory(atPath: inbox.path), left.isEmpty {
                try? FileManager.default.removeItem(at: inbox)
            }
        }
        return report
    }

    /// Returns the destination, or nil if an identical file is already in the library.
    private static func copyIntoLibrary(_ source: URL, preferredName: String) throws -> URL? {
        let fm = FileManager.default
        let base = (preferredName as NSString).deletingPathExtension
        let ext = (preferredName as NSString).pathExtension
        var candidate = GamePaths.roms.appending(path: preferredName)
        var counter = 2
        while fm.fileExists(atPath: candidate.path) {
            if fm.contentsEqual(atPath: candidate.path, andPath: source.path) { return nil }
            candidate = GamePaths.roms.appending(path: "\(base) (\(counter)).\(ext)")
            counter += 1
        }
        try fm.copyItem(at: source, to: candidate)
        return candidate
    }

    // MARK: Delete / rename

    /// Every save file belonging to a ROM: SRAM plus all state slots.
    static func saveFiles(for rom: URL) -> [URL] {
        let fm = FileManager.default
        var files: [URL] = []
        let system = GameSystem.of(rom: rom)
        let sram = GamePaths.sram(for: rom, system: system)
        if fm.fileExists(atPath: sram.path) { files.append(sram) }
        let prefix = rom.deletingPathExtension().lastPathComponent + ".s"
        // NES states live in their own subfolder; ask GamePaths rather than assume.
        let statesFolder = GamePaths.state(for: rom, slot: 0, system: system).deletingLastPathComponent()
        let states = (try? fm.contentsOfDirectory(at: statesFolder, includingPropertiesForKeys: nil)) ?? []
        for state in states {
            let name = state.lastPathComponent
            guard name.hasPrefix(prefix) else { continue }
            let slot = name.dropFirst(prefix.count)
            if !slot.isEmpty, slot.allSatisfy(\.isNumber) { files.append(state) }
        }
        return files
    }

    func delete(_ entry: ROMEntry, includingSaves: Bool) throws {
        let fm = FileManager.default
        // Collect saves before the ROM disappears, then remove the ROM first: if that fails,
        // the saves are left untouched.
        let saves = includingSaves ? ROMLibrary.saveFiles(for: entry.url) : []
        let tracks = CueSheet.trackFiles(of: entry.url)
            .map { entry.url.deletingLastPathComponent().appending(path: $0) }
        try fm.removeItem(at: entry.url)
        for file in saves + tracks { try? fm.removeItem(at: file) }
        RecentlyPlayed.forget(entry.fileName)
        refresh()
    }

    /// Renames the ROM (keeping its extension) and moves its SRAM / state files along so
    /// progress stays attached. `newName` is the base name without extension.
    func rename(_ entry: ROMEntry, to newName: String) throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains(":"),
              trimmed != ".", trimmed != ".." else { throw LibraryError.invalidName }
        let ext = entry.url.pathExtension
        let target = GamePaths.roms.appending(path: ext.isEmpty ? trimmed : "\(trimmed).\(ext)")
        if target.lastPathComponent == entry.fileName { return }
        let fm = FileManager.default
        // A case-only change refers to the same file on the case-insensitive file system.
        let caseOnly = target.lastPathComponent.lowercased() == entry.fileName.lowercased()
        if !caseOnly && fm.fileExists(atPath: target.path) {
            throw LibraryError.nameTaken(target.lastPathComponent)
        }
        let saves = ROMLibrary.saveFiles(for: entry.url)
        try fm.moveItem(at: entry.url, to: target)
        RecentlyPlayed.move(entry.fileName, to: target.lastPathComponent)

        let oldBase = entry.url.deletingPathExtension().lastPathComponent
        for file in saves {
            let suffix = String(file.lastPathComponent.dropFirst(oldBase.count))   // ".srm" / ".s3"
            let dest = file.deletingLastPathComponent().appending(path: trimmed + suffix)
            let destCaseOnly = dest.lastPathComponent.lowercased() == file.lastPathComponent.lowercased()
            if !destCaseOnly && fm.fileExists(atPath: dest.path) {
                // Another ROM's base name already owns that save; keep ours under the old
                // name rather than overwrite someone else's progress.
                continue
            }
            try? fm.moveItem(at: file, to: dest)
        }
        refresh()
    }
}

/// Minimal cue sheet reader: the track files a `.cue` names (`FILE "Game (Track 1).bin" BINARY`).
enum CueSheet {
    static func trackFiles(of cue: URL) -> [String] {
        guard cue.pathExtension.lowercased() == "cue",
              let data = try? Data(contentsOf: cue), data.count < 1_000_000 else { return [] }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.uppercased().hasPrefix("FILE ") else { return nil }
            let rest = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("\""), let end = rest.dropFirst().firstIndex(of: "\"") {
                return String(rest[rest.index(after: rest.startIndex)..<end])
            }
            return rest.split(separator: " ").first.map(String.init)
        }
        // Only plain names: a cue pointing elsewhere (../, absolute) isn't ours to manage.
        .filter { !$0.contains("/") && !$0.isEmpty }
    }
}

/// When each game was last started, keyed by ROM file name (UserDefaults "lastPlayed").
enum RecentlyPlayed {
    static let key = "lastPlayed"

    static func dates(defaults: UserDefaults = .standard) -> [String: Date] {
        (defaults.dictionary(forKey: key) as? [String: Date]) ?? [:]
    }

    static func mark(_ fileName: String, at date: Date = Date(), defaults: UserDefaults = .standard) {
        var all = dates(defaults: defaults)
        all[fileName] = date
        defaults.set(all, forKey: key)
    }

    static func forget(_ fileName: String, defaults: UserDefaults = .standard) {
        var all = dates(defaults: defaults)
        guard all.removeValue(forKey: fileName) != nil else { return }
        defaults.set(all, forKey: key)
    }

    static func move(_ fileName: String, to newName: String, defaults: UserDefaults = .standard) {
        var all = dates(defaults: defaults)
        guard let date = all.removeValue(forKey: fileName) else { return }
        all[newName] = date
        defaults.set(all, forKey: key)
    }
}
