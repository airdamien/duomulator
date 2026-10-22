import Foundation

// MARK: - Settings keys

/// UserDefaults keys and raw values shared with the gameplay modules. The Settings screen
/// writes these through @AppStorage; GameViewController / renderer / input read them back.
/// The strings are the contract — never rename them.
enum AppSettings {
    /// Bool. Touch-control haptics.
    static let hapticsKey = "hapticsEnabled"
    /// String, one of `PostureOverride`. Forces a layout regardless of the hinge.
    static let postureOverrideKey = "postureOverride"
    /// String, one of `Scaling`.
    static let scalingKey = "scaling"
    /// String, one of `Filter`.
    static let filterKey = "filter"

    enum PostureOverride: String, CaseIterable, Identifiable {
        case auto, forceTent, forceFlat
        var id: String { rawValue }
        var label: String {
            switch self {
            case .auto: "Auto"
            case .forceTent: "DS (game above fold)"
            case .forceFlat: "Flat"
            }
        }
    }

    enum Scaling: String, CaseIterable, Identifiable {
        case aspectFit, integer
        var id: String { rawValue }
        var label: String { self == .aspectFit ? "Aspect Fit" : "Integer" }
    }

    enum Filter: String, CaseIterable, Identifiable {
        case nearest, linear
        var id: String { rawValue }
        var label: String { self == .nearest ? "Sharp" : "Smooth" }
    }

    /// Registers defaults so modules reading UserDefaults directly (e.g. `bool(forKey:)`)
    /// see the same values the Settings screen shows before the user ever touches it.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            hapticsKey: true,
            postureOverrideKey: PostureOverride.auto.rawValue,
            scalingKey: Scaling.aspectFit.rawValue,
            filterKey: Filter.nearest.rawValue,
        ])
    }
}
