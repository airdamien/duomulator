import XCTest
@testable import Duomulator

/// The library's Manufacturer > Console > Games hierarchy.
final class LibraryGroupingTests: XCTestCase {
    func testEverySystemHasAManufacturer() {
        let makers = Dictionary(grouping: GameSystem.allCases, by: \.manufacturer)
        XCTAssertEqual(Set(makers.keys), ["Nintendo", "Sega"])
        XCTAssertEqual(Set(makers["Nintendo"] ?? []), [.nes, .snes, .nds])
        XCTAssertEqual(Set(makers["Sega"] ?? []), [.genesis, .segaCD, .sega32x])
    }

    func testConsolesAreInReleaseOrder() {
        let nintendo = GameSystem.allCases.filter { $0.manufacturer == "Nintendo" }
            .sorted { $0.releaseYear < $1.releaseYear }
        XCTAssertEqual(nintendo, [.nes, .snes, .nds])
        let sega = GameSystem.allCases.filter { $0.manufacturer == "Sega" }
            .sorted { $0.releaseYear < $1.releaseYear }
        XCTAssertEqual(sega, [.genesis, .segaCD, .sega32x])
    }
}
