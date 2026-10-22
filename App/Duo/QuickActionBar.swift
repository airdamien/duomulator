import UIKit

/// Thin strip of one-tap actions shown under the game (tent posture, and flat portrait when
/// there's room): quick save, quick load, fast-forward toggle, menu. On the Duo's outer
/// display it stands vertically at the right edge, icons only, Menu first, the way system
/// bars move there.
final class QuickActionBar: UIView {
    static let preferredHeight: CGFloat = 44
    static let verticalWidth: CGFloat = 52
    static var verticalHeight: CGFloat { 4 * 44 + 3 * 10 }

    var isVertical = false {
        didSet {
            guard isVertical != oldValue else { return }
            applyAxis()
        }
    }
    private let stack = UIStackView()

    var onSave: (() -> Void)?
    var onLoad: (() -> Void)?
    var onFastForward: (() -> Void)?
    var onMenu: (() -> Void)?

    /// Reflects `EmulatorCore.fastForward`; drives the toggle's highlighted look.
    var isFastForwarding = false { didSet { styleFastForward() } }
    /// Dims the load button when the quick slot is empty.
    var canLoad = true { didSet { loadButton.isEnabled = canLoad } }

    private let saveButton = QuickActionBar.makeButton(title: "Save", symbol: "record.circle")
    private let loadButton = QuickActionBar.makeButton(title: "Load", symbol: "arrow.counterclockwise")
    private let fastButton = QuickActionBar.makeButton(title: "Fast", symbol: "forward.fill")
    private let menuButton = QuickActionBar.makeButton(title: "Menu", symbol: "line.3.horizontal")

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        saveButton.addAction(UIAction { [weak self] _ in self?.onSave?() }, for: .primaryActionTriggered)
        loadButton.addAction(UIAction { [weak self] _ in self?.onLoad?() }, for: .primaryActionTriggered)
        fastButton.addAction(UIAction { [weak self] _ in self?.onFastForward?() }, for: .primaryActionTriggered)
        menuButton.addAction(UIAction { [weak self] _ in self?.onMenu?() }, for: .primaryActionTriggered)
        saveButton.accessibilityLabel = "Quick save"
        loadButton.accessibilityLabel = "Quick load"
        fastButton.accessibilityLabel = "Fast forward"
        menuButton.accessibilityLabel = "Menu"
        applyAxis()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func applyAxis() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let order = isVertical ? [menuButton, saveButton, loadButton, fastButton]
                               : [saveButton, loadButton, fastButton, menuButton]
        order.forEach(stack.addArrangedSubview)
        stack.axis = isVertical ? .vertical : .horizontal
        stack.spacing = isVertical ? 10 : 8
        for (button, title) in [(saveButton, "Save"), (loadButton, "Load"), (fastButton, "Fast"), (menuButton, "Menu")] {
            button.configuration?.title = isVertical ? nil : title
            button.configuration?.cornerStyle = isVertical ? .large : .capsule
        }
        styleFastForward()
    }

    private static func makeButton(title: String, symbol: String) -> UIButton {
        var config = UIButton.Configuration.gray()
        config.title = title
        config.image = UIImage(systemName: symbol,
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        config.imagePadding = 4
        // Four buttons share ~90pt each on the outer display; keep titles on one line.
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
        config.titleLineBreakMode = .byTruncatingTail
        config.cornerStyle = .capsule
        config.baseForegroundColor = .white
        config.baseBackgroundColor = UIColor(white: 1, alpha: 0.12)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var attrs = attrs
            attrs.font = .systemFont(ofSize: 14, weight: .semibold)
            return attrs
        }
        let button = UIButton(configuration: config)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        return button
    }

    private func styleFastForward() {
        guard var config = fastButton.configuration else { return }
        config.baseBackgroundColor = isFastForwarding ? .systemOrange : UIColor(white: 1, alpha: 0.12)
        config.baseForegroundColor = isFastForwarding ? .black : .white
        fastButton.configuration = config
        fastButton.accessibilityValue = isFastForwarding ? "On" : "Off"
    }
}
