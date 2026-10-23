import XCTest
@testable import Duomulator

/// Importing ROMs through the queue: background chunked copies, retry-then-skip, resume,
/// and a queue that survives a restart.
@MainActor
final class ImportTests: XCTestCase {
    private var temp: URL!
    private var created: [URL] = []

    override func setUp() async throws {
        temp = FileManager.default.temporaryDirectory.appending(path: "ImportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for url in created { try? FileManager.default.removeItem(at: url) }
        try? FileManager.default.removeItem(at: temp)
    }

    private func makeQueue() -> ImportQueue {
        let queue = ImportQueue(storeURL: temp.appending(path: "queue-\(UUID().uuidString).json"))
        queue.retryDelay = 0.01
        return queue
    }

    private func makeSource(_ name: String, bytes: Int) throws -> (URL, Data) {
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { raw in
            for i in stride(from: 0, to: raw.count, by: 4096) { raw[i] = UInt8(truncatingIfNeeded: i / 4096 + 7) }
        }
        let url = temp.appending(path: name)
        try data.write(to: url)
        return (url, data)
    }

    func testLargeImportCopiesExactlyAndCleansUp() async throws {
        let (source, data) = try makeSource("duoimport-\(UUID().uuidString).nes", bytes: 9 * 1024 * 1024 + 123)
        let library = ROMLibrary(imports: makeQueue())
        let report = await library.importFiles([source])
        let imported = try XCTUnwrap(report.imported.first)
        created.append(imported)
        XCTAssertEqual(try Data(contentsOf: imported), data)
        XCTAssertNil(library.importProgress, "the banner goes away when the import finishes")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: GamePaths.roms.path)
            .filter { $0.hasPrefix(".importing-") }
        XCTAssertEqual(leftovers, [])

        let again = await library.importFiles([source])
        XCTAssertEqual(again.duplicates.count, 1, "importing the same file again is a duplicate")
        XCTAssertTrue(again.imported.isEmpty)
    }

    func testAFailingFileDoesNotStopTheRest() async throws {
        let (missing, _) = try makeSource("duogone-\(UUID().uuidString).nes", bytes: 1024)
        let (good, data) = try makeSource("duogood-\(UUID().uuidString).nes", bytes: 64 * 1024)
        let queue = makeQueue()
        let library = ROMLibrary(imports: queue)
        // The first file disappears after it's picked, the way a dropped network share would.
        let pending = Task { await library.importFiles([missing, good]) }
        try FileManager.default.removeItem(at: missing)
        let report = await pending.value
        let imported = try XCTUnwrap(report.imported.first)
        created.append(imported)
        XCTAssertEqual(try Data(contentsOf: imported), data)
        XCTAssertEqual(report.failed, [missing.lastPathComponent])
        let failed = try XCTUnwrap(queue.items.first { $0.name == missing.lastPathComponent })
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.attempts, ImportQueue.maxAttempts)
    }

    func testPartialCopyResumes() throws {
        let (source, data) = try makeSource("duoresume-\(UUID().uuidString).nes", bytes: 10 * 1024 * 1024)
        let item = ImportQueue.Item(id: UUID(), name: source.lastPathComponent, path: source.path,
                                    size: Int64(data.count))
        // An earlier attempt got 3 MB in before it was interrupted.
        let partial = ImportQueue.partialURL(for: item.id)
        try data.prefix(3 * 1024 * 1024).write(to: partial)
        var firstReport: Int64?
        let outcome = ImportQueue.copy(item, shouldStop: { nil }) { done, _ in
            if firstReport == nil { firstReport = done }
        }
        guard case .saved(let name, let bytes) = outcome else { return XCTFail("\(outcome)") }
        let saved = GamePaths.roms.appending(path: name)
        created.append(saved)
        XCTAssertEqual(firstReport, 3 * 1024 * 1024, "picked up where the partial copy ended")
        XCTAssertEqual(bytes, Int64(data.count))
        XCTAssertEqual(try Data(contentsOf: saved), data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testQueueSurvivesARestart() throws {
        let store = temp.appending(path: "store.json")
        var item = ImportQueue.Item(id: UUID(), name: "Game.nes", path: "/nowhere/Game.nes", size: 10)
        item.state = .copying
        try JSONEncoder().encode([item]).write(to: store)
        let reloaded = ImportQueue(storeURL: store)
        XCTAssertEqual(reloaded.items.first?.state, .waiting, "an interrupted copy goes back in line")
        XCTAssertTrue(reloaded.hasWork)
    }
}
