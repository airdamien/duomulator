import Foundation

// STUB — owned by the input module. Keep signatures.
/// Feeds MFi / Xbox / PlayStation controllers and hardware keyboards into `InputHub`.
final class GameControllerManager {
    static let shared = GameControllerManager()
    /// True while at least one physical controller is connected (UI hides touch controls).
    private(set) var isControllerConnected = false
    var onConnectionChange: ((Bool) -> Void)?
    /// Called on the controller's menu/home button.
    var onMenu: (() -> Void)?
    func start(hub: InputHub = .shared) {}
    func stop() {}
}
