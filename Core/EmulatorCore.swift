import Foundation
import Synchronization
import os

enum EmulatorError: Error, LocalizedError {
    case romUnreadable(URL), coreRejectedROM, noGameLoaded, stateFailed(String)
    /// A `.zip` that can't be used: no ROM inside, unsupported method, or damaged.
    case unsupportedArchive(String)
    /// The system needs a BIOS dumped from the user's console (Sega CD).
    case missingBIOS(GameSystem)
    /// FinalBurn Neo couldn't start an arcade set.
    case arcadeSetRejected(String)

    var errorDescription: String? {
        switch self {
        case .romUnreadable(let url): "Couldn't read \(url.lastPathComponent)."
        case .coreRejectedROM: "The emulator couldn't start this game. The file may be damaged or not a supported ROM."
        case .missingBIOS(let system):
            "\(system.displayName) games need the console's BIOS. Copy one of these files from your own console into Duomulator's System folder (Files app ▸ On My iPhone ▸ Duomulator ▸ System): "
            + system.requiredBIOS.prefix(4).joined(separator: ", ") + " (or the EU/JP equivalents)."
        case .noGameLoaded: "No game is loaded."
        case .stateFailed(let detail): "Save state failed: \(detail)"
        case .unsupportedArchive(let detail): detail
        case .arcadeSetRejected(let set):
            "FinalBurn Neo couldn't start \(set). Arcade sets have to match FinalBurn Neo's ROM set versions, and their parent and BIOS sets (such as neogeo.zip) must be in the ROMs folder too."
        }
    }
}

private let log = Logger(subsystem: "io.kurast.duomulator", category: "core")

// MARK: - Process-wide libretro state

/// Each core is a static library full of globals, so there is exactly one emulated console
/// per process; `api` points at the core of the loaded game. Every retro_* call happens with `coreLock` held; the core's callbacks only fire
/// from inside those calls, so they see `activeHost` (the EmulatorCore that owns the loaded
/// game) and the environment tables consistently. Public API calls are serialized by
/// `apiLock` (recursive, because `load` unloads whatever was loaded before).
private let coreLock = NSLock()
private let apiLock = NSRecursiveLock()
nonisolated(unsafe) private var activeHost: EmulatorCore?
nonisolated(unsafe) private var api = GameSystem.snes.coreAPI
/// Cores that have had retro_set_environment / retro_init called (once per process each).
nonisolated(unsafe) private var initializedCores: Set<String> = []   // GameSystem.coreName

extension GameSystem {
    /// The statically linked libretro core for this system (see Core/CoreAPI.h).
    var coreAPI: DuoCoreAPI {
        switch self {
        case .snes: duo_core_snes9x
        case .nes: duo_core_fceumm
        case .nds: duo_core_melonds
        case .genesis, .sega32x, .segaCD: duo_core_picodrive
        case .neoGeo, .cps, .arcade: duo_core_fbneo
        case .psx: duo_core_pcsx
        case .n64: duo_core_mupen64
        }
    }
}

/// Disc-swap callbacks the loaded game's core registered (multi-disc PlayStation games via
/// .m3u), or nil. Cleared before every load; the core registers again while loading.
nonisolated(unsafe) private var diskControl: retro_disk_control_callback?

/// System whose core `api` points at; environment answers that differ per core use it.
nonisolated(unsafe) private var apiSystem = GameSystem.snes
/// Pixel format each core asked for (RGB565 or XRGB8888); FrameBuffer is RGB565, so XRGB8888
/// frames are converted on the way in. Kept per core because a core may only announce its
/// format once per process, and cores alternate as games are switched.
nonisolated(unsafe) private var corePixelFormats: [String: retro_pixel_format] = [:]   // by coreName

/// C strings handed to the core. libretro requires them to outlive the call that returned
/// them, so they are allocated once and kept for the life of the process.
private enum CoreEnvironment {
    nonisolated(unsafe) static var systemDirectory: UnsafeMutablePointer<CChar>?
    /// Per system, matching GamePaths' save folders (melonDS writes its .sav files there).
    nonisolated(unsafe) static var saveDirectories: [GameSystem: UnsafeMutablePointer<CChar>] = [:]
    /// Core option key -> value, filled from the defaults the core declares via the legacy
    /// SET_VARIABLES call (we answer GET_CORE_OPTIONS_VERSION with false).
    /// The defaults are what we want: overscan cropped to 224 lines, no NTSC filter, no
    /// opposing d-pad directions, no memory randomization. Keys are prefixed per core, so one
    /// table serves all of them; `overrides` replaces the few defaults we don't want.
    nonisolated(unsafe) static var variables: [String: UnsafeMutablePointer<CChar>] = [:]

    /// Per-game values set by the app (`EmulatorCore.setCoreOption`); win over everything.
    nonisolated(unsafe) static var gameOptions: [String: UnsafeMutablePointer<CChar>] = [:]
    /// Set when `gameOptions` changes; answered (and cleared) by GET_VARIABLE_UPDATE so cores
    /// that poll it (PicoDrive) apply the change on the next frame.
    nonisolated(unsafe) static var optionsChanged = false

    static let overrides: [String: String] = [
        // The DS touch screen is driven by RETRO_DEVICE_POINTER (absolute touches), not a mouse.
        "melonds_touch_mode": "Touch",
        // 3D rendering on a second core; the CPU interpreter is the bottleneck without a JIT.
        "melonds_threaded_renderer": "enabled",
        // One frame with the top screen above the touch screen; the UI splits it at the fold.
        "melonds_screen_layout": "Top/Bottom",
        "melonds_screen_gap": "0",
        // N64: no JIT on iOS, so the cached interpreter; GLideN64 on OpenGL ES; HLE RSP.
        "mupen64plus-cpucore": "cached_interpreter",
        "mupen64plus-rdp-plugin": "gliden64",
        "mupen64plus-rsp-plugin": "hle",
        "mupen64plus-43screensize": "640x480",
        "mupen64plus-aspect": "4:3",
    ]
}

/// RETRO_ENVIRONMENT_EXPERIMENTAL is OR'd into a few command ids.
private let envExperimental: UInt32 = 0x10000

private func environmentCallback(_ cmd: UInt32, _ data: UnsafeMutableRawPointer?) -> Bool {
    switch cmd {
    case UInt32(RETRO_ENVIRONMENT_SET_PIXEL_FORMAT):
        // FrameBuffer stores RGB565, which snes9x and FCEUmm render natively. melonDS only
        // renders XRGB8888, which videoRefreshCallback converts.
        guard let data else { return false }
        let format = data.load(as: retro_pixel_format.self)
        guard format == RETRO_PIXEL_FORMAT_RGB565 || format == RETRO_PIXEL_FORMAT_XRGB8888 else { return false }
        corePixelFormats[apiSystem.coreName] = format
        return true

    case UInt32(RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY):
        guard let data else { return false }
        data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee =
            UnsafePointer(CoreEnvironment.systemDirectory)
        return CoreEnvironment.systemDirectory != nil

    case UInt32(RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY):
        guard let data else { return false }
        let dir = CoreEnvironment.saveDirectories[apiSystem]
        data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee = UnsafePointer(dir)
        return dir != nil

    case UInt32(RETRO_ENVIRONMENT_SET_VARIABLES):
        guard let data else { return false }
        registerVariables(data.assumingMemoryBound(to: retro_variable.self))
        return true

    case UInt32(RETRO_ENVIRONMENT_GET_VARIABLE):
        // Several snes9x call sites strcmp(var.value) without a NULL check, so we only ever
        // return true together with a non-NULL value.
        guard let data else { return false }
        let variable = data.assumingMemoryBound(to: retro_variable.self)
        guard let key = variable.pointee.key,
              let value = CoreEnvironment.gameOptions[String(cString: key)]
                ?? CoreEnvironment.variables[String(cString: key)] else {
            variable.pointee.value = nil
            return false
        }
        variable.pointee.value = UnsafePointer(value)
        return true

    case UInt32(RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE):
        guard let data else { return false }
        data.assumingMemoryBound(to: Bool.self).pointee = CoreEnvironment.optionsChanged
        CoreEnvironment.optionsChanged = false
        return true

    case UInt32(RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION):
        // Legacy options only: the core then describes its options with SET_VARIABLES.
        return false

    case UInt32(RETRO_ENVIRONMENT_GET_CAN_DUPE):
        data?.assumingMemoryBound(to: Bool.self).pointee = true
        return data != nil

    case UInt32(RETRO_ENVIRONMENT_SET_HW_RENDER):
        return duo_hw_set_render(data)

    case 56: // RETRO_ENVIRONMENT_GET_PREFERRED_HW_RENDER
        data?.assumingMemoryBound(to: UInt32.self).pointee = 4   // RETRO_HW_CONTEXT_OPENGLES3
        return data != nil

    case 44 | envExperimental: // RETRO_ENVIRONMENT_SET_HW_SHARED_CONTEXT
        return true

    case UInt32(RETRO_ENVIRONMENT_SET_DISK_CONTROL_INTERFACE):
        guard let data else { return false }
        diskControl = data.load(as: retro_disk_control_callback.self)
        return true

    case UInt32(DUO_ENVIRONMENT_GET_GAME_INFO_EXT):
        return duo_get_game_info_ext(data)

    case UInt32(RETRO_ENVIRONMENT_GET_LOG_INTERFACE):
        guard let data else { return false }
        return duo_install_log_interface(data)

    case 47 | envExperimental: // RETRO_ENVIRONMENT_GET_AUDIO_VIDEO_ENABLE
        // Bit 0 = render video, bit 1 = produce audio (cleared while fast-forwarding, which
        // makes snes9x discard its samples instead of mixing them).
        guard let data else { return false }
        let audioOn = activeHost?.audioEnabledThisFrame ?? true
        data.assumingMemoryBound(to: Int32.self).pointee = audioOn ? 0b11 : 0b01
        return true

    case 51 | envExperimental: // RETRO_ENVIRONMENT_GET_INPUT_BITMASKS
        return true

    case UInt32(RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS),
         UInt32(RETRO_ENVIRONMENT_SET_CONTROLLER_INFO),
         UInt32(RETRO_ENVIRONMENT_SET_SUBSYSTEM_INFO),
         UInt32(RETRO_ENVIRONMENT_SET_PERFORMANCE_LEVEL),
         UInt32(RETRO_ENVIRONMENT_SET_GEOMETRY),
         UInt32(RETRO_ENVIRONMENT_SET_SUPPORT_ACHIEVEMENTS):
        // Informational; FrameBuffer follows each frame's own width/height.
        return true

    default:
        return false
    }
}

/// Parses legacy `{ key, "Description; default|other|..." }` pairs and records each
/// option's default (the first listed value).
private func registerVariables(_ list: UnsafeMutablePointer<retro_variable>) {
    var p = list
    while let key = p.pointee.key {
        let name = String(cString: key)
        var value: String?
        if let raw = p.pointee.value {
            let spec = String(cString: raw)
            if let semicolon = spec.range(of: "; ") {
                value = spec[semicolon.upperBound...].split(separator: "|").first.map(String.init)
            }
        }
        if let value = CoreEnvironment.overrides[name] ?? value {
            if let old = CoreEnvironment.variables[name] { free(old) }
            CoreEnvironment.variables[name] = strdup(value)
        }
        p += 1
    }
}

private func videoRefreshCallback(_ data: UnsafeRawPointer?, _ width: UInt32, _ height: UInt32, _ pitch: Int) {
    // data == NULL is a dupe frame (we advertise GET_CAN_DUPE): keep showing the last one.
    guard let data, width > 0, height > 0, let host = activeHost else { return }
    if data == UnsafeRawPointer(bitPattern: -1) {
        // RETRO_HW_FRAME_BUFFER_VALID: the core drew this frame with OpenGL ES.
        let w = min(Int(width), FrameBuffer.maxWidth), h = min(Int(height), FrameBuffer.maxHeight)
        guard duo_hw_read_frame(Int32(w), Int32(h), host.conversionBuffer, w * 2) else { return }
        host.frameBuffer.submit(host.conversionBuffer, width: w, height: h, pitch: w * 2)
        return
    }
    guard corePixelFormats[apiSystem.coreName] == RETRO_PIXEL_FORMAT_XRGB8888 else {
        host.frameBuffer.submit(data, width: Int(width), height: Int(height), pitch: pitch)
        return
    }
    // XRGB8888 -> RGB565 into a scratch frame (DS: 256x384, ~100K pixels).
    let w = min(Int(width), FrameBuffer.maxWidth), h = min(Int(height), FrameBuffer.maxHeight)
    let out = host.conversionBuffer
    for y in 0..<h {
        let row = (data + y * pitch).assumingMemoryBound(to: UInt32.self)
        for x in 0..<w {
            let p = row[x]
            out[y * w + x] = UInt16(truncatingIfNeeded: (p >> 8) & 0xF800 | (p >> 5) & 0x07E0 | (p >> 3) & 0x001F)
        }
    }
    host.frameBuffer.submit(out, width: w, height: h, pitch: w * 2)
}

private func audioSampleCallback(_ left: Int16, _ right: Int16) {
    guard let host = activeHost, host.audioEnabledThisFrame else { return }
    var pair = (left, right)
    withUnsafePointer(to: &pair) {
        $0.withMemoryRebound(to: Int16.self, capacity: 2) { host.writeAudio($0, frames: 1) }
    }
}

private func audioBatchCallback(_ data: UnsafePointer<Int16>?, _ frames: Int) -> Int {
    guard let data, frames > 0, let host = activeHost, host.audioEnabledThisFrame else { return frames }
    host.writeAudio(data, frames: frames)
    // Report everything as consumed: a full ring drops samples rather than stalling the core.
    return frames
}

private func inputPollCallback() {
    activeHost?.pollInput()
}

private func inputStateCallback(_ port: UInt32, _ device: UInt32, _ index: UInt32, _ id: UInt32) -> Int16 {
    if device & 0xFF == UInt32(RETRO_DEVICE_POINTER) {
        guard port == 0, index == 0 else { return 0 }
        let pointer = InputHub.shared.pointer
        switch id {
        case UInt32(RETRO_DEVICE_ID_POINTER_X): return pointer.x
        case UInt32(RETRO_DEVICE_ID_POINTER_Y): return pointer.y
        case UInt32(RETRO_DEVICE_ID_POINTER_PRESSED): return pointer.pressed ? 1 : 0
        default: return 0
        }
    }
    if device & 0xFF == UInt32(RETRO_DEVICE_ANALOG) {
        // index 0/1 = left/right stick, id 0/1 = x/y. Analog button pressure isn't emulated.
        guard port < UInt32(InputHub.maxPlayers), index < 2, id < 2 else { return 0 }
        var stick = InputHub.shared.stick(Int(index), player: Int(port))
        if index == 1, apiSystem == .n64, let host = activeHost {
            // N64 C buttons: Mupen64Plus reads them from the right stick.
            let c = SNESButtons(rawValue: host.polledButtons[Int(port)])
            if c.contains(.cLeft) { stick.x = -32767 } else if c.contains(.cRight) { stick.x = 32767 }
            if c.contains(.cUp) { stick.y = -32767 } else if c.contains(.cDown) { stick.y = 32767 }
        }
        return id == 0 ? stick.x : stick.y
    }
    guard let host = activeHost,
          device & 0xFF == UInt32(RETRO_DEVICE_JOYPAD), // RETRO_DEVICE_MASK: base type, ignoring subclass
          port < UInt32(InputHub.maxPlayers) else { return 0 }
    let mask = host.polledButtons[Int(port)]
    if id == UInt32(RETRO_DEVICE_ID_JOYPAD_MASK) {
        return Int16(truncatingIfNeeded: mask & 0xFFFF)
    }
    guard id < 16 else { return 0 }
    return Int16((mask >> id) & 1)
}

// MARK: - EmulatorCore

/// Hosts the libretro core for the loaded game (snes9x, FCEUmm or melonDS) on a dedicated
/// emulation thread.
///
/// Threading: every public method may be called from the main thread (or any thread); they
/// are serialized among themselves, and anything that touches the core waits for the
/// in-flight frame (at most ~16 ms). The core's callbacks run on the emulation thread.
final class EmulatorCore: @unchecked Sendable {
    static let shared = EmulatorCore()

    let frameBuffer = FrameBuffer()
    /// Scratch frame for converting XRGB8888 cores' output to RGB565 (emulation thread only).
    fileprivate let conversionBuffer = UnsafeMutablePointer<UInt16>.allocate(
        capacity: FrameBuffer.maxWidth * FrameBuffer.maxHeight)

    deinit { conversionBuffer.deallocate() }
    let audio = AudioRingBuffer()
    let input = InputHub.shared

    /// Valid after `load`. NTSC ≈ 60.0988, PAL ≈ 50.007.
    private(set) var frameRate: Double = 60.0988
    /// Valid after `load`. snes9x reports 32040 Hz.
    private(set) var sampleRate: Double = 32040
    private(set) var loadedROM: URL?
    /// Picture aspect the core reports (arcade games vary, and some are vertical); nil when
    /// the core leaves it to the frontend. Valid after `load`.
    private(set) var displayAspect: Double?
    /// System of the loaded game (valid after `load`).
    private(set) var system: GameSystem = .snes
    /// The loaded core draws with OpenGL ES; its context must be current around `run`.
    private var usesHardwareRender = false
    private(set) var isRunning = false
    /// Runs the core as fast as possible (audio is dropped while true).
    /// False for throwaway runs (title-screen artwork captures): battery saves are neither
    /// loaded nor written and no auto-save state is made, so the player's progress is never
    /// touched. Set before `load`.
    var persistsSaves = true

    var fastForward: Bool {
        get { fastForwardFlag.load(ordering: .relaxed) }
        set { fastForwardFlag.store(newValue, ordering: .relaxed) }
    }

    /// Fast-forward speed cap, as a multiple of normal speed.
    static let fastForwardMultiplier = 4.0
    /// How often the emulation thread checks battery RAM for changes.
    static let sramFlushInterval: TimeInterval = 10

    private let fastForwardFlag = Atomic<Bool>(false)

    // Emulation thread control (guarded by `runCondition`).
    private let runCondition = NSCondition()
    private var shouldRun = false
    private var shouldExit = false
    private var threadDone: DispatchSemaphore?

    // Touched only with `coreLock` held (core callbacks, emulation thread, API calls).
    fileprivate var audioEnabledThisFrame = true
    fileprivate var polledButtons: [UInt32] = [0, 0]
    private var lastSavedSRAM: Data?
    /// Frames emulated since the game was loaded (or a state restored). The auto-save on
    /// unload is skipped when zero so an untouched load never clobbers a suspend state.
    private var framesSinceLoad = 0
    private var audioFramesWritten = 0

    // MARK: Loading

    func load(rom: URL) throws {
        apiLock.lock(); defer { apiLock.unlock() }

        if loadedROM != nil { unload() }
        if let other = coreLock.withLock({ activeHost }), other !== self { other.unload() }

        let content = try Self.readROM(at: rom)
        GamePaths.ensureDirectories()

        try coreLock.withLock {
            api = content.system.coreAPI
            apiSystem = content.system
            diskControl = nil
            Self.initializeCoreIfNeeded(content.system)
            activeHost = self
            let loaded = content.path.withCString { path in
                content.data.withUnsafeBytes { buffer -> Bool in
                    // Empty data (disc images): the core opens `path` itself.
                    let bytes = buffer.isEmpty ? nil : buffer.baseAddress
                    duo_set_game_info_ext(path, content.archivePath, content.archiveFile,
                                          bytes, buffer.count)
                    defer { duo_clear_game_info_ext() }
                    // Both cores report need_fullpath = false and copy the bytes (snes9x also
                    // strips any 512-byte copier header itself), so the buffer can go away after.
                    var info = retro_game_info(path: path, data: bytes, size: buffer.count, meta: nil)
                    return api.load_game(&info)
                }
            }
            guard loaded else {
                activeHost = nil
                duo_hw_stop()
                throw content.system.isArcade
                    ? EmulatorError.arcadeSetRejected(rom.lastPathComponent)
                    : EmulatorError.coreRejectedROM
            }
            // Cores that draw with OpenGL ES (N64) asked for a context while loading.
            usesHardwareRender = duo_hw_requested()
            if usesHardwareRender {
                guard duo_hw_start(Int32(FrameBuffer.maxWidth), Int32(FrameBuffer.maxHeight)) else {
                    api.unload_game()
                    duo_hw_stop()
                    usesHardwareRender = false
                    activeHost = nil
                    throw EmulatorError.coreRejectedROM
                }
                // The emulation thread makes it current before each frame.
                duo_hw_release_current()
            }
            // PlayStation: a DualShock (RETRO_DEVICE_SUBCLASS(ANALOG, 1) in PCSX), so games
            // read the sticks; everything else: a plain joypad.
            let device = content.system == .psx ? UInt32(RETRO_DEVICE_ANALOG) | (2 << 8) : UInt32(RETRO_DEVICE_JOYPAD)
            for port in 0..<UInt32(InputHub.maxPlayers) {
                api.set_controller_port_device(port, device)
            }

            var av = retro_system_av_info()
            api.get_system_av_info(&av)
            frameRate = av.timing.fps > 1 ? av.timing.fps : 60.0988
            sampleRate = av.timing.sample_rate > 1 ? av.timing.sample_rate : 32040
            displayAspect = av.geometry.aspect_ratio > 0.1 ? Double(av.geometry.aspect_ratio) : nil

            polledButtons = [0, 0]
            framesSinceLoad = 0
            system = content.system
            loadSRAMLocked(for: rom)
        }

        loadedROM = rom
        isRunning = false
        startThread()
        let discs = discCount
        log.notice("Loaded \(rom.lastPathComponent, privacy: .public) (\(self.system.rawValue, privacy: .public)) at \(self.frameRate) fps\(discs > 1 ? ", \(discs) discs" : "", privacy: .public)")
    }

    /// A ROM ready to hand to a core.
    private struct Content {
        var data: Data
        var system: GameSystem
        /// What the core is told the game is called. Cores such as FCEUmm pick the format
        /// from its extension, so for a zip this names the ROM inside, next to the archive.
        var path: String
        /// Set when the ROM came out of an archive (for GET_GAME_INFO_EXT).
        var archivePath: String?
        var archiveFile: String?
    }

    /// Reads a ROM file, unwrapping `.zip` archives, and works out which system it's for.
    /// Copier headers are left for snes9x.
    private static func readROM(at url: URL) throws -> Content {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        if let system = GameSystem.of(rom: url), system.loadsFromPath {
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                throw EmulatorError.romUnreadable(url)
            }
            let bios = system.requiredBIOS
            if !bios.isEmpty, !bios.contains(where: {
                FileManager.default.fileExists(atPath: GamePaths.system.appending(path: $0).path)
            }) {
                throw EmulatorError.missingBIOS(system)
            }
            return Content(data: Data(), system: system, path: url.path)
        }

        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), !data.isEmpty,
              data.count <= ZipArchive.maxEntrySize else {
            throw EmulatorError.romUnreadable(url)
        }
        let isZip = url.pathExtension.lowercased() == "zip"
            || data.prefix(4).elementsEqual([0x50, 0x4B, 0x03, 0x04])
        guard isZip else {
            guard let system = GameSystem(romExtension: url.pathExtension) else {
                throw EmulatorError.romUnreadable(url)
            }
            return Content(data: data, system: system, path: url.path)
        }
        let entry = try ZipArchive.extractFirstROM(from: [UInt8](data))
        let innerName = entry.name.split(separator: "/").last.map(String.init) ?? entry.name
        guard let system = GameSystem(romExtension: (innerName as NSString).pathExtension) else {
            throw EmulatorError.romUnreadable(url)
        }
        return Content(data: entry.data, system: system,
                       path: url.deletingLastPathComponent().appending(path: innerName).path,
                       archivePath: url.path, archiveFile: entry.name)
    }

    /// retro_set_environment / retro_init run once per process per core; both cores support
    /// loading game after game without retro_deinit. Caller holds `coreLock` and has pointed
    /// `api` at `system`'s core.
    private static func initializeCoreIfNeeded(_ system: GameSystem) {
        guard !initializedCores.contains(system.coreName) else { return }
        GamePaths.ensureDirectories()
        if CoreEnvironment.systemDirectory == nil {
            CoreEnvironment.systemDirectory = strdup(GamePaths.system.path)
        }
        if CoreEnvironment.saveDirectories[system] == nil {
            // GamePaths.sram's folder for this system (Saves/ or Saves/<system>/).
            let folder = GamePaths.sram(for: URL(filePath: "/x"), system: system).deletingLastPathComponent()
            CoreEnvironment.saveDirectories[system] = strdup(folder.path)
        }

        var info = retro_system_info()
        api.get_system_info(&info)
        if info.need_fullpath {
            // PicoDrive says so but takes in-memory data offered via GET_GAME_INFO_EXT.
            log.info("\(system.coreName, privacy: .public) reports need_fullpath; ROM data is offered through GET_GAME_INFO_EXT")
        }

        api.set_environment(environmentCallback)
        api.set_video_refresh(videoRefreshCallback)
        api.set_audio_sample(audioSampleCallback)
        api.set_audio_sample_batch(audioBatchCallback)
        api.set_input_poll(inputPollCallback)
        api.set_input_state(inputStateCallback)
        api.`init`()
        initializedCores.insert(system.coreName)
    }

    // MARK: Run control

    /// Starts or resumes the emulation thread.
    func resume() {
        apiLock.lock(); defer { apiLock.unlock() }
        guard loadedROM != nil else { return }
        runCondition.lock()
        shouldRun = true
        runCondition.broadcast()
        runCondition.unlock()
        isRunning = true
    }

    /// Pauses after the current frame and flushes SRAM to disk.
    func pause() {
        apiLock.lock(); defer { apiLock.unlock() }
        runCondition.lock()
        shouldRun = false
        runCondition.unlock()
        // The emulation thread re-checks `shouldRun` with coreLock held, so once we own the
        // lock no further frame will run.
        coreLock.withLock { flushSRAMLocked() }
        isRunning = false
    }

    /// Pauses, writes SRAM + auto-save state (slot 0), and unloads the game.
    func unload() {
        apiLock.lock(); defer { apiLock.unlock() }
        guard let rom = loadedROM else { isRunning = false; return }

        stopThread()
        coreLock.withLock {
            flushSRAMLocked()
            if persistsSaves && framesSinceLoad > 0 {
                do {
                    try Self.writeAtomically(try serializeLocked(), to: GamePaths.state(for: rom, slot: 0, system: system))
                } catch {
                    log.error("Auto-save failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            if usesHardwareRender { duo_hw_make_current() }
            api.unload_game()
            if usesHardwareRender {
                duo_hw_stop()
                usesHardwareRender = false
            }
            if activeHost === self { activeHost = nil }
            lastSavedSRAM = nil
        }
        loadedROM = nil
        isRunning = false
        fastForward = false
    }

    // MARK: Discs

    /// Number of discs in the loaded game (a multi-disc .m3u playlist); 1 or 0 otherwise.
    var discCount: Int {
        coreLock.withLock {
            guard loadedROM != nil, let count = diskControl?.get_num_images?() else { return 0 }
            return Int(count)
        }
    }

    /// Zero-based index of the disc in the drive.
    var currentDisc: Int {
        coreLock.withLock { Int(diskControl?.get_image_index?() ?? 0) }
    }

    /// Swaps discs the way a player would: open the lid, change the disc, close the lid.
    @discardableResult
    func insertDisc(_ index: Int) -> Bool {
        apiLock.lock(); defer { apiLock.unlock() }
        return coreLock.withLock {
            guard loadedROM != nil, let control = diskControl,
                  let count = control.get_num_images?(), index >= 0, index < Int(count),
                  control.set_eject_state?(true) == true else { return false }
            let swapped = control.set_image_index?(UInt32(index)) == true
            _ = control.set_eject_state?(false)
            return swapped
        }
    }

    /// Sets a core option for the current or next game (e.g. PicoDrive's controller type).
    /// Read at load, and applied on the next frame by cores that poll for option changes.
    func setCoreOption(_ key: String, _ value: String) {
        coreLock.withLock {
            if let old = CoreEnvironment.gameOptions[key] {
                if String(cString: old) == value { return }
                free(old)
            }
            CoreEnvironment.gameOptions[key] = strdup(value)
            CoreEnvironment.optionsChanged = true
        }
    }

    func reset() {
        apiLock.lock(); defer { apiLock.unlock() }
        guard loadedROM != nil else { return }
        coreLock.withLock { api.reset() }
    }

    // MARK: Save states

    func saveState(slot: Int) throws {
        apiLock.lock(); defer { apiLock.unlock() }
        guard let rom = loadedROM else { throw EmulatorError.noGameLoaded }
        let data = try coreLock.withLock { try serializeLocked() }
        try Self.writeAtomically(data, to: GamePaths.state(for: rom, slot: slot, system: system))
    }

    func loadState(slot: Int) throws {
        apiLock.lock(); defer { apiLock.unlock() }
        guard let rom = loadedROM else { throw EmulatorError.noGameLoaded }
        let url = GamePaths.state(for: rom, slot: slot, system: system)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            throw EmulatorError.stateFailed("slot \(slot) is empty")
        }
        try coreLock.withLock {
            let ok = data.withUnsafeBytes { api.unserialize($0.baseAddress, $0.count) }
            guard ok else { throw EmulatorError.stateFailed("slot \(slot) doesn't match this game") }
            framesSinceLoad = 1
        }
    }

    func hasState(slot: Int) -> Bool {
        apiLock.lock(); defer { apiLock.unlock() }
        guard let rom = loadedROM else { return false }
        return FileManager.default.fileExists(atPath: GamePaths.state(for: rom, slot: slot, system: system).path)
    }

    /// Caller holds `coreLock`.
    private func serializeLocked() throws -> Data {
        let size = api.serialize_size()
        guard size > 0 else { throw EmulatorError.stateFailed("the core has no state to save") }
        var data = Data(count: size)
        let ok = data.withUnsafeMutableBytes { api.serialize($0.baseAddress, size) }
        guard ok else { throw EmulatorError.stateFailed("the core couldn't serialize") }
        return data
    }

    private static func writeAtomically(_ data: Data, to url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw EmulatorError.stateFailed(error.localizedDescription)
        }
    }

    // MARK: Battery RAM

    func flushSRAM() {
        apiLock.lock(); defer { apiLock.unlock() }
        coreLock.withLock { flushSRAMLocked() }
    }

    /// The core's battery RAM, or nil when the cartridge has none. Caller holds `coreLock`.
    private func sramRegionLocked() -> UnsafeMutableRawBufferPointer? {
        let size = api.get_memory_size(UInt32(RETRO_MEMORY_SAVE_RAM))
        guard size > 0, let base = api.get_memory_data(UInt32(RETRO_MEMORY_SAVE_RAM)) else { return nil }
        return UnsafeMutableRawBufferPointer(start: base, count: size)
    }

    /// Copies a saved .srm into the core (call after retro_load_game, which clears SRAM).
    private func loadSRAMLocked(for rom: URL) {
        guard persistsSaves, let region = sramRegionLocked() else { lastSavedSRAM = nil; return }
        if let saved = try? Data(contentsOf: GamePaths.sram(for: rom, system: system)), !saved.isEmpty {
            let n = min(saved.count, region.count)
            saved.withUnsafeBytes { region.baseAddress!.copyMemory(from: $0.baseAddress!, byteCount: n) }
            if saved.count != region.count {
                log.notice("SRAM file is \(saved.count) bytes, cartridge has \(region.count)")
            }
        }
        lastSavedSRAM = Data(region)
    }

    /// Writes battery RAM to disk if it changed since the last write. Caller holds `coreLock`.
    private func flushSRAMLocked() {
        guard persistsSaves, let rom = loadedROM, let region = sramRegionLocked() else { return }
        let current = Data(region)
        guard current != lastSavedSRAM else { return }
        do {
            try FileManager.default.createDirectory(at: GamePaths.saves, withIntermediateDirectories: true)
            try current.write(to: GamePaths.sram(for: rom, system: system), options: .atomic)
            lastSavedSRAM = current
        } catch {
            log.error("SRAM write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Emulation thread

    private func startThread() {
        runCondition.lock()
        shouldRun = false
        shouldExit = false
        runCondition.unlock()

        let done = DispatchSemaphore(value: 0)
        threadDone = done
        let thread = Thread { [self] in
            emulationLoop()
            done.signal()
        }
        thread.name = "Duomulator.emulation"
        thread.qualityOfService = .userInteractive
        thread.stackSize = 4 << 20
        thread.start()
    }

    private func stopThread() {
        guard let done = threadDone else { return }
        runCondition.lock()
        shouldExit = true
        shouldRun = false
        runCondition.broadcast()
        runCondition.unlock()
        done.wait()
        threadDone = nil
    }

    private func emulationLoop() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticksPerSecond = 1e9 * Double(timebase.denom) / Double(timebase.numer)
        let sramInterval = UInt64(Self.sramFlushInterval * ticksPerSecond)

        var deadline = mach_absolute_time()
        var lastSRAMCheck = deadline
        var lastConsumed = 0

        while true {
            runCondition.lock()
            var waited = false
            while !shouldRun && !shouldExit {
                runCondition.wait()
                waited = true
            }
            let exiting = shouldExit
            runCondition.unlock()
            if exiting { break }
            if waited { deadline = mach_absolute_time() }

            let turbo = fastForward
            coreLock.lock()
            // Re-check under the core lock so pause() returns with no frame in flight.
            runCondition.lock()
            let go = shouldRun && !shouldExit
            runCondition.unlock()
            if go {
                audioEnabledThisFrame = !turbo
                if usesHardwareRender { duo_hw_make_current() }
                api.run()
                framesSinceLoad += 1
                let now = mach_absolute_time()
                if now &- lastSRAMCheck >= sramInterval {
                    lastSRAMCheck = now
                    flushSRAMLocked()
                }
            }
            let written = audioFramesWritten
            coreLock.unlock()
            guard go else { continue }

            // Light dynamic rate control: nudge the frame period ±0.5% to keep the audio ring
            // between 1/8 and 1/2 full, but only while something is actually draining it.
            var period = ticksPerSecond / frameRate
            if turbo {
                period /= Self.fastForwardMultiplier
            } else {
                let available = audio.availableFrames
                let consumed = written - available
                if consumed != lastConsumed {
                    if available < audio.capacity / 8 { period *= 0.995 }
                    else if available > audio.capacity / 2 { period *= 1.005 }
                }
                lastConsumed = consumed
            }

            deadline &+= UInt64(period)
            let now = mach_absolute_time()
            if deadline > now {
                mach_wait_until(deadline)
            } else if now - deadline > UInt64(period * 4) {
                // Fell well behind (debugger, heavy SuperFX scene): don't sprint to catch up.
                deadline = now
            }
        }
    }

    // MARK: Callback helpers (emulation thread, coreLock held)

    fileprivate func writeAudio(_ samples: UnsafePointer<Int16>, frames: Int) {
        audioFramesWritten &+= audio.write(samples, frames: frames)
    }

    fileprivate func pollInput() {
        for player in 0..<polledButtons.count {
            polledButtons[player] = input.buttons(player: player).rawValue
        }
    }

    // MARK: Test hooks (internal)

    /// Runs `n` frames synchronously on the calling thread, unpaced, with audio enabled.
    func runFrames(_ n: Int) {
        apiLock.lock(); defer { apiLock.unlock() }
        guard loadedROM != nil else { return }
        coreLock.withLock {
            audioEnabledThisFrame = true
            if usesHardwareRender { duo_hw_make_current() }
            for _ in 0..<n { api.run() }
            framesSinceLoad += n
        }
    }

    /// Total stereo frames accepted by `audio` (samples a full ring dropped aren't counted).
    var audioFramesProduced: Int {
        coreLock.withLock { audioFramesWritten }
    }

    /// A copy of the cartridge's battery RAM, or nil when it has none.
    func sramContents() -> Data? {
        apiLock.lock(); defer { apiLock.unlock() }
        guard loadedROM != nil else { return nil }
        return coreLock.withLock { sramRegionLocked().map { Data($0) } }
    }

    /// Overwrites the start of battery RAM (as if the game had written it).
    func pokeSRAM(_ bytes: Data) {
        apiLock.lock(); defer { apiLock.unlock() }
        guard loadedROM != nil else { return }
        coreLock.withLock {
            guard let region = sramRegionLocked() else { return }
            let n = min(bytes.count, region.count)
            bytes.withUnsafeBytes { region.baseAddress!.copyMemory(from: $0.baseAddress!, byteCount: n) }
        }
    }
}
