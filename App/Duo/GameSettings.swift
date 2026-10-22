import Foundation

/// Gameplay display/audio preferences changed from the in-game menu. Persisted in
/// UserDefaults so they carry across games and launches.
enum GameSettings {
    /// Shared with the Settings screen; raw values are `AppSettings.Scaling`.
    static let scalingKey = AppSettings.scalingKey
    /// Shared with the Settings screen; raw values are `AppSettings.Filter`.
    static let filterKey = AppSettings.filterKey
    /// Bool.
    static let mutedKey = "muted"

    static var scaling: GameRenderView.Scaling {
        get { UserDefaults.standard.string(forKey: scalingKey) == AppSettings.Scaling.integer.rawValue ? .integer : .aspectFit }
        set { UserDefaults.standard.set((newValue == .integer ? AppSettings.Scaling.integer : .aspectFit).rawValue, forKey: scalingKey) }
    }

    static var filter: GameRenderView.Filter {
        get { UserDefaults.standard.string(forKey: filterKey) == AppSettings.Filter.linear.rawValue ? .linear : .nearest }
        set { UserDefaults.standard.set((newValue == .linear ? AppSettings.Filter.linear : .nearest).rawValue, forKey: filterKey) }
    }

    static var muted: Bool {
        get { UserDefaults.standard.bool(forKey: mutedKey) }
        set { UserDefaults.standard.set(newValue, forKey: mutedKey) }
    }
}
