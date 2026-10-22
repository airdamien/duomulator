import CryptoKit
import Foundation

/// One BIOS / system file a core can use, and where it has to live under the name the core
/// looks for.
struct BIOSSlot: Identifiable, Hashable, Sendable {
    enum Folder: Sendable { case system, roms }

    let system: GameSystem
    /// What the player sees, e.g. "US (SCPH1001)".
    let title: String
    /// The exact file name the core opens.
    let fileName: String
    let folder: Folder
    /// MD5s of known-good dumps, for recognising files on import (empty = by name only).
    let md5: Set<String>

    var id: String { fileName }

    var url: URL {
        (folder == .system ? GamePaths.system : GamePaths.roms).appending(path: fileName)
    }

    var isInstalled: Bool { FileManager.default.fileExists(atPath: url.path) }
}

/// The BIOS files Duomulator's cores use. Sega CD and Neo Geo need one; PlayStation and DS
/// run without (built-in replacement BIOS) but are more compatible with the real thing.
enum BIOSCatalog {
    struct Group: Identifiable, Sendable {
        let system: GameSystem
        let slots: [BIOSSlot]
        /// Games won't start without at least one of `slots`.
        let required: Bool
        let note: String
        var id: GameSystem { system }
        var isSatisfied: Bool { slots.contains { $0.isInstalled } }
    }

    static let groups: [Group] = [
        Group(system: .segaCD, slots: [
            BIOSSlot(system: .segaCD, title: "US (Sega CD)", fileName: "bios_CD_U.bin", folder: .system,
                     md5: ["2efd74e3232ff260e371b99f84024f7f"]),
            BIOSSlot(system: .segaCD, title: "Europe (Mega-CD)", fileName: "bios_CD_E.bin", folder: .system,
                     md5: ["e66fa1dc5820d254611fdcdba0662372"]),
            BIOSSlot(system: .segaCD, title: "Japan (Mega-CD)", fileName: "bios_CD_J.bin", folder: .system,
                     md5: ["278a9397d192149e84e820ac621a8edd"]),
        ], required: true, note: "Needed for Sega CD games; one region is enough."),
        Group(system: .psx, slots: [
            BIOSSlot(system: .psx, title: "US (SCPH5501)", fileName: "scph5501.bin", folder: .system,
                     md5: ["490f666e1afb15b7362b406ed1cea246"]),
            BIOSSlot(system: .psx, title: "US (SCPH1001)", fileName: "scph1001.bin", folder: .system,
                     md5: ["924e392ed05558ffdb115408c263dccf"]),
            BIOSSlot(system: .psx, title: "US (SCPH7001)", fileName: "scph7001.bin", folder: .system,
                     md5: ["1e68c231d0896b7eadcad1d7d8e76129"]),
            BIOSSlot(system: .psx, title: "PSone (SCPH101)", fileName: "scph101.bin", folder: .system,
                     md5: ["6e3735ff4c7dc899ee98981385f6f3d0"]),
        ], required: false, note: "Optional: without one a built-in replacement BIOS runs, which some games don't like."),
        Group(system: .nds, slots: [
            BIOSSlot(system: .nds, title: "ARM7 BIOS", fileName: "bios7.bin", folder: .system,
                     md5: ["df692a80a5b1bc90728bc3dfc76cd948"]),
            BIOSSlot(system: .nds, title: "ARM9 BIOS", fileName: "bios9.bin", folder: .system,
                     md5: ["a392174eb3e572fed6447e956bde4b25"]),
            BIOSSlot(system: .nds, title: "Firmware", fileName: "firmware.bin", folder: .system, md5: []),
        ], required: false, note: "Optional: melonDS's built-in FreeBIOS runs most games. Install all three to use them."),
        Group(system: .neoGeo, slots: [
            BIOSSlot(system: .neoGeo, title: "Neo Geo BIOS set", fileName: "neogeo.zip", folder: .roms, md5: []),
        ], required: true, note: "Needed for Neo Geo games, in a current FinalBurn Neo set. Kept with the ROMs, hidden from the game list."),
    ]

    static var allSlots: [BIOSSlot] { groups.flatMap(\.slots) }

    static var installedCount: Int { allSlots.filter(\.isInstalled).count }

    // MARK: Import

    enum ImportError: LocalizedError {
        case unreadable(String)
        case unrecognized(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): "Couldn't read \(name)."
            case .unrecognized(let name): "\(name) isn't a BIOS file Duomulator recognises. Import it from its slot instead."
            }
        }
    }

    /// The slot a file belongs in: a known checksum, else an exact file name (case-insensitive),
    /// else a DS firmware-sized file named like "firmware".
    static func identify(_ file: URL) -> BIOSSlot? {
        let name = file.lastPathComponent.lowercased()
        if let data = try? Data(contentsOf: file, options: .mappedIfSafe), data.count <= 8 * 1024 * 1024 {
            let md5 = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if let slot = allSlots.first(where: { $0.md5.contains(md5) }) { return slot }
            if name.contains("firmware"), [131_072, 262_144, 524_288].contains(data.count) {
                return allSlots.first { $0.fileName == "firmware.bin" }
            }
        }
        return allSlots.first { $0.fileName.lowercased() == name }
    }

    /// Copies `file` into `slot` under the core's file name, replacing what was there.
    static func install(_ file: URL, into slot: BIOSSlot) throws {
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        GamePaths.ensureDirectories()
        var coordinationError: NSError?
        var result: Result<Void, Error> = .success(())
        NSFileCoordinator().coordinate(readingItemAt: file, options: [.withoutChanges], error: &coordinationError) { readable in
            result = Result {
                let fm = FileManager.default
                let temp = slot.url.deletingLastPathComponent()
                    .appending(path: ".\(slot.fileName).\(UUID().uuidString)")
                try fm.copyItem(at: readable, to: temp)
                if fm.fileExists(atPath: slot.url.path) {
                    _ = try fm.replaceItemAt(slot.url, withItemAt: temp)
                } else {
                    try fm.moveItem(at: temp, to: slot.url)
                }
            }
        }
        if coordinationError != nil { throw ImportError.unreadable(file.lastPathComponent) }
        try result.get()
    }

    /// Recognises and installs each file; returns what went where and what didn't.
    static func importFiles(_ files: [URL]) -> (installed: [(file: String, slot: BIOSSlot)], failed: [String]) {
        var installed: [(String, BIOSSlot)] = [], failed: [String] = []
        for file in files {
            let scoped = file.startAccessingSecurityScopedResource()
            let slot = identify(file)
            if scoped { file.stopAccessingSecurityScopedResource() }
            guard let slot else { failed.append(file.lastPathComponent); continue }
            do {
                try install(file, into: slot)
                installed.append((file.lastPathComponent, slot))
            } catch {
                failed.append(file.lastPathComponent)
            }
        }
        return (installed, failed)
    }

    static func remove(_ slot: BIOSSlot) throws {
        try FileManager.default.removeItem(at: slot.url)
    }
}
