import Foundation

/// Gameplay display/audio preferences changed from the in-game menu. Persisted in
/// UserDefaults so they carry across games and launches.
enum GameSettings {
    /// "aspect" or "integer".
    static let scalingKey = "scaling"
    /// "sharp" or "smooth".
    static let filterKey = "filter"
    /// Bool.
    static let mutedKey = "muted"

    static var scaling: GameRenderView.Scaling {
        get { UserDefaults.standard.string(forKey: scalingKey) == "integer" ? .integer : .aspectFit }
        set { UserDefaults.standard.set(newValue == .integer ? "integer" : "aspect", forKey: scalingKey) }
    }

    static var filter: GameRenderView.Filter {
        get { UserDefaults.standard.string(forKey: filterKey) == "smooth" ? .linear : .nearest }
        set { UserDefaults.standard.set(newValue == .linear ? "smooth" : "sharp", forKey: filterKey) }
    }

    static var muted: Bool {
        get { UserDefaults.standard.bool(forKey: mutedKey) }
        set { UserDefaults.standard.set(newValue, forKey: mutedKey) }
    }
}
