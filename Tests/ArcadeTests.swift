import XCTest
@testable import Duomulator

/// Arcade sets (FinalBurn Neo): catalog lookups and telling arcade zips from zipped cartridges.
final class ArcadeTests: XCTestCase {
    private var created: [URL] = []

    override func tearDown() {
        for url in created { try? FileManager.default.removeItem(at: url) }
        created = []
        super.tearDown()
    }

    /// Writes a zip containing empty stored files with these names. Only the central
    /// directory matters to `GameSystem.of(rom:)`, but the archive is well formed.
    private func makeZip(named name: String, files: [String]) throws -> URL {
        var local = Data(), central = Data()
        func put16(_ data: inout Data, _ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { data.append(contentsOf: $0) } }
        func put32(_ data: inout Data, _ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { data.append(contentsOf: $0) } }
        for file in files {
            let nameBytes = Data(file.utf8)
            let offset = local.count
            // Local file header: signature, version, flags, method, time, date, crc, sizes, name.
            put32(&local, 0x0403_4B50)
            for _ in 0..<5 { put16(&local, 0) }
            for _ in 0..<3 { put32(&local, 0) }
            put16(&local, nameBytes.count); put16(&local, 0)
            local.append(nameBytes)
            // Central directory entry.
            put32(&central, 0x0201_4B50)
            put16(&central, 20); put16(&central, 10)
            for _ in 0..<4 { put16(&central, 0) }
            for _ in 0..<3 { put32(&central, 0) }
            put16(&central, nameBytes.count)
            for _ in 0..<4 { put16(&central, 0) }
            put32(&central, 0); put32(&central, offset)
            central.append(nameBytes)
        }
        var eocd = Data()
        put32(&eocd, 0x0605_4B50); put16(&eocd, 0); put16(&eocd, 0)
        put16(&eocd, files.count); put16(&eocd, files.count)
        put32(&eocd, central.count); put32(&eocd, local.count); put16(&eocd, 0)
        let dir = FileManager.default.temporaryDirectory.appending(path: "duotest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        created.append(dir)
        let url = dir.appending(path: name)
        var zip = local
        zip.append(central)
        zip.append(eocd)
        try zip.write(to: url)
        return url
    }

    func testCatalogKnowsTheBigNames() throws {
        XCTAssertGreaterThan(ArcadeCatalog.entries.count, 5_000)
        let mslug = try XCTUnwrap(ArcadeCatalog.entry(forSet: URL(filePath: "/tmp/mslug.zip")))
        XCTAssertEqual(mslug.title, "Metal Slug - Super Vehicle-001")
        XCTAssertEqual(mslug.system, .neoGeo)
        XCTAssertEqual(ArcadeCatalog.system(forSet: URL(filePath: "/tmp/SF2CE.ZIP")), .cps, "case-insensitive")
        XCTAssertEqual(ArcadeCatalog.system(forSet: URL(filePath: "/tmp/sfiii3.7z")), .cps)
        XCTAssertTrue(try XCTUnwrap(ArcadeCatalog.entry(forSet: URL(filePath: "/tmp/neogeo.zip"))).isBIOS)
        XCTAssertNil(ArcadeCatalog.entry(forSet: URL(filePath: "/tmp/Super Mario World (U).zip")))
    }

    func testArcadeZipsVersusZippedCartridges() throws {
        // Neo Geo set: every file is .bin, and the name is a known set.
        let mslug = try makeZip(named: "mslug.zip", files: ["201-p1.bin", "201-s1.bin", "201-c1.bin"])
        XCTAssertEqual(GameSystem.of(rom: mslug), .neoGeo)
        // Genesis dump zipped under its title: .bin inside, not a set name.
        let sonic = try makeZip(named: "Sonic The Hedgehog (U).zip", files: ["Sonic The Hedgehog (U).bin"])
        XCTAssertEqual(GameSystem.of(rom: sonic), .genesis)
        // A distinctive cartridge extension wins even over a set-like name.
        let snes = try makeZip(named: "dino.zip", files: ["Dino.sfc"])
        XCTAssertEqual(GameSystem.of(rom: snes), .snes)
        // Unknown name, unknown contents.
        let junk = try makeZip(named: "notes.zip", files: ["readme.txt"])
        XCTAssertNil(GameSystem.of(rom: junk))
    }

    func testArcadeSystemsShareTheCoreAndLoadFromPath() {
        for system in [GameSystem.neoGeo, .cps, .arcade] {
            XCTAssertEqual(system.coreName, "fbneo")
            XCTAssertTrue(system.loadsFromPath)
            XCTAssertEqual(system.manufacturer, "Arcade")
            XCTAssertEqual(BoxArtDownloader.folder(for: system), "FBNeo - Arcade Games")
        }
        XCTAssertEqual(BoxArtDownloader.matchName(for: URL(filePath: "/tmp/mslug.zip"), system: .neoGeo),
                       "Metal Slug - Super Vehicle-001")
    }

    func testFBNeoRejectsABogusSetWithoutCrashing() throws {
        // Named like a real set but empty: the core must refuse it and the app must survive.
        let fake = try makeZip(named: "sf2ce.zip", files: ["nothing.bin"])
        let core = EmulatorCore()
        defer { core.unload() }
        do {
            try core.load(rom: fake)
            core.runFrames(10)   // FBNeo may accept the load and show its own error screen
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("FinalBurn Neo"), "\(error)")
        }
    }
}
