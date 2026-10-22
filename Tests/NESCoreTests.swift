import XCTest
@testable import Duomulator

/// NES support: the FCEUmm core behind the same EmulatorCore API, and switching between
/// cores in one process. Uses the GPL-2.0 "240p Test Suite" ROM; see Tests/Fixtures/README.
final class NESCoreTests: XCTestCase {
    private var core: EmulatorCore!
    private var createdROMs: [URL] = []

    override func setUp() {
        super.setUp()
        core = EmulatorCore()
    }

    override func tearDown() {
        core.unload()
        for rom in createdROMs {
            // Save paths depend on the ROM's system, which zips detect from the file itself,
            // so clear saves before deleting the ROM.
            try? FileManager.default.removeItem(at: GamePaths.sram(for: rom))
            for slot in 0...9 { try? FileManager.default.removeItem(at: GamePaths.state(for: rom, slot: slot)) }
            try? FileManager.default.removeItem(at: rom)
        }
        createdROMs = []
        core = nil
        super.tearDown()
    }

    // MARK: Helpers

    /// Copies a bundled fixture to a unique temporary ROM file.
    private func makeROM(_ name: String, _ ext: String) throws -> URL {
        let source = try XCTUnwrap(Bundle(for: NESCoreTests.self).url(forResource: name, withExtension: ext),
                                   "\(name).\(ext) missing from the test bundle")
        let url = FileManager.default.temporaryDirectory
            .appending(path: "duotest-\(UUID().uuidString).\(ext)")
        try FileManager.default.copyItem(at: source, to: url)
        createdROMs.append(url)
        return url
    }

    private func latestFrame() -> EmulatorCore.TestFrame {
        core.frameBuffer.withLatestFrame { frame, base in
            let pixels = Array(UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt16.self),
                                                   count: frame.width * frame.height))
            return EmulatorCore.TestFrame(width: frame.width, height: frame.height,
                                          sequence: frame.sequence, pixels: pixels)
        }
    }

    /// Runs frames and asserts the core presented a real picture of the expected width.
    private func assertRendersPicture(width: Int, file: StaticString = #filePath, line: UInt = #line) {
        let before = core.frameBuffer.latestSequence
        core.runFrames(180)
        let frame = latestFrame()
        XCTAssertGreaterThanOrEqual(frame.sequence - before, 100, "core should have presented frames",
                                    file: file, line: line)
        XCTAssertEqual(frame.width, width, file: file, line: line)
        XCTAssertGreaterThan(Set(frame.pixels).count, 1, "frame is a single flat color", file: file, line: line)
    }

    // MARK: Tests

    func testSystemDetection() throws {
        XCTAssertEqual(GameSystem(romExtension: "NES"), .nes)
        XCTAssertEqual(GameSystem(romExtension: "smc"), .snes)
        XCTAssertNil(GameSystem(romExtension: "gba"))
        XCTAssertEqual(GameSystem.of(rom: try makeROM("240pee", "zip")), .nes)
        XCTAssertEqual(GameSystem.of(rom: try makeROM("cputest-stored", "zip")), .snes)
        XCTAssertTrue(GamePaths.romExtensions.isSuperset(of: ["nes", "sfc", "smc", "zip"]))
    }

    func testNESSavesLiveInTheirOwnFolder() {
        let nes = URL(filePath: "/tmp/Tetris.nes")
        let snes = URL(filePath: "/tmp/Tetris.sfc")
        XCTAssertEqual(GamePaths.sram(for: nes), GamePaths.saves.appending(path: "NES/Tetris.srm"))
        XCTAssertEqual(GamePaths.state(for: nes, slot: 2), GamePaths.states.appending(path: "NES/Tetris.s2"))
        // SNES saves stay where they always were.
        XCTAssertEqual(GamePaths.sram(for: snes), GamePaths.saves.appending(path: "Tetris.srm"))
    }

    func testNESLoadRunsVideoAndAudio() throws {
        try core.load(rom: try makeROM("240pee", "nes"))
        XCTAssertEqual(core.system, .nes)
        XCTAssertEqual(core.frameRate, 60.1, accuracy: 0.2)
        XCTAssertGreaterThan(core.sampleRate, 8000)
        assertRendersPicture(width: 256)
        XCTAssertTrue((224...240).contains(latestFrame().height), "NES frames are 224–240 lines")
        XCTAssertGreaterThan(core.audioFramesProduced, 0)
    }

    func testNESZipLoads() throws {
        try core.load(rom: try makeROM("240pee", "zip"))
        XCTAssertEqual(core.system, .nes)
        assertRendersPicture(width: 256)
    }

    func testNESSaveStateRoundTrip() throws {
        let rom = try makeROM("240pee", "nes")
        try core.load(rom: rom)
        core.runFrames(60)
        try core.saveState(slot: 1)
        XCTAssertTrue(core.hasState(slot: 1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: GamePaths.state(for: rom, slot: 1).path))
        core.runFrames(60)
        try core.loadState(slot: 1)
        core.runFrames(10)
    }

    func testSwitchingBetweenSNESAndNES() throws {
        let snes = try makeROM("cputest-basic", "sfc")
        let nes = try makeROM("240pee", "nes")

        try core.load(rom: snes)
        XCTAssertEqual(core.system, .snes)
        assertRendersPicture(width: 256)
        XCTAssertEqual(latestFrame().height, 224)

        try core.load(rom: nes)
        XCTAssertEqual(core.system, .nes)
        assertRendersPicture(width: 256)

        // Back to SNES: its core was initialized earlier and must still work.
        try core.load(rom: snes)
        XCTAssertEqual(core.system, .snes)
        XCTAssertEqual(core.sampleRate, 32040)
        assertRendersPicture(width: 256)
        XCTAssertEqual(latestFrame().height, 224)
    }
}
