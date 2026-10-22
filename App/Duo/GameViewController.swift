import UIKit

// STUB — owned by the Duo module. Keep signatures.
/// Full-screen gameplay screen. Lays out GameRenderView + TouchControllerView per Posture.
final class GameViewController: UIViewController {
    let rom: URL
    /// Called when the user quits back to the library.
    var onExit: (() -> Void)?
    init(rom: URL) { self.rom = rom; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
}
