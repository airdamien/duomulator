import XCTest
@testable import Duomulator

/// Importing ROMs: copied in the background in chunks, reported, cleaned up.
@MainActor
final class ImportTests: XCTestCase {
    func testLargeImportCopiesExactlyAndCleansUp() async throws {
        let source = FileManager.default.temporaryDirectory.appending(path: "duoimport-\(UUID().uuidString).nes")
        var data = Data(count: 9 * 1024 * 1024 + 123)   // spans several 4 MB chunks
        data.withUnsafeMutableBytes { raw in
            for i in stride(from: 0, to: raw.count, by: 4096) { raw[i] = UInt8(truncatingIfNeeded: i / 4096) }
        }
        try data.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let library = ROMLibrary()
        let report = await library.importFiles([source])
        let imported = try XCTUnwrap(report.imported.first)
        defer { try? FileManager.default.removeItem(at: imported) }
        XCTAssertEqual(try Data(contentsOf: imported), data)
        XCTAssertNil(library.importProgress, "the banner goes away when the import finishes")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: GamePaths.roms.path)
            .filter { $0.hasPrefix(".importing-") }
        XCTAssertEqual(leftovers, [])

        // Importing the same file again is a duplicate, not a second copy.
        let again = await library.importFiles([source])
        XCTAssertEqual(again.duplicates.count, 1)
        XCTAssertTrue(again.imported.isEmpty)
    }
}
