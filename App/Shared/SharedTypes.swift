import Foundation
import Synchronization
import CoreGraphics

// MARK: - Buttons

/// SNES pad state as a bitmask. Bit positions match libretro's RETRO_DEVICE_ID_JOYPAD_* ids,
/// so the core host can answer input_state(port, JOYPAD, 0, id) with `(mask >> id) & 1`.
struct SNESButtons: OptionSet, Hashable, Sendable {
    let rawValue: UInt32

    static let b      = SNESButtons(rawValue: 1 << 0)
    static let y      = SNESButtons(rawValue: 1 << 1)
    static let select = SNESButtons(rawValue: 1 << 2)
    static let start  = SNESButtons(rawValue: 1 << 3)
    static let up     = SNESButtons(rawValue: 1 << 4)
    static let down   = SNESButtons(rawValue: 1 << 5)
    static let left   = SNESButtons(rawValue: 1 << 6)
    static let right  = SNESButtons(rawValue: 1 << 7)
    static let a      = SNESButtons(rawValue: 1 << 8)
    static let x      = SNESButtons(rawValue: 1 << 9)
    static let l      = SNESButtons(rawValue: 1 << 10)
    static let r      = SNESButtons(rawValue: 1 << 11)

    static let dpad: SNESButtons = [.up, .down, .left, .right]
}

// MARK: - Input

/// Where a button press came from. Each source owns its own slot so that releasing a key on
/// one device never cancels a press held on another.
enum InputSource: Int, CaseIterable, Sendable {
    case touch, gamepad, keyboard
}

/// Thread-safe merge point for all input. Written from the main thread / GameController
/// callbacks, read from the emulation thread once per input poll.
final class InputHub: Sendable {
    static let shared = InputHub()
    static let maxPlayers = 2

    private final class Slot: Sendable { let bits = Atomic<UInt32>(0) }
    private let slots: [Slot]

    init() {
        slots = (0..<(Self.maxPlayers * InputSource.allCases.count)).map { _ in Slot() }
    }

    private func index(_ source: InputSource, _ player: Int) -> Int {
        player * InputSource.allCases.count + source.rawValue
    }

    func set(_ buttons: SNESButtons, source: InputSource, player: Int = 0) {
        guard player < Self.maxPlayers else { return }
        slots[index(source, player)].bits.store(buttons.rawValue, ordering: .relaxed)
    }

    func press(_ buttons: SNESButtons, source: InputSource, player: Int = 0) {
        guard player < Self.maxPlayers else { return }
        slots[index(source, player)].bits.bitwiseOr(buttons.rawValue, ordering: .relaxed)
    }

    func release(_ buttons: SNESButtons, source: InputSource, player: Int = 0) {
        guard player < Self.maxPlayers else { return }
        slots[index(source, player)].bits.bitwiseAnd(~buttons.rawValue, ordering: .relaxed)
    }

    /// Union of all sources for a player. Opposing d-pad directions are masked out because
    /// some games misbehave when left+right or up+down are held at once.
    func buttons(player: Int) -> SNESButtons {
        guard player < Self.maxPlayers else { return [] }
        var raw: UInt32 = 0
        for source in InputSource.allCases {
            raw |= slots[index(source, player)].bits.load(ordering: .relaxed)
        }
        var result = SNESButtons(rawValue: raw)
        if result.contains([.left, .right]) { result.remove([.left, .right]) }
        if result.contains([.up, .down]) { result.remove([.up, .down]) }
        return result
    }

    func clearAll() {
        for slot in slots { slot.bits.store(0, ordering: .relaxed) }
        setPointer(x: 0, y: 0, pressed: false)
    }

    // MARK: Touch screen (DS)

    /// The DS touch screen as a libretro pointer: x/y in -0x7FFF...0x7FFF across the core's
    /// whole frame, plus whether a finger is down. Packed into one atomic so the emulation
    /// thread never sees x from one touch and y from another.
    private let pointerBits = Atomic<UInt64>(0)

    func setPointer(x: Int16, y: Int16, pressed: Bool) {
        let packed = UInt64(UInt16(bitPattern: x)) | UInt64(UInt16(bitPattern: y)) << 16
            | (pressed ? 1 << 32 : 0)
        pointerBits.store(packed, ordering: .relaxed)
    }

    var pointer: (x: Int16, y: Int16, pressed: Bool) {
        let packed = pointerBits.load(ordering: .relaxed)
        return (Int16(bitPattern: UInt16(truncatingIfNeeded: packed)),
                Int16(bitPattern: UInt16(truncatingIfNeeded: packed >> 16)),
                packed & (1 << 32) != 0)
    }
}

// MARK: - Video

/// Latest-frame mailbox between the emulation thread (producer) and the renderer (consumer).
/// Pixels are RGB565, tightly packed (`width * 2` bytes per row) after `submit`.
final class FrameBuffer: @unchecked Sendable {
    /// Arcade boards go up to 640 wide (SNES hi-res is 512).
    static let maxWidth = 640
    static let maxHeight = 480

    struct Frame {
        var width: Int
        var height: Int
        /// Monotonic counter; renderers skip work when it hasn't changed.
        var sequence: UInt64
    }

    private let lock = Mutex<Void>(())
    private var pixels = [UInt16](repeating: 0, count: maxWidth * maxHeight)
    private var width = 256
    private var height = 224
    private var sequence: UInt64 = 0

    /// Copies a frame from the core. `pitch` is in bytes and may exceed `width * 2`.
    func submit(_ data: UnsafeRawPointer, width: Int, height: Int, pitch: Int) {
        let w = min(width, Self.maxWidth), h = min(height, Self.maxHeight)
        lock.withLock { _ in
            pixels.withUnsafeMutableBytes { dst in
                for row in 0..<h {
                    (dst.baseAddress! + row * w * 2)
                        .copyMemory(from: data + row * pitch, byteCount: w * 2)
                }
            }
            self.width = w
            self.height = h
            sequence &+= 1
        }
    }

    /// Calls `body` with the current frame while holding the lock; keep the work short
    /// (e.g. a texture upload).
    func withLatestFrame<R>(_ body: (Frame, UnsafeRawPointer) throws -> R) rethrows -> R {
        try lock.withLock { _ in
            try pixels.withUnsafeBytes { buf in
                try body(Frame(width: width, height: height, sequence: sequence), buf.baseAddress!)
            }
        }
    }

    var latestSequence: UInt64 { lock.withLock { _ in sequence } }
}

// MARK: - Audio

/// Single-producer / single-consumer ring of interleaved stereo Int16 samples.
/// Producer: emulation thread. Consumer: the audio render callback (must never block).
final class AudioRingBuffer: @unchecked Sendable {
    /// Capacity in stereo frames.
    let capacity: Int
    private let storage: UnsafeMutablePointer<Int16>
    private let writeIndex = Atomic<Int>(0)   // total frames ever written
    private let readIndex = Atomic<Int>(0)    // total frames ever read

    init(capacityFrames: Int = 8192) {
        capacity = capacityFrames
        storage = .allocate(capacity: capacityFrames * 2)
        storage.initialize(repeating: 0, count: capacityFrames * 2)
    }

    deinit { storage.deallocate() }

    /// Frames currently buffered.
    var availableFrames: Int {
        writeIndex.load(ordering: .acquiring) - readIndex.load(ordering: .acquiring)
    }

    /// Writes up to `frames` stereo frames; drops what doesn't fit. Returns frames written.
    @discardableResult
    func write(_ samples: UnsafePointer<Int16>, frames: Int) -> Int {
        let w = writeIndex.load(ordering: .relaxed)
        let r = readIndex.load(ordering: .acquiring)
        let n = min(frames, capacity - (w - r))
        guard n > 0 else { return 0 }
        for i in 0..<n {
            let slot = ((w + i) % capacity) * 2
            storage[slot] = samples[i * 2]
            storage[slot + 1] = samples[i * 2 + 1]
        }
        writeIndex.store(w + n, ordering: .releasing)
        return n
    }

    /// Reads up to `frames` stereo frames into `out`. Returns frames read; the caller should
    /// fill any remainder with silence.
    @discardableResult
    func read(into out: UnsafeMutablePointer<Int16>, frames: Int) -> Int {
        let r = readIndex.load(ordering: .relaxed)
        let w = writeIndex.load(ordering: .acquiring)
        let n = min(frames, w - r)
        guard n > 0 else { return 0 }
        for i in 0..<n {
            let slot = ((r + i) % capacity) * 2
            out[i * 2] = storage[slot]
            out[i * 2 + 1] = storage[slot + 1]
        }
        readIndex.store(r + n, ordering: .releasing)
        return n
    }

    /// Discards everything buffered. Only call from the consumer side or while both are idle.
    func reset() {
        readIndex.store(writeIndex.load(ordering: .acquiring), ordering: .releasing)
    }
}

// MARK: - Duo posture

/// How the device is physically being held, derived from UIHinge on iPhone Duo and treated
/// as `.flat` (or `.closed`-equivalent phone layout) everywhere else.
enum Posture: Equatable, Sendable {
    /// Closed: only the 5.4" outer display is in use. Lay out like a regular phone.
    case closed
    /// Partially open like a laptop / Nintendo DS. Game goes above the fold, controls below.
    /// `division` is the fold's frame in the game view controller's view coordinates.
    case tent(division: CGRect)
    /// Fully open 7.6" inner display, or any non-foldable device.
    case flat
}

// MARK: - Systems

/// A console the app can emulate. Each maps to one statically linked libretro core.
enum GameSystem: String, CaseIterable, Sendable {
    case snes, nes, nds, genesis, sega32x, segaCD, neoGeo, cps, arcade, psx

    var displayName: String {
        switch self {
        case .snes: "SNES"
        case .nes: "NES"
        case .nds: "DS"
        case .genesis: "Genesis"
        case .sega32x: "32X"
        case .segaCD: "Sega CD"
        case .neoGeo: "Neo Geo"
        case .cps: "Capcom CPS"
        case .arcade: "Arcade"
        case .psx: "PlayStation"
        }
    }

    /// Arcade boards run by FinalBurn Neo, recognized by set name (`ArcadeCatalog`).
    var isArcade: Bool { coreName == "fbneo" }

    /// Who made the console; the library's top-level folders.
    var manufacturer: String {
        switch self {
        case .nes, .snes, .nds: "Nintendo"
        case .genesis, .sega32x, .segaCD: "Sega"
        case .neoGeo, .cps, .arcade: "Arcade"
        case .psx: "Sony"
        }
    }

    /// North American release year, used to order systems within a manufacturer.
    var releaseYear: Int {
        switch self {
        case .nes: 1985
        case .genesis: 1989
        case .snes: 1991
        case .segaCD: 1992
        case .sega32x: 1994
        case .nds: 2004
        case .cps: 1988
        case .neoGeo: 1990
        case .psx: 1995
        // "Arcade" (every other board) is listed last.
        case .arcade: 9999
        }
    }

    /// The libretro core that runs this system. Several systems can share one core
    /// (PicoDrive runs Genesis, 32X and Sega CD), so per-core state is keyed by this.
    var coreName: String {
        switch self {
        case .snes: "snes9x"
        case .nes: "fceumm"
        case .nds: "melonds"
        case .genesis, .sega32x, .segaCD: "picodrive"
        case .neoGeo, .cps, .arcade: "fbneo"
        case .psx: "pcsx"
        }
    }

    /// The core opens the file itself: disc images (a .cue names its .bin tracks) and arcade
    /// sets (FinalBurn Neo reads the zip and finds BIOS sets such as neogeo.zip beside it),
    /// so the app passes the path instead of reading hundreds of MB into memory.
    var loadsFromPath: Bool { self == .segaCD || self == .psx || isArcade }

    /// Sega's consoles output 256- or 320-pixel-wide frames that a TV showed at 4:3 either
    /// way; nil means derive the shape from the frame (SNES/NES 8:7 pixels, DS square).
    var displayAspect: CGFloat? {
        switch self {
        case .genesis, .sega32x, .segaCD, .psx: 4.0 / 3.0
        default: nil
        }
    }

    /// BIOS file names the core looks for in GamePaths.system (any one is enough), or
    /// empty when none is needed.
    var requiredBIOS: [String] {
        guard self == .segaCD else { return [] }
        // PicoDrive's find_bios() names (platform/libretro/libretro.c), US/EU/JP.
        return ["us_scd2_9306", "SegaCDBIOS9303", "us_scd1_9210", "bios_CD_U",
                "eu_mcd2_9306", "eu_mcd2_9303", "eu_mcd1_9210", "bios_CD_E",
                "jp_mcd2_921222", "jp_mcd1_9112", "jp_mcd1_9111", "bios_CD_J"].map { $0 + ".bin" }
    }

    /// Two screens stacked in one frame (top screen above the touch screen).
    var isDualScreen: Bool { self == .nds }

    /// Shape of the on-screen pad: SNES-style (SNES, DS: d-pad, A/B/X/Y, L/R, Select/Start),
    /// NES (A/B, Select/Start), or the Genesis 3-button (A/B/C) / 6-button (also X/Y/Z) pad
    /// with Start. Sega games pick 3 or 6 per game (`GenesisPad`).
    enum PadStyle: Equatable, Sendable {
        case snes, nes, genesis3, genesis6, playstation
        var isGenesis: Bool { self == .genesis3 || self == .genesis6 }
        /// Four face buttons in a diamond with L/R shoulders (SNES, DS, arcade, PlayStation).
        var isDiamond: Bool { self == .snes || self == .playstation }
    }

    /// Default pad for the system; Sega systems default to the 6-button pad.
    var padStyle: PadStyle {
        switch self {
        case .snes, .nds, .neoGeo, .cps, .arcade: .snes
        case .nes: .nes
        case .genesis, .sega32x, .segaCD: .genesis6
        case .psx: .playstation
        }
    }

    /// Whether the pad has L/R shoulder buttons (and X/Y).
    var hasShoulderButtons: Bool { padStyle.isDiamond }

    /// ROM file extensions (lowercase, without the dot). `.zip` is handled separately.
    var romExtensions: Set<String> {
        switch self {
        case .snes: ["sfc", "smc", "swc", "fig", "bs", "st"]
        case .nes: ["nes", "unf", "unif"]
        case .nds: ["nds"]
        // .bin is also used for CD tracks; the library hides .bin files a .cue refers to.
        case .genesis: ["md", "gen", "smd", "sgd", "bin"]
        case .sega32x: ["32x"]
        case .segaCD: ["cue", "chd"]
        // Arcade sets are .zip / .7z named after the set; see `GameSystem.of(rom:)`.
        case .neoGeo, .cps, .arcade: []
        // .cue / .chd are shared with Sega CD; `GameSystem.of(rom:)` looks inside.
        case .psx: ["pbp", "m3u"]
        }
    }

    /// Folder under Saves/ and States/. SNES predates multi-system support and keeps the
    /// top level so existing saves stay where they are; others get their own folder so
    /// "Tetris.nes" and "Tetris.sfc" never share a save.
    var saveSubfolder: String? {
        switch self {
        case .snes: nil
        case .nes: "NES"
        case .nds: "DS"
        case .genesis: "Genesis"
        case .sega32x: "32X"
        case .segaCD: "SegaCD"
        case .neoGeo, .cps, .arcade: "Arcade"
        case .psx: "PSX"
        }
    }

    /// Battery-save file extension. melonDS writes its own `<game>.sav` (DS saves live in
    /// cartridge EEPROM/flash, which it flushes itself); the other cores expose SRAM to us.
    var saveExtension: String { self == .nds ? "sav" : "srm" }

    init?(romExtension ext: String) {
        guard let match = Self.allCases.first(where: { $0.romExtensions.contains(ext.lowercased()) })
        else { return nil }
        self = match
    }

    /// System of a ROM file. For `.zip` archives this reads only the file's tail, where the
    /// zip's central directory lists entry names, and matches the first ROM-looking name.
    static func of(rom: URL) -> GameSystem? {
        let ext = rom.pathExtension.lowercased()
        if ext == "bin" { return isSega32XCartridge(rom) ? .sega32x : .genesis }
        if ext == "7z" { return ArcadeCatalog.system(forSet: rom) }
        if ext == "cue" || ext == "chd" { return DiscImage.system(of: rom) }
        if ext == "m3u" {
            // A multi-disc playlist is whatever its first disc is.
            return DiscPlaylist.entries(of: rom).first
                .flatMap { GameSystem.of(rom: rom.deletingLastPathComponent().appending(path: $0)) } ?? .psx
        }
        if ext != "zip" { return GameSystem(romExtension: ext) }
        guard let handle = try? FileHandle(forReadingFrom: rom) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let tailLength = min(size, 256 * 1024)
        try? handle.seek(toOffset: size - tailLength)
        guard let tail = try? handle.read(upToCount: Int(tailLength)) else { return nil }
        // Strongest evidence first: a distinctive cartridge extension inside (.sfc, .nes,
        // .md...), then an arcade set name (mslug.zip, whose files are all .bin), and only
        // then a lone .bin, which arcade sets and Genesis dumps both use.
        let systems = zipEntryNames(inTail: [UInt8](tail)).compactMap { name -> GameSystem? in
            let file = name.split(separator: "/").last.map(String.init) ?? name
            guard !name.hasPrefix("__MACOSX/"), !file.hasPrefix("._") else { return nil }
            let ext = (file as NSString).pathExtension.lowercased()
            return ext == "bin" ? nil : GameSystem(romExtension: ext)
        }
        if let cartridge = systems.first { return cartridge }
        if let arcade = ArcadeCatalog.system(forSet: rom) { return arcade }
        let hasBin = zipEntryNames(inTail: [UInt8](tail)).contains { $0.lowercased().hasSuffix(".bin") }
        return hasBin ? .genesis : nil
    }

    /// GoodGen-style sets name 32X cartridges ".bin" too; their header (0x100) reads
    /// "SEGA 32X" where Genesis carts have "SEGA GENESIS" / "SEGA MEGA DRIVE".
    private static func isSega32XCartridge(_ rom: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: rom) else { return false }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: 0x100)) != nil,
              let header = try? handle.read(upToCount: 16) else { return false }
        return String(decoding: header, as: UTF8.self).uppercased().contains("32X")
    }

    /// Names from zip central-directory headers (signature PK\1\2) found in `bytes`.
    private static func zipEntryNames(inTail bytes: [UInt8]) -> [String] {
        var names: [String] = []
        var i = 0
        while i + 46 <= bytes.count {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4B, bytes[i + 2] == 0x01, bytes[i + 3] == 0x02 {
                let nameLength = Int(bytes[i + 28]) | Int(bytes[i + 29]) << 8
                if i + 46 + nameLength <= bytes.count,
                   let name = String(bytes: bytes[(i + 46)..<(i + 46 + nameLength)], encoding: .utf8) {
                    names.append(name)
                }
                i += 46 + nameLength
            } else {
                i += 1
            }
        }
        return names
    }
}

// MARK: - File locations

/// On-disk layout. Everything lives under Documents so it shows up in the Files app
/// (UIFileSharingEnabled) and is included in device backups.
enum GamePaths {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    static var roms: URL { documents.appending(path: "ROMs", directoryHint: .isDirectory) }
    static var saves: URL { documents.appending(path: "Saves", directoryHint: .isDirectory) }
    static var states: URL { documents.appending(path: "States", directoryHint: .isDirectory) }
    /// libretro "system" directory (BIOS-like files; snes9x needs none for normal games).
    static var system: URL { documents.appending(path: "System", directoryHint: .isDirectory) }

    /// Battery save (SRAM) for a ROM, keyed by the ROM's file name without extension.
    /// `system` defaults to detecting it from the ROM; pass it when already known.
    static func sram(for rom: URL, system: GameSystem? = nil) -> URL {
        let system = system ?? GameSystem.of(rom: rom)
        return folder(saves, for: system)
            .appending(path: rom.deletingPathExtension().lastPathComponent
                       + "." + (system ?? .snes).saveExtension)
    }

    /// Save-state slot file. Slot 0 is the auto-save written on suspend.
    static func state(for rom: URL, slot: Int, system: GameSystem? = nil) -> URL {
        folder(states, for: system ?? GameSystem.of(rom: rom))
            .appending(path: rom.deletingPathExtension().lastPathComponent + ".s\(slot)")
    }

    private static func folder(_ base: URL, for system: GameSystem?) -> URL {
        guard let sub = system?.saveSubfolder else { return base }
        return base.appending(path: sub, directoryHint: .isDirectory)
    }

    static func ensureDirectories() {
        let perSystem = GameSystem.allCases.compactMap(\.saveSubfolder)
            .flatMap { [saves.appending(path: $0), states.appending(path: $0)] }
        for dir in [roms, saves, states, system] + perSystem {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Every importable extension: all systems' ROMs plus `.zip`.
    static let romExtensions: Set<String> = GameSystem.allCases
        .reduce(into: ["zip", "7z"]) { $0.formUnion($1.romExtensions) }
}

// MARK: - Disc images

/// Tells PlayStation discs from Sega CD ones, which share the .cue / .chd formats: PlayStation
/// discs are CD-ROM XA "Mode 2", Sega CD discs "Mode 1".
enum DiscImage {
    static func system(of disc: URL) -> GameSystem? {
        let mode: Int?
        switch disc.pathExtension.lowercased() {
        case "cue": mode = cueDataMode(disc)
        case "chd": mode = chdDataMode(disc)
        default: mode = nil
        }
        guard FileManager.default.fileExists(atPath: disc.path) else { return nil }
        return mode == 2 ? .psx : .segaCD
    }

    /// Mode of the first data track in a cue sheet ("TRACK 01 MODE2/2352" -> 2).
    static func cueDataMode(_ cue: URL) -> Int? {
        guard let data = try? Data(contentsOf: cue), data.count < 1_000_000 else { return nil }
        return dataMode(in: String(decoding: data, as: UTF8.self).uppercased())
    }

    /// Mode of the first data track in a CHD's CD metadata ("TYPE:MODE2_RAW" -> 2). Reads the
    /// header's metadata offset (v5 at byte 48, v3/v4 at 36) and the first metadata entry.
    static func chdDataMode(_ chd: URL) -> Int? {
        guard let handle = try? FileHandle(forReadingFrom: chd) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 124), header.count >= 56,
              header.prefix(8) == Data("MComprHD".utf8) else { return nil }
        let bytes = [UInt8](header)
        func be(_ at: Int, _ count: Int) -> UInt64 { (0..<count).reduce(0) { $0 << 8 | UInt64(bytes[at + $1]) } }
        let version = be(12, 4)
        var offset = version >= 5 ? be(48, 8) : be(36, 8)
        // Walk a few metadata entries: tag(4) flags+length(4) next(8) data.
        for _ in 0..<8 where offset > 0 {
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let entry = try? handle.read(upToCount: 16), entry.count == 16 else { return nil }
            let e = [UInt8](entry)
            let length = Int(e[5]) << 16 | Int(e[6]) << 8 | Int(e[7])
            let next = (8..<16).reduce(UInt64(0)) { $0 << 8 | UInt64(e[$1]) }
            if let text = try? handle.read(upToCount: min(length, 512)),
               let mode = dataMode(in: String(decoding: text, as: UTF8.self).uppercased()) {
                return mode
            }
            offset = next
        }
        return nil
    }

    private static func dataMode(in text: String) -> Int? {
        if text.contains("MODE2") { return 2 }
        if text.contains("MODE1") { return 1 }
        return nil
    }
}

/// .m3u multi-disc playlists: one disc file name per line ("#" lines are comments).
enum DiscPlaylist {
    static func entries(of m3u: URL) -> [String] {
        guard let data = try? Data(contentsOf: m3u), data.count < 100_000 else { return [] }
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.contains("/") }
    }

    /// Groups disc files named like "Game Disc 1.chd", "Game (Disc 2).chd", "Game CD3.chd",
    /// "Game (1of2).chd" by game, for files that make up more than one disc. Returns
    /// playlist name -> disc file names in disc order.
    static func groups(in fileNames: [String]) -> [String: [String]] {
        let pattern = try! NSRegularExpression(
            pattern: #"^(.*?)[\s\-_]*[\(\[]?(?:disc|disk|cd)\s*(\d+)(?:\s*of\s*\d+)?[\)\]]?(.*)\.(chd|cue|pbp)$|^(.*?)\s*\((\d+)\s*of\s*\d+\)(.*)\.(chd|cue|pbp)$"#,
            options: [.caseInsensitive])
        var byGame: [String: [(Int, String)]] = [:]
        for name in fileNames {
            let range = NSRange(name.startIndex..., in: name)
            guard let m = pattern.firstMatch(in: name, range: range) else { continue }
            let first = m.range(at: 1).location != NSNotFound ? 1 : 5
            func group(_ i: Int) -> String {
                Range(m.range(at: i), in: name).map { String(name[$0]) } ?? ""
            }
            // Per-disc serials ("[SLUS_013.13]" / "[SLUS_013.14]") don't make different games.
            let rest = group(first + 2).replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
            let title = (group(first) + rest)
                .trimmingCharacters(in: CharacterSet(charactersIn: " -_"))
            guard let disc = Int(group(first + 1)), !title.isEmpty else { continue }
            byGame[title, default: []].append((disc, name))
        }
        return byGame.filter { $0.value.count > 1 }
            .mapValues { $0.sorted { $0.0 < $1.0 }.map(\.1) }
    }
}
