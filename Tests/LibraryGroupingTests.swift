import XCTest
@testable import Duomulator

/// The library's Manufacturer > Console > Games hierarchy.
final class LibraryGroupingTests: XCTestCase {
    func testEverySystemHasAManufacturer() {
        let makers = Dictionary(grouping: GameSystem.allCases, by: \.manufacturer)
        XCTAssertEqual(Set(makers.keys), ["Nintendo", "Sega", "Arcade", "Sony"])
        XCTAssertEqual(Set(makers["Nintendo"] ?? []), [.nes, .snes, .nds, .n64])
        XCTAssertEqual(Set(makers["Sega"] ?? []), [.genesis, .segaCD, .sega32x])
    }

    func testConsolesAreInReleaseOrder() {
        let nintendo = GameSystem.allCases.filter { $0.manufacturer == "Nintendo" }
            .sorted { $0.releaseYear < $1.releaseYear }
        XCTAssertEqual(nintendo, [.nes, .snes, .n64, .nds])
        let sega = GameSystem.allCases.filter { $0.manufacturer == "Sega" }
            .sorted { $0.releaseYear < $1.releaseYear }
        XCTAssertEqual(sega, [.genesis, .segaCD, .sega32x])
    }
}

/// Recently Played: launch history and the per-console recent list.
final class RecentlyPlayedTests: XCTestCase {
    private func entry(_ name: String, played: Date?) -> ROMEntry {
        ROMEntry(url: URL(filePath: "/tmp/\(name)"), fileSize: 0, hasSuspendState: false,
                 hasSRAM: false, system: .snes, lastPlayed: played)
    }

    func testRecentIsMostRecentFirstAndCapped() {
        let now = Date()
        let entries = (0..<8).map { entry("Game \($0).sfc", played: now.addingTimeInterval(Double($0) * 60)) }
            + [entry("Never Played.sfc", played: nil)]
        let recent = ROMLibrary.recent(entries)
        XCTAssertEqual(recent.map(\.fileName), ["Game 7.sfc", "Game 6.sfc", "Game 5.sfc", "Game 4.sfc", "Game 3.sfc"])
        XCTAssertFalse(recent.contains { $0.lastPlayed == nil })
        XCTAssertNotEqual(recent[0].recentID, recent[0].id.path, "distinct row identity from the full list")
    }

    func testHistoryFollowsRenameAndDelete() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "duotest-\(UUID().uuidString)"))
        let date = Date(timeIntervalSince1970: 1_000_000)
        RecentlyPlayed.mark("Zelda.sfc", at: date, defaults: defaults)
        XCTAssertEqual(RecentlyPlayed.dates(defaults: defaults)["Zelda.sfc"], date)
        RecentlyPlayed.move("Zelda.sfc", to: "Link.sfc", defaults: defaults)
        XCTAssertNil(RecentlyPlayed.dates(defaults: defaults)["Zelda.sfc"])
        XCTAssertEqual(RecentlyPlayed.dates(defaults: defaults)["Link.sfc"], date)
        RecentlyPlayed.forget("Link.sfc", defaults: defaults)
        XCTAssertTrue(RecentlyPlayed.dates(defaults: defaults).isEmpty)
    }
}
