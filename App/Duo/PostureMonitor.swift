import UIKit

// STUB — owned by the Duo module. Keep signatures.
/// Tracks hinge state + the fold's division region for a view and reports a `Posture`.
final class PostureMonitor {
    private(set) var posture: Posture = .flat
    var onChange: ((Posture) -> Void)?
    init(view: UIView) {}
    /// Re-evaluate (call from viewDidLayoutSubviews).
    func refresh() {}
}
