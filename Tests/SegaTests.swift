import XCTest
@testable import Duomulator

/// Genesis / 32X / Sega CD through PicoDrive. Uses genesistest.md, a public domain ROM made
/// by Tests/Fixtures/make-genesis-test-rom.py that paints the whole screen red.
final class SegaTests: XCTestCase {
    private var core: EmulatorCore!
    private var created: [URL] = []

    override func setUp() {
        super.setUp()
        core = EmulatorCore()
    }

    override func tearDown() {
        core.unload()
        for url in created {
            try? FileManager.default.removeItem(at: GamePaths.sram(for: url))
            for slot in 0...9 { try? FileManager.default.removeItem(at: GamePaths.state(for: url, slot: slot)) }
            try? FileManager.default.removeItem(at: url)
        }
        created = []
        core = nil
        super.tearDown()
    }

    private func makeROM(_ name: String, _ ext: String) throws -> URL {
        let source = try XCTUnwrap(Bundle(for: SegaTests.self).url(forResource: name, withExtension: ext),
                                   "\(name).\(ext) missing from the test bundle")
        let url = FileManager.default.temporaryDirectory.appending(path: "duotest-\(UUID().uuidString).\(ext)")
        try FileManager.default.copyItem(at: source, to: url)
        created.append(url)
        return url
    }

    private func latestPixels() -> (width: Int, height: Int, pixels: [UInt16]) {
        core.frameBuffer.withLatestFrame { frame, base in
            (frame.width, frame.height,
             Array(UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt16.self),
                                       count: frame.width * frame.height)))
        }
    }

    func testSystemDetection() {
        XCTAssertEqual(GameSystem(romExtension: "md"), .genesis)
        XCTAssertEqual(GameSystem(romExtension: "BIN"), .genesis)
        XCTAssertEqual(GameSystem(romExtension: "32x"), .sega32x)
        XCTAssertEqual(GameSystem(romExtension: "cue"), .segaCD)
        XCTAssertEqual(GameSystem(romExtension: "chd"), .segaCD)
        XCTAssertEqual(Set([GameSystem.genesis, .sega32x, .segaCD].map(\.coreName)), ["picodrive"])
        XCTAssertTrue(GameSystem.segaCD.loadsFromPath)
        XCTAssertEqual(GamePaths.sram(for: URL(filePath: "/tmp/Sonic.md")),
                       GamePaths.saves.appending(path: "Genesis/Sonic.srm"))
    }

    func testGenesisBootsAndPaintsTheScreenRed() throws {
        try core.load(rom: try makeROM("genesistest", "md"))
        XCTAssertEqual(core.system, .genesis)
        XCTAssertEqual(core.frameRate, 59.9, accuracy: 0.3)
        core.runFrames(60)
        let frame = latestPixels()
        XCTAssertEqual(frame.width, 320, "H40 mode")
        XCTAssertEqual(frame.height, 224)
        // Most common colour: red, i.e. a full red channel and (almost) no green or blue.
        let counts = Dictionary(frame.pixels.map { ($0, 1) }, uniquingKeysWith: +)
        let dominant = try XCTUnwrap(counts.max { $0.value < $1.value }?.key)
        XCTAssertGreaterThanOrEqual(dominant >> 11, 24, String(dominant, radix: 16))
        XCTAssertLessThan((dominant >> 5) & 0x3F, 8, String(dominant, radix: 16))
        XCTAssertLessThan(dominant & 0x1F, 4, String(dominant, radix: 16))
        XCTAssertGreaterThan(core.audioFramesProduced, 0)
    }

    func testGenesisSaveStateRoundTrip() throws {
        try core.load(rom: try makeROM("genesistest", "md"))
        core.runFrames(30)
        try core.saveState(slot: 1)
        XCTAssertTrue(core.hasState(slot: 1))
        try core.loadState(slot: 1)
        core.runFrames(5)
    }

    func testSegaCDWithoutBIOSExplainsWhatToDo() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "duotest-cd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        created.append(dir)
        let cue = dir.appending(path: "Game.cue")
        try "FILE \"Game (Track 1).bin\" BINARY\n  TRACK 01 MODE1/2352\n    INDEX 01 00:00:00\n"
            .write(to: cue, atomically: true, encoding: .utf8)
        try Data(count: 2352 * 16).write(to: dir.appending(path: "Game (Track 1).bin"))
        let bios = GameSystem.segaCD.requiredBIOS.map { GamePaths.system.appending(path: $0) }
        try XCTSkipIf(bios.contains { FileManager.default.fileExists(atPath: $0.path) },
                      "a Sega CD BIOS is installed")

        XCTAssertThrowsError(try core.load(rom: cue)) { error in
            guard case EmulatorError.missingBIOS(.segaCD) = error else {
                return XCTFail("expected missingBIOS, got \(error)")
            }
            XCTAssertTrue(error.localizedDescription.contains("System folder"))
        }
        XCTAssertNil(core.loadedROM)
    }

    func testCueSheetTracks() throws {
        let cue = FileManager.default.temporaryDirectory.appending(path: "duotest-\(UUID().uuidString).cue")
        created.append(cue)
        try """
        REM a comment
        FILE "Sonic CD (Track 01).bin" BINARY
          TRACK 01 MODE1/2352
        file Track02.bin BINARY
          TRACK 02 AUDIO
        FILE "../elsewhere.bin" BINARY
        """.write(to: cue, atomically: true, encoding: .utf8)
        XCTAssertEqual(CueSheet.trackFiles(of: cue), ["Sonic CD (Track 01).bin", "Track02.bin"])
    }

    func testGenesisPadIsThreeButtons() {
        let layout = ControllerLayout(bounds: CGRect(x: 0, y: 0, width: 400, height: 380),
                                      style: .panel, system: .genesis)
        XCTAssertEqual(layout.faceButtons.map { layout.label(for: $0.button) }, ["A", "B", "C"])
        // PicoDrive reads Genesis A/B/C from libretro Y/B/A.
        XCTAssertEqual(layout.faceButtons.map(\.button), [.y, .b, .a])
        XCTAssertTrue(layout.lRect.isNull)
        XCTAssertTrue(layout.selectRect.isNull)
        XCTAssertFalse(layout.startRect.isNull)
        let a = layout.faceButtons[0].center, b = layout.faceButtons[1].center
        let between = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        XCTAssertEqual(layout.buttons(at: between, for: .buttons), [.y, .b], "A+B together")
    }

    func testSwitchingAcrossAllCores() throws {
        let roms = [(try makeROM("genesistest", "md"), GameSystem.genesis, 320),
                    (try makeROM("cputest-basic", "sfc"), .snes, 256),
                    (try makeROM("dstest", "nds"), .nds, 256),
                    (try makeROM("240pee", "nes"), .nes, 256)]
        for (rom, system, width) in roms + roms.prefix(1) {
            try core.load(rom: rom)
            XCTAssertEqual(core.system, system)
            core.runFrames(60)
            XCTAssertEqual(latestPixels().width, width, "\(system)")
        }
    }
}
