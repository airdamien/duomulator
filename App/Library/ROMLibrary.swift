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

    var id: URL { url }
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

        /// Human-readable summary, or nil when everything imported cleanly.
        var problemSummary: String? {
            var lines: [String] = []
            if !unsupported.isEmpty {
                lines.append("Not SNES ROMs (\(GamePaths.romExtensions.sorted().joined(separator: ", ")) only): "
                             + unsupported.joined(separator: ", "))
            }
            if !duplicates.isEmpty {
                lines.append("Already in library: " + duplicates.joined(separator: ", "))
            }
            if !failed.isEmpty {
                lines.append("Couldn't copy: " + failed.joined(separator: ", "))
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
        let found = urls.compactMap { url -> ROMEntry? in
            guard ROMLibrary.isROM(url) else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile ?? true else { return nil }
            return ROMEntry(url: url.standardizedFileURL,
                            fileSize: Int64(values?.fileSize ?? 0),
                            hasSuspendState: fm.fileExists(atPath: GamePaths.state(for: url, slot: 0).path),
                            hasSRAM: fm.fileExists(atPath: GamePaths.sram(for: url).path))
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
        let sram = GamePaths.sram(for: rom)
        if fm.fileExists(atPath: sram.path) { files.append(sram) }
        let prefix = rom.deletingPathExtension().lastPathComponent + ".s"
        let states = (try? fm.contentsOfDirectory(at: GamePaths.states, includingPropertiesForKeys: nil)) ?? []
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
        try fm.removeItem(at: entry.url)
        for file in saves { try? fm.removeItem(at: file) }
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
