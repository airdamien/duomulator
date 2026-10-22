import Foundation

/// The arcade sets FinalBurn Neo can run, from ArcadeCatalog.tsv (generated from FBNeo's
/// gamelist.txt). Arcade ROMs are zips named after their set ("mslug.zip"), so the set name
/// is how they are recognized, titled and grouped.
enum ArcadeCatalog {
    struct Entry: Sendable {
        let title: String
        let year: String
        let company: String
        let system: GameSystem
        /// BIOS sets (neogeo.zip, pgm.zip) are needed beside the games but aren't playable.
        let isBIOS: Bool
    }

    /// Lowercased set name -> entry. Loaded once, on first use (~8,500 sets, ~0.5 MB).
    static let entries: [String: Entry] = load()

    static func entry(forSet rom: URL) -> Entry? {
        entries[rom.deletingPathExtension().lastPathComponent.lowercased()]
    }

    static func system(forSet rom: URL) -> GameSystem? { entry(forSet: rom)?.system }

    private static func load() -> [String: Entry] {
        guard let url = Bundle.main.url(forResource: "ArcadeCatalog", withExtension: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var result: [String: Entry] = [:]
        result.reserveCapacity(9_000)
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count >= 6 else { continue }
            let system: GameSystem = switch f[4] {
            case "n": .neoGeo
            case "c": .cps
            default: .arcade
            }
            result[String(f[0]).lowercased()] = Entry(title: String(f[1]), year: String(f[2]),
                                                      company: String(f[3]), system: system,
                                                      isBIOS: f[5] == "1")
        }
        return result
    }
}
