import XCTest
@testable import Duomulator

/// Exercises the libretro host against a real (MIT-licensed) homebrew ROM; see
/// Tests/Fixtures/README. Each test copies fixtures to uniquely named ROM files so their
/// .srm/.sN files never collide with real saves, and removes everything it created.
final class CoreTests: XCTestCase {
    private var core: EmulatorCore!
    private var createdROMs: [URL] = []

    override func setUp() {
        super.setUp()
        core = EmulatorCore()
    }

    override func tearDown() {
        core.unload()
        for rom in createdROMs {
            try? FileManager.default.removeItem(at: rom)
            try? FileManager.default.removeItem(at: GamePaths.sram(for: rom))
            for slot in 0...9 { try? FileManager.default.removeItem(at: GamePaths.state(for: rom, slot: slot)) }
        }
        createdROMs = []
        core = nil
        super.tearDown()
    }

    // MARK: Helpers

    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle(for: CoreTests.self).url(forResource: name, withExtension: ext),
                      "\(name).\(ext) missing from the test bundle")
    }

    /// Copies a fixture (optionally transformed) to a unique temporary ROM file.
    private func makeROM(_ name: String = "cputest-basic", _ ext: String = "sfc",
                         transform: ((inout Data) -> Void)? = nil) throws -> URL {
        var data = try Data(contentsOf: fixture(name, ext))
        transform?(&data)
        let url = FileManager.default.temporaryDirectory
            .appending(path: "duotest-\(UUID().uuidString).\(ext)")
        try data.write(to: url)
        createdROMs.append(url)
        return url
    }

    private func latestPixels() -> (EmulatorCore.TestFrame) {
        core.frameBuffer.withLatestFrame { frame, base in
            let count = frame.width * frame.height
            let pixels = Array(UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt16.self), count: count))
            return EmulatorCore.TestFrame(width: frame.width, height: frame.height,
                                          sequence: frame.sequence, pixels: pixels)
        }
    }

    // MARK: Tests

    func testFixtureIsBundled() throws {
        let url = try fixture("cputest-basic", "sfc")
        XCTAssertEqual(try Data(contentsOf: url).count, 256 * 1024)
    }

    func testSmallROMLoadsWithoutReadingPastTheEnd() throws {
        // 32 KB homebrew: snes9x used to read a BS-X header at 0xFFC0, past the end.
        let rom = try makeROM { $0 = $0.prefix(0x8000) }
        try core.load(rom: rom)
        core.runFrames(10)
        XCTAssertEqual(core.loadedROM, rom)
    }

    func testLoadRunsVideoAndAudio() throws {
        let rom = try makeROM()
        try core.load(rom: rom)
        XCTAssertEqual(core.loadedROM, rom)
        XCTAssertEqual(core.frameRate, 21477272.0 / 357366.0, accuracy: 0.001)
        XCTAssertEqual(core.sampleRate, 32040)

        let before = core.frameBuffer.latestSequence
        core.runFrames(120)
        let frame = latestPixels()
        XCTAssertGreaterThanOrEqual(frame.sequence - before, 100, "core should have presented frames")
        XCTAssertEqual(frame.width, 256)
        XCTAssertEqual(frame.height, 224)
        XCTAssertGreaterThan(Set(frame.pixels).count, 1, "frame is a single flat color")

        // ~534 stereo frames of audio per video frame at 32040 Hz / 60.1 fps.
        XCTAssertGreaterThan(core.audioFramesProduced, 0)
        XCTAssertGreaterThan(core.audio.availableFrames, 0)
    }

    func testSaveStateRoundTrip() throws {
        let rom = try makeROM()
        try core.load(rom: rom)
        XCTAssertFalse(core.hasState(slot: 3))
        XCTAssertThrowsError(try core.loadState(slot: 3))

        core.runFrames(60)
        try core.saveState(slot: 3)
        XCTAssertTrue(core.hasState(slot: 3))
        XCTAssertTrue(FileManager.default.fileExists(atPath: GamePaths.state(for: rom, slot: 3).path))

        core.runFrames(45)
        let first = latestPixels().pixels
        core.runFrames(200)
        try core.loadState(slot: 3)
        core.runFrames(45)
        XCTAssertEqual(latestPixels().pixels, first, "restored state should replay identically")
    }

    func testSaveStateWithoutGameThrows() {
        XCTAssertThrowsError(try core.saveState(slot: 1)) { error in
            guard case EmulatorError.noGameLoaded = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(core.hasState(slot: 1))
    }

    func testSRAMPaths() {
        let rom = URL(fileURLWithPath: "/tmp/Some Game (USA).sfc")
        XCTAssertEqual(GamePaths.sram(for: rom), GamePaths.saves.appending(path: "Some Game (USA).srm"))
        XCTAssertEqual(GamePaths.state(for: rom, slot: 2),
                       GamePaths.states.appending(path: "Some Game (USA).s2"))
        let zipped = URL(fileURLWithPath: "/tmp/Some Game (USA).zip")
        XCTAssertEqual(GamePaths.sram(for: zipped), GamePaths.sram(for: rom))
    }

    func testNoSRAMCartridgeWritesNoSaveFile() throws {
        let rom = try makeROM()
        try core.load(rom: rom)
        XCTAssertNil(core.sramContents())
        core.runFrames(10)
        core.flushSRAM()
        XCTAssertFalse(FileManager.default.fileExists(atPath: GamePaths.sram(for: rom).path))
    }

    func testSRAMPersistsAcrossReload() throws {
        // Patch the LoROM header: cartridge type ROM+RAM+battery, 8 KB of SRAM.
        let rom = try makeROM { data in
            data[0x7FD6] = 0x02
            data[0x7FD8] = 0x03
        }
        try core.load(rom: rom)
        let sram = try XCTUnwrap(core.sramContents())
        XCTAssertEqual(sram.count, 8 * 1024)

        // Unchanged SRAM is not written.
        core.flushSRAM()
        XCTAssertFalse(FileManager.default.fileExists(atPath: GamePaths.sram(for: rom).path))

        let marker = Data((0..<64).map { UInt8($0 * 3 & 0xFF) })
        core.pokeSRAM(marker)
        core.pause()   // pause flushes
        let onDisk = try Data(contentsOf: GamePaths.sram(for: rom))
        XCTAssertEqual(onDisk.count, 8 * 1024)
        XCTAssertEqual(onDisk.prefix(64), marker)

        core.unload()
        try core.load(rom: rom)
        XCTAssertEqual(try XCTUnwrap(core.sramContents()).prefix(64), marker)
    }

    func testUnloadWritesAutoSaveAndReloadWorks() throws {
        let first = try makeROM()
        try core.load(rom: first)
        core.runFrames(30)
        core.unload()
        XCTAssertNil(core.loadedROM)
        XCTAssertFalse(core.isRunning)
        XCTAssertTrue(FileManager.default.fileExists(atPath: GamePaths.state(for: first, slot: 0).path),
                      "unload should write the slot 0 suspend state")

        // A different game (from a zip) loads into the same process-wide core.
        let second = try makeROM("cputest-deflate", "zip")
        try core.load(rom: second)
        XCTAssertEqual(core.loadedROM, second)
        let before = core.frameBuffer.latestSequence
        core.runFrames(60)
        XCTAssertGreaterThan(core.frameBuffer.latestSequence, before)
        XCTAssertGreaterThan(Set(latestPixels().pixels).count, 1)

        // Suspend state from the first game resumes it.
        core.unload()
        try core.load(rom: first)
        XCTAssertTrue(core.hasState(slot: 0))
        XCTAssertNoThrow(try core.loadState(slot: 0))
    }

    func testUnloadWithoutRunningKeepsExistingAutoSave() throws {
        let rom = try makeROM()
        try core.load(rom: rom)
        core.runFrames(30)
        core.unload()
        let url = GamePaths.state(for: rom, slot: 0)
        let saved = try Data(contentsOf: url)

        try core.load(rom: rom)
        core.unload()   // nothing ran: the suspend state must be left alone
        XCTAssertEqual(try Data(contentsOf: url), saved)
    }

    func testLoadingInAnotherInstanceTakesOverTheCore() throws {
        let rom = try makeROM()
        try core.load(rom: rom)
        let other = EmulatorCore()
        try other.load(rom: rom)
        XCTAssertNil(core.loadedROM, "the previous owner is unloaded")
        let before = other.frameBuffer.latestSequence
        other.runFrames(10)
        XCTAssertGreaterThan(other.frameBuffer.latestSequence, before)
        other.unload()
    }

    func testThreadedRunPauseAndFastForward() throws {
        try core.load(rom: try makeROM())
        core.resume()
        XCTAssertTrue(core.isRunning)
        Thread.sleep(forTimeInterval: 1.0)
        core.pause()
        XCTAssertFalse(core.isRunning)
        let normal = core.frameBuffer.latestSequence
        XCTAssertGreaterThan(normal, 40, "≈60 frames expected in one second")
        XCTAssertLessThan(normal, 80, "emulation must be paced to real time")

        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(core.frameBuffer.latestSequence, normal, "no frames after pause() returns")

        core.fastForward = true
        core.resume()
        Thread.sleep(forTimeInterval: 1.0)
        core.pause()
        core.fastForward = false
        let turbo = core.frameBuffer.latestSequence - normal
        XCTAssertGreaterThan(turbo, 120, "fast-forward should run well above normal speed")

        // State operations while running are safe (they wait for the in-flight frame).
        core.resume()
        try core.saveState(slot: 5)
        try core.loadState(slot: 5)
        core.reset()
        core.unload()
        XCTAssertNil(core.loadedROM)
    }

    func testInputReachesHubMask() {
        // Bit positions are libretro's joypad ids; the host answers JOYPAD_MASK queries with them.
        InputHub.shared.set([.a, .start], source: .keyboard, player: 1)
        defer { InputHub.shared.clearAll() }
        XCTAssertEqual(InputHub.shared.buttons(player: 1).rawValue,
                       1 << UInt32(RETRO_DEVICE_ID_JOYPAD_A) | 1 << UInt32(RETRO_DEVICE_ID_JOYPAD_START))
    }

    func testMissingFileIsUnreadable() {
        let url = FileManager.default.temporaryDirectory.appending(path: "does-not-exist.sfc")
        XCTAssertThrowsError(try core.load(rom: url)) { error in
            guard case EmulatorError.romUnreadable = error else { return XCTFail("\(error)") }
        }
        XCTAssertNil(core.loadedROM)
    }

    // MARK: ZIP

    func testZipExtractionMatchesRawROM() throws {
        let raw = try Data(contentsOf: fixture("cputest-basic", "sfc"))
        for name in ["cputest-deflate", "cputest-stored"] {
            let zip = [UInt8](try Data(contentsOf: fixture(name, "zip")))
            let (entry, data) = try ZipArchive.extractFirstROM(from: zip)
            XCTAssertEqual(entry, "cputest-basic.sfc")
            XCTAssertEqual(data, raw, name)
        }
    }

    func testDamagedZipIsRejected() throws {
        var zip = [UInt8](try Data(contentsOf: fixture("cputest-deflate", "zip")))
        zip[200] ^= 0xFF   // inside the deflate stream
        XCTAssertThrowsError(try ZipArchive.extractFirstROM(from: zip)) { error in
            guard case EmulatorError.unsupportedArchive = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try ZipArchive.extractFirstROM(from: [0x50, 0x4B, 0x03, 0x04, 0, 0]))
    }

    func testCRC32() {
        XCTAssertEqual(ZipArchive.crc32(Array("123456789".utf8)), 0xCBF4_3926)
    }
}

extension EmulatorCore {
    /// A copied-out frame for assertions.
    struct TestFrame {
        var width: Int
        var height: Int
        var sequence: UInt64
        var pixels: [UInt16]
    }
}
