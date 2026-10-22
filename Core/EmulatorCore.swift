import Foundation
import Synchronization
import os

enum EmulatorError: Error, LocalizedError {
    case romUnreadable(URL), coreRejectedROM, noGameLoaded, stateFailed(String)
    /// A `.zip` that can't be used: no ROM inside, unsupported method, or damaged.
    case unsupportedArchive(String)

    var errorDescription: String? {
        switch self {
        case .romUnreadable(let url): "Couldn't read \(url.lastPathComponent)."
        case .coreRejectedROM: "This file isn't a SNES ROM that snes9x can run."
        case .noGameLoaded: "No game is loaded."
        case .stateFailed(let detail): "Save state failed: \(detail)"
        case .unsupportedArchive(let detail): detail
        }
    }
}

private let log = Logger(subsystem: "io.kurast.duomulator", category: "core")

// MARK: - Process-wide libretro state

/// snes9x is a static library full of globals, so there is exactly one emulated console per
/// process. Every retro_* call happens with `coreLock` held; the core's callbacks only fire
/// from inside those calls, so they see `activeHost` (the EmulatorCore that owns the loaded
/// game) and the environment tables consistently. Public API calls are serialized by
/// `apiLock` (recursive, because `load` unloads whatever was loaded before).
private let coreLock = NSLock()
private let apiLock = NSRecursiveLock()
nonisolated(unsafe) private var activeHost: EmulatorCore?
nonisolated(unsafe) private var coreInitialized = false

/// C strings handed to the core. libretro requires them to outlive the call that returned
/// them, so they are allocated once and kept for the life of the process.
private enum CoreEnvironment {
    nonisolated(unsafe) static var systemDirectory: UnsafeMutablePointer<CChar>?
    nonisolated(unsafe) static var saveDirectory: UnsafeMutablePointer<CChar>?
    /// Core option key -> value, filled from the defaults the core declares via the legacy
    /// SET_VARIABLES call (we answer GET_CORE_OPTIONS_VERSION with false).
    /// The defaults are what we want: overscan cropped to 224 lines, no NTSC filter, no
    /// opposing d-pad directions, no memory randomization.
    nonisolated(unsafe) static var variables: [String: UnsafeMutablePointer<CChar>] = [:]
}

/// RETRO_ENVIRONMENT_EXPERIMENTAL is OR'd into a few command ids.
private let envExperimental: UInt32 = 0x10000

private func environmentCallback(_ cmd: UInt32, _ data: UnsafeMutableRawPointer?) -> Bool {
    switch cmd {
    case UInt32(RETRO_ENVIRONMENT_SET_PIXEL_FORMAT):
        // FrameBuffer stores RGB565, which is also what snes9x renders natively.
        guard let data else { return false }
        return data.load(as: retro_pixel_format.self) == RETRO_PIXEL_FORMAT_RGB565

    case UInt32(RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY):
        guard let data else { return false }
        data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee =
            UnsafePointer(CoreEnvironment.systemDirectory)
        return CoreEnvironment.systemDirectory != nil

    case UInt32(RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY):
        guard let data else { return false }
        data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee =
            UnsafePointer(CoreEnvironment.saveDirectory)
        return CoreEnvironment.saveDirectory != nil

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
              let value = CoreEnvironment.variables[String(cString: key)] else {
            variable.pointee.value = nil
            return false
        }
        variable.pointee.value = UnsafePointer(value)
        return true

    case UInt32(RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE):
        data?.assumingMemoryBound(to: Bool.self).pointee = false
        return data != nil

    case UInt32(RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION):
        // Legacy options only: the core then describes its options with SET_VARIABLES.
        return false

    case UInt32(RETRO_ENVIRONMENT_GET_CAN_DUPE):
        data?.assumingMemoryBound(to: Bool.self).pointee = true
        return data != nil

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
        if let value {
            if let old = CoreEnvironment.variables[name] { free(old) }
            CoreEnvironment.variables[name] = strdup(value)
        }
        p += 1
    }
}

private func videoRefreshCallback(_ data: UnsafeRawPointer?, _ width: UInt32, _ height: UInt32, _ pitch: Int) {
    // data == NULL is a dupe frame (we advertise GET_CAN_DUPE): keep showing the last one.
    guard let data, width > 0, height > 0, let host = activeHost else { return }
    host.frameBuffer.submit(data, width: Int(width), height: Int(height), pitch: pitch)
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
    guard let host = activeHost,
          device & 0xFF == UInt32(RETRO_DEVICE_JOYPAD), // RETRO_DEVICE_MASK: base type, ignoring subclass
          port < UInt32(InputHub.maxPlayers) else { return 0 }
    let mask = host.polledButtons[Int(port)]
    if id == UInt32(RETRO_DEVICE_ID_JOYPAD_MASK) {
        return Int16(truncatingIfNeeded: mask & 0xFFF)
    }
    guard id < 16 else { return 0 }
    return Int16((mask >> id) & 1)
}

// MARK: - EmulatorCore

/// Hosts the snes9x libretro core on a dedicated emulation thread.
///
/// Threading: every public method may be called from the main thread (or any thread); they
/// are serialized among themselves, and anything that touches the core waits for the
/// in-flight frame (at most ~16 ms). The core's callbacks run on the emulation thread.
final class EmulatorCore: @unchecked Sendable {
    static let shared = EmulatorCore()

    let frameBuffer = FrameBuffer()
    let audio = AudioRingBuffer()
    let input = InputHub.shared

    /// Valid after `load`. NTSC ≈ 60.0988, PAL ≈ 50.007.
    private(set) var frameRate: Double = 60.0988
    /// Valid after `load`. snes9x reports 32040 Hz.
    private(set) var sampleRate: Double = 32040
    private(set) var loadedROM: URL?
    private(set) var isRunning = false
    /// Runs the core as fast as possible (audio is dropped while true).
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

        let bytes = try Self.readROM(at: rom)
        GamePaths.ensureDirectories()

        try coreLock.withLock {
            Self.initializeCoreIfNeeded()
            activeHost = self
            let loaded = rom.path.withCString { path in
                bytes.withUnsafeBytes { buffer -> Bool in
                    // snes9x reports need_fullpath = false and copies the bytes (stripping
                    // any 512-byte copier header itself), so the buffer can go away after.
                    var info = retro_game_info(path: path, data: buffer.baseAddress,
                                               size: buffer.count, meta: nil)
                    return retro_load_game(&info)
                }
            }
            guard loaded else {
                activeHost = nil
                throw EmulatorError.coreRejectedROM
            }
            for port in 0..<UInt32(InputHub.maxPlayers) {
                retro_set_controller_port_device(port, UInt32(RETRO_DEVICE_JOYPAD))
            }

            var av = retro_system_av_info()
            retro_get_system_av_info(&av)
            frameRate = av.timing.fps > 1 ? av.timing.fps : 60.0988
            sampleRate = av.timing.sample_rate > 1 ? av.timing.sample_rate : 32040

            polledButtons = [0, 0]
            framesSinceLoad = 0
            loadSRAMLocked(for: rom)
        }

        loadedROM = rom
        isRunning = false
        startThread()
        log.info("Loaded \(rom.lastPathComponent, privacy: .public) at \(self.frameRate) fps")
    }

    /// Reads a ROM file, unwrapping `.zip` archives. Copier headers are left for snes9x.
    private static func readROM(at url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), !data.isEmpty,
              data.count <= ZipArchive.maxEntrySize else {
            throw EmulatorError.romUnreadable(url)
        }
        let isZip = url.pathExtension.lowercased() == "zip"
            || data.prefix(4).elementsEqual([0x50, 0x4B, 0x03, 0x04])
        guard isZip else { return data }
        return try ZipArchive.extractFirstROM(from: [UInt8](data)).data
    }

    /// retro_set_environment / retro_init run once per process; snes9x supports loading game
    /// after game without retro_deinit. Caller holds `coreLock`.
    private static func initializeCoreIfNeeded() {
        guard !coreInitialized else { return }
        GamePaths.ensureDirectories()
        CoreEnvironment.systemDirectory = strdup(GamePaths.system.path)
        CoreEnvironment.saveDirectory = strdup(GamePaths.saves.path)

        var info = retro_system_info()
        retro_get_system_info(&info)
        if info.need_fullpath {
            log.error("Core unexpectedly requires need_fullpath; in-memory loading may fail")
        }

        retro_set_environment(environmentCallback)
        retro_set_video_refresh(videoRefreshCallback)
        retro_set_audio_sample(audioSampleCallback)
        retro_set_audio_sample_batch(audioBatchCallback)
        retro_set_input_poll(inputPollCallback)
        retro_set_input_state(inputStateCallback)
        retro_init()
        coreInitialized = true
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
            if framesSinceLoad > 0 {
                do {
                    try Self.writeAtomically(try serializeLocked(), to: GamePaths.state(for: rom, slot: 0))
                } catch {
                    log.error("Auto-save failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            retro_unload_game()
            if activeHost === self { activeHost = nil }
            lastSavedSRAM = nil
        }
        loadedROM = nil
        isRunning = false
        fastForward = false
    }

    func reset() {
        apiLock.lock(); defer { apiLock.unlock() }
        guard loadedROM != nil else { return }
        coreLock.withLock { retro_reset() }
    }

    // MARK: Save states

    func saveState(slot: Int) throws {
        apiLock.lock(); defer { apiLock.unlock() }
        guard let rom = loadedROM else { throw EmulatorError.noGameLoaded }
        let data = try coreLock.withLock { try serializeLocked() }
        try Self.writeAtomically(data, to: GamePaths.state(for: rom, slot: slot))
    }

    func loadState(slot: Int) throws {
        apiLock.lock(); defer { apiLock.unlock() }
        guard let rom = loadedROM else { throw EmulatorError.noGameLoaded }
        let url = GamePaths.state(for: rom, slot: slot)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            throw EmulatorError.stateFailed("slot \(slot) is empty")
        }
        try coreLock.withLock {
            let ok = data.withUnsafeBytes { retro_unserialize($0.baseAddress, $0.count) }
            guard ok else { throw EmulatorError.stateFailed("slot \(slot) doesn't match this game") }
            framesSinceLoad = 1
        }
    }

    func hasState(slot: Int) -> Bool {
        apiLock.lock(); defer { apiLock.unlock() }
        guard let rom = loadedROM else { return false }
        return FileManager.default.fileExists(atPath: GamePaths.state(for: rom, slot: slot).path)
    }

    /// Caller holds `coreLock`.
    private func serializeLocked() throws -> Data {
        let size = retro_serialize_size()
        guard size > 0 else { throw EmulatorError.stateFailed("the core has no state to save") }
        var data = Data(count: size)
        let ok = data.withUnsafeMutableBytes { retro_serialize($0.baseAddress, size) }
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
        let size = retro_get_memory_size(UInt32(RETRO_MEMORY_SAVE_RAM))
        guard size > 0, let base = retro_get_memory_data(UInt32(RETRO_MEMORY_SAVE_RAM)) else { return nil }
        return UnsafeMutableRawBufferPointer(start: base, count: size)
    }

    /// Copies a saved .srm into the core (call after retro_load_game, which clears SRAM).
    private func loadSRAMLocked(for rom: URL) {
        guard let region = sramRegionLocked() else { lastSavedSRAM = nil; return }
        if let saved = try? Data(contentsOf: GamePaths.sram(for: rom)), !saved.isEmpty {
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
        guard let rom = loadedROM, let region = sramRegionLocked() else { return }
        let current = Data(region)
        guard current != lastSavedSRAM else { return }
        do {
            try FileManager.default.createDirectory(at: GamePaths.saves, withIntermediateDirectories: true)
            try current.write(to: GamePaths.sram(for: rom), options: .atomic)
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
                retro_run()
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
            for _ in 0..<n { retro_run() }
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
