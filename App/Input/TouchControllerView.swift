import UIKit

// STUB — owned by the input module. Keep signatures.
/// On-screen SNES controller. `.overlay` floats translucent controls over the game
/// (closed / flat postures); `.panel` fills a dedicated area below the fold (tent posture).
final class TouchControllerView: UIView {
    enum Style { case overlay, panel }
    var style: Style { didSet { setNeedsLayout() } }
    /// Called when the on-screen menu button is tapped.
    var onMenu: (() -> Void)?

    init(style: Style, hub: InputHub = .shared) {
        self.style = style
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }
}
