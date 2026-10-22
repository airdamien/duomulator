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
                                      style: .panel, system: .genesis, pad: .genesis3)
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

    func testSixButtonPadLabelsAndBits() {
        let layout = ControllerLayout(bounds: CGRect(x: 0, y: 0, width: 400, height: 380),
                                      style: .panel, system: .genesis)
        XCTAssertEqual(layout.pad, .genesis6, "Sega defaults to the 6-button pad")
        XCTAssertEqual(layout.faceButtons.map { layout.label(for: $0.button) }, ["X", "Y", "Z", "A", "B", "C"])
        // PicoDrive: X/Y/Z <- libretro L/X/R, A/B/C <- Y/B/A.
        XCTAssertEqual(layout.faceButtons.map(\.button), [.l, .x, .r, .y, .b, .a])
        let top = layout.faceButtons[0].center.y, bottom = layout.faceButtons[3].center.y
        XCTAssertLessThan(top, bottom, "X Y Z row above A B C")
    }

    func testGenesisButtonsDontTouchAndAreAllReachable() {
        let cases: [(CGRect, ControllerLayout.Style, CGRect?)] = [
            (CGRect(x: 0, y: 0, width: 669, height: 401), .panel, nil),       // Duo, below the fold
            (CGRect(x: 0, y: 0, width: 466, height: 330), .overlay, nil),     // outer display
            (CGRect(x: 0, y: 0, width: 375, height: 300), .overlay, nil),     // small iPhone
        ]
        for pad in [GameSystem.PadStyle.genesis3, .genesis6] {
            for (bounds, style, reserved) in cases {
                let layout = ControllerLayout(bounds: bounds, style: style, system: .genesis,
                                              pad: pad, reserved: reserved)
                let buttons = layout.faceButtons
                for i in buttons.indices {
                    for j in buttons.indices where j > i {
                        let gap = hypot(buttons[i].center.x - buttons[j].center.x,
                                        buttons[i].center.y - buttons[j].center.y) - 2 * layout.faceRadius
                        XCTAssertGreaterThanOrEqual(gap, 6, "\(pad) \(style) \(bounds.size): buttons \(i),\(j) gap \(gap)")
                    }
                    // A press just inside each button's outer edge still lands on it.
                    let c = buttons[i].center
                    let out = CGPoint(x: c.x - layout.faceCenter.x, y: c.y - layout.faceCenter.y)
                    let len = max(hypot(out.x, out.y), 0.001)
                    let edge = CGPoint(x: c.x + out.x / len * layout.faceRadius * 0.9,
                                       y: c.y + out.y / len * layout.faceRadius * 0.9)
                    let control = layout.control(at: edge)
                    XCTAssertEqual(control, .buttons, "\(pad) button \(i) edge not grabbable")
                    if let control {
                        XCTAssertTrue(layout.buttons(at: edge, for: control).contains(buttons[i].button))
                    }
                }
            }
        }
    }

    func testGenesisPadLookupTableAndOverride() throws {
        func rom(_ name: String) -> URL { URL(filePath: "/tmp/\(name)") }
        XCTAssertEqual(GenesisPad.normalizedTitle(of: rom("Addams Family, The (UE) [!].bin")), "addamsfamily")
        XCTAssertEqual(GenesisPad.normalizedTitle(of: rom("Ms. Pac-Man (U) [!].bin")), "mspacman")
        XCTAssertEqual(GenesisPad.automatic(for: rom("Golden Axe II (W) [!].bin")), .three)
        XCTAssertEqual(GenesisPad.automatic(for: rom("Sunset Riders (U) [!].bin")), .three)
        XCTAssertEqual(GenesisPad.automatic(for: rom("Street Fighter II' - Special Champion Edition (U) [!].bin")), .six)
        XCTAssertEqual(GenesisPad.automatic(for: rom("Some Unknown Homebrew.md")), .six, "unknown games get 6")

        let defaults = try XCTUnwrap(UserDefaults(suiteName: "duotest-\(UUID().uuidString)"))
        let game = rom("Sunset Riders (U) [!].bin")
        XCTAssertEqual(GenesisPad.effective(for: game, defaults: defaults), .three)
        GenesisPad.setOverride(.six, for: game, defaults: defaults)
        XCTAssertEqual(GenesisPad.effective(for: game, defaults: defaults), .six)
        GenesisPad.setOverride(nil, for: game, defaults: defaults)
        XCTAssertEqual(GenesisPad.effective(for: game, defaults: defaults), .three, "back to automatic")
    }

    func test32XCartridgeNamedBinIsDetectedFromItsHeader() throws {
        let genesis = try makeROM("genesistest", "md")
        let asBin = genesis.deletingPathExtension().appendingPathExtension("bin")
        try FileManager.default.copyItem(at: genesis, to: asBin)
        created.append(asBin)
        XCTAssertEqual(GameSystem.of(rom: asBin), .genesis)

        var data = try Data(contentsOf: genesis)
        data.replaceSubrange(0x100..<0x110, with: Array("SEGA 32X        ".utf8))
        let mars = FileManager.default.temporaryDirectory.appending(path: "duotest-\(UUID().uuidString).bin")
        try data.write(to: mars)
        created.append(mars)
        XCTAssertEqual(GameSystem.of(rom: mars), .sega32x)
    }

    func testPadTypeOptionReachesTheCore() throws {
        core.setCoreOption("picodrive_input1", GenesisPad.six.coreOptionValue)
        try core.load(rom: try makeROM("genesistest", "md"))
        core.runFrames(5)
        core.setCoreOption("picodrive_input1", GenesisPad.three.coreOptionValue)
        core.runFrames(5)   // PicoDrive re-reads options via GET_VARIABLE_UPDATE; must not crash
        XCTAssertEqual(core.system, .genesis)
    }
}
