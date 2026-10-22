import UIKit

/// In-game pause menu: a dimmed full-screen overlay with a scrollable card. The owner sets
/// `cardArea` so the card stays clear of the fold (tent posture) and of the game image.
final class GameMenuView: UIView {
    /// Everything the menu displays; rebuilt by the owner and passed to `update(_:)`.
    struct State {
        var title: String
        /// Modification dates of save-state slots 1...3 (nil = empty).
        var slotDates: [Int: Date]
        var fastForward: Bool
        var muted: Bool
        var layout: PostureOverride
        var scaling: GameRenderView.Scaling
        var filter: GameRenderView.Filter
    }

    static let slots = 1...3

    var onResume: (() -> Void)?
    var onSave: ((Int) -> Void)?
    var onLoad: ((Int) -> Void)?
    var onFastForward: ((Bool) -> Void)?
    var onMute: ((Bool) -> Void)?
    var onLayout: ((PostureOverride) -> Void)?
    var onScaling: ((GameRenderView.Scaling) -> Void)?
    var onFilter: ((GameRenderView.Filter) -> Void)?
    var onReset: (() -> Void)?
    var onQuit: (() -> Void)?

    /// Rect (in this view's coordinates) the card must fit inside. Defaults to the safe area.
    var cardArea: CGRect? { didSet { setNeedsLayout() } }

    private let backdrop = UIControl()
    private let card = UIView()
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let titleLabel = UILabel()
    private var saveButtons: [Int: UIButton] = [:]
    private var loadButtons: [Int: UIButton] = [:]
    private let fastSwitch = UISwitch()
    private let muteSwitch = UISwitch()
    private let layoutControl = UISegmentedControl(items: ["Auto", "DS (tent)", "Flat"])
    private let scalingControl = UISegmentedControl(items: ["Aspect", "Integer"])
    private let filterControl = UISegmentedControl(items: ["Sharp", "Smooth"])

    private static let layoutOrder: [PostureOverride] = [.auto, .forceTent, .forceFlat]

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backdrop.backgroundColor = UIColor(white: 0, alpha: 0.55)
        backdrop.addAction(UIAction { [weak self] _ in self?.onResume?() }, for: .touchUpInside)
        addSubview(backdrop)

        card.backgroundColor = UIColor(white: 0.11, alpha: 0.97)
        card.layer.cornerRadius = 22
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor(white: 1, alpha: 0.08).cgColor
        card.clipsToBounds = true
        addSubview(card)

        scroll.alwaysBounceVertical = false
        scroll.indicatorStyle = .white
        card.addSubview(scroll)

        stack.axis = .vertical
        stack.spacing = 14
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 18, leading: 18, bottom: 18, trailing: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        ])
        buildContent()
        overrideUserInterfaceStyle = .dark
        accessibilityViewIsModal = true
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Content

    private func buildContent() {
        titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 2
        titleLabel.textAlignment = .center
        stack.addArrangedSubview(titleLabel)

        var resume = UIButton.Configuration.filled()
        resume.title = "Resume"
        resume.image = UIImage(systemName: "play.fill")
        resume.imagePadding = 8
        resume.cornerStyle = .large
        resume.buttonSize = .large
        let resumeButton = UIButton(configuration: resume, primaryAction: UIAction { [weak self] _ in
            self?.onResume?()
        })
        stack.addArrangedSubview(resumeButton)

        stack.addArrangedSubview(sectionLabel("Save State"))
        stack.addArrangedSubview(slotRow(into: &saveButtons) { [weak self] slot in self?.onSave?(slot) })
        stack.addArrangedSubview(sectionLabel("Load State"))
        stack.addArrangedSubview(slotRow(into: &loadButtons) { [weak self] slot in self?.onLoad?(slot) })

        fastSwitch.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onFastForward?(self.fastSwitch.isOn)
        }, for: .valueChanged)
        muteSwitch.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onMute?(self.muteSwitch.isOn)
        }, for: .valueChanged)
        stack.addArrangedSubview(switchRow("Fast-forward", fastSwitch))
        stack.addArrangedSubview(switchRow("Mute", muteSwitch))

        layoutControl.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onLayout?(Self.layoutOrder[max(0, self.layoutControl.selectedSegmentIndex)])
        }, for: .valueChanged)
        scalingControl.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onScaling?(self.scalingControl.selectedSegmentIndex == 1 ? .integer : .aspectFit)
        }, for: .valueChanged)
        filterControl.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onFilter?(self.filterControl.selectedSegmentIndex == 1 ? .linear : .nearest)
        }, for: .valueChanged)
        stack.addArrangedSubview(segmentRow("Layout", layoutControl))
        stack.addArrangedSubview(segmentRow("Scaling", scalingControl))
        stack.addArrangedSubview(segmentRow("Filter", filterControl))

        var reset = UIButton.Configuration.gray()
        reset.title = "Reset"
        reset.image = UIImage(systemName: "arrow.clockwise")
        reset.imagePadding = 6
        reset.cornerStyle = .large
        var quit = UIButton.Configuration.tinted()
        quit.title = "Quit"
        quit.image = UIImage(systemName: "xmark")
        quit.imagePadding = 6
        quit.cornerStyle = .large
        quit.baseForegroundColor = .systemRed
        quit.baseBackgroundColor = .systemRed
        let bottom = UIStackView(arrangedSubviews: [
            UIButton(configuration: reset, primaryAction: UIAction { [weak self] _ in self?.onReset?() }),
            UIButton(configuration: quit, primaryAction: UIAction { [weak self] _ in self?.onQuit?() }),
        ])
        bottom.axis = .horizontal
        bottom.distribution = .fillEqually
        bottom.spacing = 10
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(bottom)
    }

    private func sectionLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text.uppercased()
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = UIColor(white: 1, alpha: 0.55)
        return label
    }

    private func slotRow(into buttons: inout [Int: UIButton], action: @escaping (Int) -> Void) -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.spacing = 8
        for slot in Self.slots {
            var config = UIButton.Configuration.gray()
            config.title = "Slot \(slot)"
            config.titleAlignment = .center
            config.cornerStyle = .large
            config.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
                var attrs = attrs
                attrs.font = .systemFont(ofSize: 11)
                return attrs
            }
            let button = UIButton(configuration: config, primaryAction: UIAction { _ in action(slot) })
            buttons[slot] = button
            row.addArrangedSubview(button)
        }
        return row
    }

    private func switchRow(_ title: String, _ control: UISwitch) -> UIStackView {
        let label = UILabel()
        label.text = title
        label.textColor = .white
        label.font = .systemFont(ofSize: 16, weight: .medium)
        let row = UIStackView(arrangedSubviews: [label, control])
        row.axis = .horizontal
        row.alignment = .center
        return row
    }

    private func segmentRow(_ title: String, _ control: UISegmentedControl) -> UIStackView {
        let label = UILabel()
        label.text = title
        label.textColor = .white
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [label, control])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        return row
    }

    /// Refreshes every control from `state`.
    func update(_ state: State) {
        titleLabel.text = state.title
        for slot in Self.slots {
            let date = state.slotDates[slot]
            let subtitle = date.map { Self.dateFormatter.string(from: $0) } ?? "Empty"
            saveButtons[slot]?.configuration?.subtitle = subtitle
            loadButtons[slot]?.configuration?.subtitle = subtitle
            loadButtons[slot]?.isEnabled = date != nil
            saveButtons[slot]?.accessibilityLabel = "Save to slot \(slot), \(subtitle)"
            loadButtons[slot]?.accessibilityLabel = "Load slot \(slot), \(subtitle)"
        }
        fastSwitch.isOn = state.fastForward
        muteSwitch.isOn = state.muted
        layoutControl.selectedSegmentIndex = Self.layoutOrder.firstIndex(of: state.layout) ?? 0
        scalingControl.selectedSegmentIndex = state.scaling == .integer ? 1 : 0
        filterControl.selectedSegmentIndex = state.filter == .linear ? 1 : 0
        setNeedsLayout()
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        backdrop.frame = bounds
        let area = (cardArea ?? bounds.inset(by: safeAreaInsets)).insetBy(dx: 12, dy: 12)
        let width = max(0, min(area.width, 440))
        let fitting = stack.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        let height = max(0, min(area.height, fitting.height))
        card.frame = CGRect(x: area.midX - width / 2, y: area.midY - height / 2,
                            width: width, height: height).integral
        scroll.frame = card.bounds
        scroll.alwaysBounceVertical = fitting.height > height
    }
}
