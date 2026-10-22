import UIKit

// MARK: - Game presentation

/// Presents GameViewController full screen from the active window scene with a plain UIKit
/// modal, so the game owns status bar, home indicator and rotation without SwiftUI wrappers.
enum GameLauncher {
    /// - Parameter onFinish: called on the main thread after the game has been dismissed.
    static func play(_ rom: URL, onFinish: @escaping () -> Void) {
        // A game already on screen (or mid-presentation from a double tap) wins.
        guard let presenter = topViewController(), !(presenter is GameViewController) else { return }
        let game = GameViewController(rom: rom)
        game.modalPresentationStyle = .fullScreen
        game.modalTransitionStyle = .crossDissolve
        game.onExit = { [weak game] in
            guard let game, game.presentingViewController != nil else {
                onFinish()
                return
            }
            game.dismiss(animated: true, completion: onFinish)
        }
        presenter.present(game, animated: true)
    }

    /// Top-most view controller of the foreground scene's key window.
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}
