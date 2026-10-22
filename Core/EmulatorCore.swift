import Foundation

// STUB — owned by the core-host module. Public API is the contract; keep signatures.
enum EmulatorError: Error, LocalizedError {
    case romUnreadable(URL), coreRejectedROM, noGameLoaded, stateFailed(String)
    var errorDescription: String? { "\(self)" }
}

/// Hosts the snes9x libretro core on a dedicated emulation thread.
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
    var fastForward = false

    func load(rom: URL) throws { loadedROM = rom }
    /// Starts or resumes the emulation thread.
    func resume() { isRunning = true }
    /// Pauses after the current frame and flushes SRAM to disk.
    func pause() { isRunning = false }
    /// Pauses, writes SRAM + auto-save state (slot 0), and unloads the game.
    func unload() { isRunning = false; loadedROM = nil }
    func reset() {}
    func saveState(slot: Int) throws {}
    func loadState(slot: Int) throws {}
    func hasState(slot: Int) -> Bool { false }
    func flushSRAM() {}
}
