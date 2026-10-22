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
}
