import SwiftUI
import UIKit

// SCRATCH — temporary harness for layout screenshots; reverted before commit.
@main
struct DuomulatorApp: App {
    var body: some Scene {
        WindowGroup { ScratchHost().ignoresSafeArea() }
    }
}

struct ScratchHost: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController { ScratchRoot() }
    func updateUIViewController(_ vc: UIViewController, context: Context) {}
}

final class ScratchRoot: UIViewController {
    private var shown = false
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !shown else { return }
        shown = true
        let game = GameViewController(rom: URL(fileURLWithPath: "/tmp/Dummy Game.sfc"))
        present(game, animated: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            func walk(_ v: UIView) {
                if v is GameRenderView { v.backgroundColor = .systemBlue }
                if v is TouchControllerView { v.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.5) }
                v.subviews.forEach(walk)
            }
            walk(game.view)
            NSLog("SCRATCH bounds \(game.view.bounds) safe \(game.view.safeAreaInsets)")
            for v in game.view.subviews { NSLog("SCRATCH sub \(type(of: v)) \(v.frame) alpha \(v.alpha)") }
            if #available(iOS 27.1, *) {
                for k in [UIView.ReservedRegion.Kind.division, .occlusion] {
                    for reg in game.view.reservedRegions(kind: k, options: .includeInactive) {
                        NSLog("SCRATCH region \(k) frame \(reg.frame) margins \(reg.margins) active \(reg.isActive)")
                    }
                }
            }
            if ProcessInfo.processInfo.arguments.contains("-openMenu") {
                func findMenu(_ v: UIView) -> UIButton? {
                    if let b = v as? UIButton, b.accessibilityLabel == "Menu" { return b }
                    for s in v.subviews { if let b = findMenu(s) { return b } }
                    return nil
                }
                findMenu(game.view)?.sendActions(for: .primaryActionTriggered)
            }
        }
    }
}
