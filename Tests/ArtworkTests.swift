import XCTest
@testable import Duomulator

/// Library artwork: box-art name matching, snapshots, the store, and capture safety.
final class ArtworkTests: XCTestCase {
    private var created: [URL] = []

    override func tearDown() {
        for url in created {
            ArtworkStore.shared.remove(for: url)
            try? FileManager.default.removeItem(at: GamePaths.sram(for: url))
            for slot in 0...9 { try? FileManager.default.removeItem(at: GamePaths.state(for: url, slot: slot)) }
            try? FileManager.default.removeItem(at: url)
        }
        created = []
        super.tearDown()
    }

    private func makeROM(_ name: String, _ ext: String) throws -> URL {
        let source = try XCTUnwrap(Bundle(for: ArtworkTests.self).url(forResource: name, withExtension: ext))
        let url = FileManager.default.temporaryDirectory.appending(path: "duotest-\(UUID().uuidString).\(ext)")
        try FileManager.default.copyItem(at: source, to: url)
        created.append(url)
        return url
    }

    // MARK: Matching

    private let snesListing = [
        "Chrono Trigger (Japan)", "Chrono Trigger (Japan) (Sample)", "Chrono Trigger (USA)",
        "Legend of Zelda, The - A Link to the Past (USA)", "Legend of Zelda, The - A Link to the Past (Europe)",
        "Super Mario World (Europe)", "Super Mario World (USA)",
        "Super Mario World (USA, Europe) (Virtual Console, Classic Mini, Switch Online)",
        "Final Fantasy III (USA) (Rev 1)", "Final Fantasy III (USA)",
    ]

    func testGoodToolsNamesMatchNoIntroBoxArt() {
        XCTAssertEqual(BoxArtDownloader.bestMatch(for: "Chrono Trigger (U) [!]", in: snesListing), "Chrono Trigger (USA)")
        XCTAssertEqual(BoxArtDownloader.bestMatch(for: "Legend of Zelda, The - A Link to the Past (U)", in: snesListing),
                       "Legend of Zelda, The - A Link to the Past (USA)")
        XCTAssertEqual(BoxArtDownloader.bestMatch(for: "Super Mario World (U) [!]", in: snesListing), "Super Mario World (USA)")
        XCTAssertEqual(BoxArtDownloader.bestMatch(for: "Super Mario World (E)", in: snesListing), "Super Mario World (Europe)")
        XCTAssertEqual(BoxArtDownloader.bestMatch(for: "Final Fantasy III (U) (V1.1) [!]", in: snesListing),
                       "Final Fantasy III (USA)")
        XCTAssertNil(BoxArtDownloader.bestMatch(for: "Totally Unknown Game (U)", in: snesListing))
    }

    func testListingParser() {
        let html = """
        <a href="?C=N;O=D">Name</a> <a href="/Nintendo/">Parent</a>
        <a href="Chrono%20Trigger%20(USA).png">x</a>
        <a href="Mario%20&amp;%20Wario%20(Japan).png">y</a>
        <a href="Tom%20%26%20Jerry%20(USA).png">z</a>
        """
        let names = BoxArtDownloader.parseListing(html)
        XCTAssertTrue(names.contains("Chrono Trigger (USA)"))
        XCTAssertTrue(names.contains("Tom & Jerry (USA)"))
        XCTAssertFalse(names.contains { $0.hasPrefix("?") || $0.hasPrefix("/") })
    }

    func testFolderNamesForEverySystem() {
        for system in GameSystem.allCases {
            let folder = BoxArtDownloader.folder(for: system)
            if system.isArcade {
                XCTAssertEqual(folder, "FBNeo - Arcade Games")
            } else {
                XCTAssertTrue(folder.hasPrefix(system.manufacturer), folder)
            }
        }
    }

    // MARK: Snapshots and store

    func testSnapshotsUseTheDisplayShape() throws {
        let core = EmulatorCore()
        defer { core.unload() }
        try core.load(rom: try makeROM("cputest-basic", "sfc"))
        core.runFrames(120)
        let snes = try XCTUnwrap(FrameSnapshot.image(from: core.frameBuffer, system: .snes))
        XCTAssertEqual(snes.size.width / snes.size.height, 4.0 / 3.0, accuracy: 0.01)

        // A one-colour picture (the Genesis test ROM paints the screen red) is no thumbnail.
        try core.load(rom: try makeROM("genesistest", "md"))
        core.runFrames(30)
        XCTAssertNil(FrameSnapshot.image(from: core.frameBuffer, system: .genesis))

        try core.load(rom: try makeROM("dstest", "nds"))
        core.runFrames(30)
        let ds = try XCTUnwrap(FrameSnapshot.image(from: core.frameBuffer, system: .nds))
        XCTAssertEqual(ds.size.height, 192, "top screen only")
        XCTAssertEqual(ds.size.width / ds.size.height, 4.0 / 3.0, accuracy: 0.01)
    }

    func testStoreSaveMoveRemove() throws {
        let store = ArtworkStore(root: FileManager.default.temporaryDirectory.appending(path: "duotest-art-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: store.root) }
        let rom = URL(filePath: "/tmp/Game.sfc"), renamed = URL(filePath: "/tmp/Renamed.sfc")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 6)).image { _ in }
        store.save(image, .title, for: rom)
        XCTAssertTrue(store.has(.title, for: rom))
        XCTAssertEqual(store.thumbnail(for: rom, preferResume: false)?.kind, .title)
        store.move(from: rom, to: renamed)
        XCTAssertFalse(store.has(.title, for: rom))
        XCTAssertTrue(store.has(.title, for: renamed))
        store.remove(for: renamed)
        XCTAssertNil(store.thumbnail(for: renamed, preferResume: true))
    }

    // MARK: Capture

    func testThrowawayRunsNeverTouchSaves() throws {
        let rom = try makeROM("genesistest", "md")
        GamePaths.ensureDirectories()
        let resume = GamePaths.state(for: rom, slot: 0)
        try Data("player's resume state".utf8).write(to: resume)

        let core = EmulatorCore()
        core.persistsSaves = false
        try core.load(rom: rom)
        core.runFrames(120)
        core.unload()

        XCTAssertEqual(try Data(contentsOf: resume), Data("player's resume state".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: GamePaths.sram(for: rom).path))
    }

    func testTitleCaptureSavesAThumbnail() throws {
        let rom = try makeROM("240pee", "nes")
        TitleCapturer.shared.capture(rom, system: .nes)
        XCTAssertTrue(ArtworkStore.shared.has(.title, for: rom), "a frame with content was captured")
        let image = try XCTUnwrap(ArtworkStore.shared.image(.title, for: rom))
        XCTAssertEqual(image.size.width / image.size.height, 4.0 / 3.0, accuracy: 0.01)
    }
}
