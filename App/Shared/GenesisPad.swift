import Foundation

/// Which Genesis controller a Sega game gets. Most games work with the 6-button pad and many
/// later ones (fighting games especially) need it, but a few early games misread its extra
/// buttons. Those default to 3 buttons; everything else, including unknown games, gets 6.
/// The player can override the choice per game from the in-game menu.
enum GenesisPad: String, CaseIterable, Sendable {
    case three, six

    var padStyle: GameSystem.PadStyle { self == .six ? .genesis6 : .genesis3 }

    /// PicoDrive's `picodrive_input1` value for this pad.
    var coreOptionValue: String { self == .six ? "6 button pad" : "3 button pad" }

    /// What the game gets: the player's per-game choice, else the lookup table.
    static func effective(for rom: URL, defaults: UserDefaults = .standard) -> GenesisPad {
        override(for: rom, defaults: defaults) ?? automatic(for: rom)
    }

    /// Lookup-table choice for a ROM, from its file name.
    static func automatic(for rom: URL) -> GenesisPad {
        threeButtonOnly.contains(normalizedTitle(of: rom)) ? .three : .six
    }

    /// The player's per-game choice, or nil for automatic.
    static func override(for rom: URL, defaults: UserDefaults = .standard) -> GenesisPad? {
        defaults.string(forKey: key(for: rom)).flatMap(GenesisPad.init(rawValue:))
    }

    static func setOverride(_ pad: GenesisPad?, for rom: URL, defaults: UserDefaults = .standard) {
        defaults.set(pad?.rawValue, forKey: key(for: rom))
    }

    private static func key(for rom: URL) -> String { "genesisPad." + rom.lastPathComponent }

    /// Title reduced for matching: no extension, no "(U)" / "[!]" style tags, no leading or
    /// trailing "The", letters and digits only. "Golden Axe II (U) [!].bin" -> "goldenaxeii".
    static func normalizedTitle(of rom: URL) -> String {
        var name = rom.deletingPathExtension().lastPathComponent
        name = name.replacingOccurrences(of: #"\([^)]*\)|\[[^\]]*\]"#, with: "", options: .regularExpression)
        name = name.lowercased()
            .replacingOccurrences(of: #"^the\s+|,\s*the\b"#, with: "", options: .regularExpression)
        return name.filter { $0.isLetter || $0.isNumber }
    }

    /// Games commonly reported to malfunction with the 6-button pad (they read its extra
    /// buttons as presses of others). A starting list, not exhaustive: if a game acts up,
    /// switch it to 3-button in the in-game menu. Keys are `normalizedTitle` values.
    static let threeButtonOnly: Set<String> = [
        "forgottenworlds",
        "goldenaxeii",
        "mspacman",
        "sunsetriders",
    ]
}
