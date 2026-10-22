import XCTest
@testable import Duomulator

/// PlayStation: telling its discs from Sega CD ones, multi-disc grouping, and the pad.
final class PSXTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "duotest-psx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    func testCueSheetsAreToldApartByTrackMode() throws {
        let psx = dir.appending(path: "Spyro.cue")
        try "FILE \"Spyro.bin\" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n"
            .write(to: psx, atomically: true, encoding: .utf8)
        let sega = dir.appending(path: "Sonic CD.cue")
        try "FILE \"Sonic CD.bin\" BINARY\n  TRACK 01 MODE1/2352\n    INDEX 01 00:00:00\n"
            .write(to: sega, atomically: true, encoding: .utf8)
        XCTAssertEqual(GameSystem.of(rom: psx), .psx)
        XCTAssertEqual(GameSystem.of(rom: sega), .segaCD)
    }

    /// A CHD v5 header (124 bytes) followed by one CD metadata entry.
    private func makeCHD(named name: String, trackType: String) throws -> URL {
        var data = Data("MComprHD".utf8)
        func be32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
        func be64(_ v: UInt64) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
        be32(124)                       // header length
        be32(5)                         // version
        for _ in 0..<4 { be32(0) }      // compressors
        be64(0)                         // logical bytes
        be64(0)                         // map offset
        be64(124)                       // metadata offset -> right after the header
        data.append(Data(count: 124 - data.count))
        let text = Data("TRACK:1 TYPE:\(trackType) SUBTYPE:NONE FRAMES:1000\0".utf8)
        data.append(Data("CHT2".utf8))
        be32(UInt32(text.count))        // flags (0) + 24-bit length
        be64(0)                         // no next entry
        data.append(text)
        let url = dir.appending(path: name)
        try data.write(to: url)
        return url
    }

    func testCHDsAreToldApartByTrackType() throws {
        XCTAssertEqual(GameSystem.of(rom: try makeCHD(named: "FF7.chd", trackType: "MODE2_RAW")), .psx)
        XCTAssertEqual(GameSystem.of(rom: try makeCHD(named: "Snatcher.chd", trackType: "MODE1_RAW")), .segaCD)
    }

    func testMultiDiscGroupingCoversRealNamingStyles() {
        let names = [
            "Final Fantasy VII Disc 1.chd", "Final Fantasy VII Disc 2.chd", "Final Fantasy VII Disc 3.chd",
            "Final Fantasy VIII CD1.chd", "Final Fantasy VIII CD2.chd",
            "Parasite Eve (Disc 1).chd", "Parasite Eve (Disc 2).chd",
            " In Cold Blood (1of2) [SLUS_013.13].chd", " In Cold Blood (2of2) [SLUS_013.14].chd",
            "Spyro the Dragon (US NTSC).chd",        // single disc: left alone
            "Crash Bandicoot 3.chd",
        ]
        let groups = DiscPlaylist.groups(in: names)
        XCTAssertEqual(groups["Final Fantasy VII"], ["Final Fantasy VII Disc 1.chd", "Final Fantasy VII Disc 2.chd",
                                                     "Final Fantasy VII Disc 3.chd"])
        XCTAssertEqual(groups["Final Fantasy VIII"]?.count, 2)
        XCTAssertEqual(groups["Parasite Eve"]?.count, 2)
        XCTAssertEqual(groups.values.first { $0.first?.contains("In Cold Blood") == true }?.count, 2)
        XCTAssertFalse(groups.values.flatMap { $0 }.contains("Spyro the Dragon (US NTSC).chd"))
        XCTAssertEqual(groups.count, 4)
    }

    func testPlaylistEntriesAndSystem() throws {
        let m3u = dir.appending(path: "Final Fantasy VII.m3u")
        try "# Discs\nFinal Fantasy VII Disc 1.chd\n\nFinal Fantasy VII Disc 2.chd\n../elsewhere.chd\n"
            .write(to: m3u, atomically: true, encoding: .utf8)
        XCTAssertEqual(DiscPlaylist.entries(of: m3u), ["Final Fantasy VII Disc 1.chd", "Final Fantasy VII Disc 2.chd"])
        _ = try makeCHD(named: "Final Fantasy VII Disc 1.chd", trackType: "MODE2_RAW")
        XCTAssertEqual(GameSystem.of(rom: m3u), .psx)
        XCTAssertEqual(GameSystem.psx.manufacturer, "Sony")
        XCTAssertTrue(GameSystem.psx.loadsFromPath)
    }

    func testPlayStationPad() {
        let layout = ControllerLayout(bounds: CGRect(x: 0, y: 0, width: 400, height: 380), style: .panel, system: .psx)
        XCTAssertEqual(layout.pad, .playstation)
        XCTAssertFalse(layout.lRect.isNull, "L1/R1")
        let labels = Dictionary(uniqueKeysWithValues: layout.faceButtons.map { ($0.button.rawValue, layout.label(for: $0.button)) })
        XCTAssertEqual(labels[SNESButtons.x.rawValue], "△")   // top
        XCTAssertEqual(labels[SNESButtons.a.rawValue], "○")   // right
        XCTAssertEqual(labels[SNESButtons.b.rawValue], "✕")   // bottom
        XCTAssertEqual(labels[SNESButtons.y.rawValue], "□")   // left
    }

    // MARK: Analog sticks

    func testVirtualSticksFitBetweenTheClusters() {
        let sizes = [CGSize(width: 669, height: 401), CGSize(width: 466, height: 330), CGSize(width: 382, height: 334)]
        for size in sizes {
            for style in [ControllerLayout.Style.panel, .overlay] {
                let l = ControllerLayout(bounds: CGRect(origin: .zero, size: size), style: style, system: .psx)
                XCTAssertGreaterThanOrEqual(l.stickRadius, 30, "\(size) \(style)")
                let sticks = [l.leftStickCenter, l.rightStickCenter]
                XCTAssertGreaterThanOrEqual(hypot(sticks[0].x - sticks[1].x, sticks[0].y - sticks[1].y) - 2 * l.stickRadius,
                                            24, "sticks need a thumb's gap between them at \(size)")
                for c in sticks {
                    let stick = CGRect(x: c.x - l.stickRadius, y: c.y - l.stickRadius,
                                       width: 2 * l.stickRadius, height: 2 * l.stickRadius)
                    XCTAssertGreaterThanOrEqual(hypot(c.x - l.dpadCenter.x, c.y - l.dpadCenter.y),
                                                l.stickRadius + l.dpadRadius + 12, "stick crowds the d-pad at \(size)")
                    for (_, center) in l.faceButtons {
                        XCTAssertGreaterThanOrEqual(hypot(c.x - center.x, c.y - center.y),
                                                    l.stickRadius + l.faceRadius, "stick overlaps a face button at \(size)")
                    }
                    XCTAssertFalse(stick.intersects(l.selectRect), "stick overlaps Select at \(size) \(style)")
                    XCTAssertFalse(stick.intersects(l.startRect), "stick overlaps Start at \(size) \(style)")
                    XCTAssertEqual(l.control(at: c), .stick(sticks.firstIndex(of: c)!))
                }
            }
        }
        XCTAssertEqual(ControllerLayout(bounds: CGRect(x: 0, y: 0, width: 669, height: 401), style: .panel,
                                        system: .snes).stickRadius, 0, "only PlayStation has sticks")
    }

    func testStickValues() {
        let l = ControllerLayout(bounds: CGRect(x: 0, y: 0, width: 669, height: 401), style: .panel, system: .psx)
        let c = l.rightStickCenter, r = l.stickRadius
        XCTAssertEqual(l.stickValue(1, at: c).x, 0)
        XCTAssertEqual(l.stickValue(1, at: CGPoint(x: c.x + r, y: c.y)).x, 32767)
        XCTAssertEqual(l.stickValue(1, at: CGPoint(x: c.x + 3 * r, y: c.y)).x, 32767, "clamped")
        XCTAssertEqual(l.stickValue(1, at: CGPoint(x: c.x, y: c.y + r)).y, 32767, "down is positive")
        XCTAssertEqual(l.stickValue(1, at: CGPoint(x: c.x + r * 0.05, y: c.y)).x, 0, "dead zone")
    }

    func testHubMergesTouchAndGamepadSticks() {
        let hub = InputHub()
        hub.setStick(0, x: 1000, y: 0, source: .touch)
        hub.setStick(0, x: -20000, y: 0, source: .gamepad)
        XCTAssertEqual(hub.stick(0).x, -20000, "the stick pushed further wins")
        hub.setStick(0, x: 0, y: 0, source: .gamepad)
        XCTAssertEqual(hub.stick(0).x, 1000)
        hub.clearAll()
        XCTAssertEqual(hub.stick(0).x, 0)
    }

    func testGamepadSticksDriveAnalogOnPlayStation() {
        var s = GamepadSnapshot()
        s.stickX = 1; s.stickY = 1          // up-right on the pad
        s.rightStickY = -0.5
        XCTAssertEqual(s.analog(0).x, 32767)
        XCTAssertEqual(s.analog(0).y, -32767, "libretro y is down-positive")
        XCTAssertEqual(s.analog(1).y, 16384)
        let psx = ControllerMapping.defaults(for: .psx)
        XCTAssertTrue(psx.usesAnalogSticks)
        XCTAssertEqual(psx.buttons(for: s), [], "the left stick isn't the d-pad on PlayStation")
        XCTAssertEqual(ControllerMapping.defaults(for: .snes).buttons(for: s), [.up, .right])
    }
}
