import UIKit

/// On-screen SNES controller. `.overlay` floats translucent controls over the game
/// (closed / flat postures); `.panel` fills a dedicated area below the fold (tent posture).
///
/// Every finger is tracked as its own `UITouch`; after each touch event the pressed set is
/// recomputed from all fingers still down and written to `InputHub` (source `.touch`), so
/// nothing can get stuck when fingers overlap, slide between buttons, or are cancelled.
final class TouchControllerView: UIView {
    enum Style { case overlay, panel }
    var style: Style {
        didSet {
            guard style != oldValue else { return }
            releaseAllTouches()
            applyStyle()
            setNeedsLayout()
        }
    }
    /// Which console's pad to show (NES has no X/Y/L/R).
    var system: GameSystem = .snes {
        didSet {
            guard system != oldValue else { return }
            releaseAllTouches()
            setNeedsLayout()
        }
    }
    /// Area (in this view's coordinates) to keep clear of controls: the DS touch screen.
    var reservedRect: CGRect? {
        didSet {
            guard reservedRect != oldValue else { return }
            releaseAllTouches()
            setNeedsLayout()
        }
    }
    /// Called when the on-screen menu button is tapped.
    var onMenu: (() -> Void)?

    /// Global haptics toggle; mirrors `InputSettings.hapticsEnabled` (UserDefaults "hapticsEnabled").
    static var hapticsEnabled: Bool {
        get { InputSettings.hapticsEnabled }
        set { InputSettings.hapticsEnabled = newValue }
    }

    private let hub: InputHub
    private(set) var layout: ControllerLayout
    /// Fingers currently down and the control each one is attached to.
    private var activeTouches: [UITouch: TouchControl] = [:]
    /// Last mask written to the hub; used to detect new presses for haptics and visuals.
    private(set) var pressedButtons: SNESButtons = []
    private var menuHighlighted = false
    /// Bound to this view so the system can route feedback to the right display/scene.
    private lazy var haptics = UIImpactFeedbackGenerator(style: .light, view: self)
    private let skin = ControllerSkin()

    init(style: Style, hub: InputHub = .shared) {
        self.style = style
        self.hub = hub
        self.layout = ControllerLayout(bounds: .zero, style: style.layoutStyle)
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        isExclusiveTouch = false
        layer.addSublayer(skin)
        applyStyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout & drawing

    override func layoutSubviews() {
        super.layoutSubviews()
        let newLayout = ControllerLayout(bounds: bounds, safeArea: safeAreaInsets,
                                         style: style.layoutStyle, system: system,
                                         reserved: reservedRect)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        skin.frame = bounds
        skin.contentsScale = traitCollection.displayScale
        if newLayout != layout || skin.needsRebuild {
            layout = newLayout
            skin.rebuild(for: layout, scale: traitCollection.displayScale)
        }
        skin.show(pressed: pressedButtons, menu: menuHighlighted)
        CATransaction.commit()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    private func applyStyle() {
        backgroundColor = style == .panel ? ControllerSkin.panelBackground : .clear
        isOpaque = style == .panel
        skin.skinStyle = style.layoutStyle
        skin.needsRebuild = true
    }

    // MARK: Hit-testing

    /// Overlay only claims touches that land on (or near) a control, so gestures over the
    /// game pass through. The opaque panel claims its whole area so fingers resting on it
    /// can slide onto buttons and never fall through to whatever is behind.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard bounds.contains(point) else { return false }
        if style == .panel { return true }
        return layout.control(at: point) != nil
    }

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Defensive: drop any finger UIKit has finished with but we never saw end.
        activeTouches = activeTouches.filter { $0.key.phase != .ended && $0.key.phase != .cancelled }
        if Self.hapticsEnabled { haptics.prepare() }
        for touch in touches {
            let p = touch.location(in: self)
            activeTouches[touch] = layout.control(at: p) ?? .buttons
        }
        update(firingMenuFor: [])
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches where activeTouches[touch] == .buttons {
            // A free finger that slides onto the d-pad takes it over until lifted.
            if layout.control(at: touch.location(in: self)) == .dpad { activeTouches[touch] = .dpad }
        }
        update(firingMenuFor: [])
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let tappedMenu = touches.filter {
            activeTouches[$0] == .menu && layout.isOnMenu($0.location(in: self))
        }
        for touch in touches { activeTouches[touch] = nil }
        update(firingMenuFor: tappedMenu)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { activeTouches[touch] = nil }
        update(firingMenuFor: [])
    }

    /// Recomputes the pressed set from every finger still down and publishes it.
    private func update(firingMenuFor tappedMenu: Set<UITouch>) {
        var mask: SNESButtons = []
        var menuDown = false
        for (touch, control) in activeTouches {
            let p = touch.location(in: self)
            if control == .menu {
                menuDown = menuDown || layout.isOnMenu(p)
            } else {
                mask.formUnion(layout.buttons(at: p, for: control))
            }
        }

        let newlyPressed = !mask.subtracting(pressedButtons).isEmpty || (menuDown && !menuHighlighted)
        if newlyPressed && Self.hapticsEnabled {
            haptics.impactOccurred()
            haptics.prepare()
        }

        hub.set(mask, source: .touch)
        if mask != pressedButtons || menuDown != menuHighlighted {
            pressedButtons = mask
            menuHighlighted = menuDown
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            skin.show(pressed: mask, menu: menuDown)
            CATransaction.commit()
        }
        if !tappedMenu.isEmpty { onMenu?() }
    }

    /// Forgets every finger and releases all touch buttons.
    private func releaseAllTouches() {
        activeTouches.removeAll()
        update(firingMenuFor: [])
    }

    override var isHidden: Bool {
        didSet { if isHidden { releaseAllTouches() } }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil { releaseAllTouches() }
    }
}

private extension TouchControllerView.Style {
    var layoutStyle: ControllerLayout.Style {
        switch self {
        case .overlay: return .overlay
        case .panel: return .panel
        }
    }
}

// MARK: - Drawing

/// Shape-layer rendering of a `ControllerLayout`. Rebuilt on layout changes; pressed state
/// only toggles colors, so per-touch updates are cheap.
private final class ControllerSkin: CALayer {
    static let panelBackground = UIColor(red: 0.075, green: 0.075, blue: 0.085, alpha: 1)

    /// SNES face colors (Super Famicom / PAL palette).
    private static let faceColors: [UInt32: UIColor] = [
        SNESButtons.a.rawValue: UIColor(red: 0.89, green: 0.24, blue: 0.24, alpha: 1),
        SNESButtons.b.rawValue: UIColor(red: 0.96, green: 0.77, blue: 0.20, alpha: 1),
        SNESButtons.x.rawValue: UIColor(red: 0.28, green: 0.47, blue: 0.92, alpha: 1),
        SNESButtons.y.rawValue: UIColor(red: 0.22, green: 0.70, blue: 0.40, alpha: 1),
    ]
    /// The NES pad's A and B are both red.
    private static let nesFaceColor = UIColor(red: 0.82, green: 0.16, blue: 0.16, alpha: 1)
    private static let faceLabels: [UInt32: String] = [
        SNESButtons.a.rawValue: "A", SNESButtons.b.rawValue: "B",
        SNESButtons.x.rawValue: "X", SNESButtons.y.rawValue: "Y",
    ]

    var skinStyle: ControllerLayout.Style = .overlay
    var needsRebuild = true

    /// A drawable control: its shape, optional label, colors, and which buttons light it.
    private struct Part {
        let shape: CAShapeLayer
        let label: CATextLayer?
        let buttons: SNESButtons
        let fill: CGColor
        let pressedFill: CGColor
        let labelColor: CGColor
        let pressedLabelColor: CGColor
        /// Lit by the menu finger rather than by `buttons` (a d-pad arm lights whenever its
        /// direction is part of the pressed set, so diagonals light two arms).
        let isMenu: Bool
    }
    private var parts: [Part] = []

    func rebuild(for layout: ControllerLayout, scale: CGFloat) {
        sublayers?.forEach { $0.removeFromSuperlayer() }
        parts.removeAll()
        needsRebuild = false
        guard layout.dpadRadius > 0 else { return }

        let panel = skinStyle == .panel
        let neutral = panel ? UIColor(white: 0.19, alpha: 1) : UIColor(white: 1, alpha: 0.13)
        let neutralPressed = panel ? UIColor(white: 0.36, alpha: 1) : UIColor(white: 1, alpha: 0.40)
        let stroke = panel ? UIColor(white: 0.30, alpha: 1) : UIColor(white: 1, alpha: 0.32)
        let labelColor = panel ? UIColor(white: 0.72, alpha: 1) : UIColor(white: 1, alpha: 0.70)
        let labelPressed = UIColor(white: 1, alpha: 0.95)

        // D-pad: base cross, then one highlight arm per direction drawn on top.
        let c = layout.dpadCenter, r = layout.dpadRadius * 0.94, w = layout.dpadRadius * 0.68
        let cross = Self.crossPath(center: c, radius: r, armWidth: w)
        let base = Self.shape(cross, fill: neutral, stroke: stroke)
        base.lineJoin = .round
        addSublayer(base)
        let half = w / 2
        let arms: [(SNESButtons, CGRect)] = [
            (.up, CGRect(x: c.x - half, y: c.y - r, width: w, height: r - half)),
            (.down, CGRect(x: c.x - half, y: c.y + half, width: w, height: r - half)),
            (.left, CGRect(x: c.x - r, y: c.y - half, width: r - half, height: w)),
            (.right, CGRect(x: c.x + half, y: c.y - half, width: r - half, height: w)),
        ]
        for (button, rect) in arms {
            let arm = Self.shape(UIBezierPath(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5),
                                              cornerRadius: w * 0.12), fill: .clear, stroke: nil)
            addSublayer(arm)
            let arrow = Self.shape(Self.arrowPath(in: rect, pointing: button, size: w * 0.32),
                                   fill: labelColor, stroke: nil)
            addSublayer(arrow)
            parts.append(Part(shape: arm, label: nil, buttons: button, fill: UIColor.clear.cgColor,
                              pressedFill: neutralPressed.cgColor, labelColor: labelColor.cgColor,
                              pressedLabelColor: labelPressed.cgColor, isMenu: false))
        }

        // Face buttons: tinted fill, colored ring, label in a lighter shade of the button color.
        let fontSize = max(13, layout.faceRadius * 0.85)
        for (button, center) in layout.faceButtons {
            let color = layout.system == .nes ? Self.nesFaceColor : Self.faceColors[button.rawValue] ?? .white
            let rect = CGRect(x: center.x - layout.faceRadius, y: center.y - layout.faceRadius,
                              width: layout.faceRadius * 2, height: layout.faceRadius * 2)
            let fill = color.withAlphaComponent(panel ? 0.22 : 0.20)
            let pressed = color.withAlphaComponent(panel ? 0.80 : 0.62)
            let shape = Self.shape(UIBezierPath(ovalIn: rect), fill: fill,
                                   stroke: color.withAlphaComponent(panel ? 0.75 : 0.55))
            shape.lineWidth = 2
            addSublayer(shape)
            let label = Self.text(Self.faceLabels[button.rawValue] ?? "", in: rect, size: fontSize,
                                  color: Self.lighten(color), scale: scale)
            addSublayer(label)
            parts.append(Part(shape: shape, label: label, buttons: button, fill: fill.cgColor,
                              pressedFill: pressed.cgColor, labelColor: Self.lighten(color).cgColor,
                              pressedLabelColor: labelPressed.cgColor, isMenu: false))
        }

        // Shoulders, Select, Start: rounded neutral buttons with text labels.
        let small: [(SNESButtons, CGRect, String, CGFloat)] = [
            (.l, layout.lRect, "L", panel ? 17 : 15),
            (.r, layout.rRect, "R", panel ? 17 : 15),
            (.select, layout.selectRect, "SELECT", 10),
            (.start, layout.startRect, "START", 10),
        ]
        for (button, rect, title, size) in small where !rect.isNull {
            let radius = button == .l || button == .r ? min(rect.height / 2, 14) : rect.height / 2
            let shape = Self.shape(UIBezierPath(roundedRect: rect, cornerRadius: radius),
                                   fill: neutral, stroke: stroke)
            addSublayer(shape)
            let label = Self.text(title, in: rect, size: size, color: labelColor, scale: scale)
            addSublayer(label)
            parts.append(Part(shape: shape, label: label, buttons: button, fill: neutral.cgColor,
                              pressedFill: neutralPressed.cgColor, labelColor: labelColor.cgColor,
                              pressedLabelColor: labelPressed.cgColor, isMenu: false))
        }

        // Menu: small circle with a three-line glyph.
        let m = layout.menuRect
        let menu = Self.shape(UIBezierPath(ovalIn: m), fill: neutral, stroke: stroke)
        addSublayer(menu)
        let glyph = UIBezierPath()
        for i in -1...1 {
            let y = m.midY + CGFloat(i) * m.height * 0.16
            glyph.move(to: CGPoint(x: m.midX - m.width * 0.22, y: y))
            glyph.addLine(to: CGPoint(x: m.midX + m.width * 0.22, y: y))
        }
        let glyphLayer = Self.shape(glyph, fill: .clear, stroke: labelColor)
        glyphLayer.lineWidth = 2
        glyphLayer.lineCap = .round
        addSublayer(glyphLayer)
        parts.append(Part(shape: menu, label: nil, buttons: [], fill: neutral.cgColor,
                          pressedFill: neutralPressed.cgColor, labelColor: labelColor.cgColor,
                          pressedLabelColor: labelPressed.cgColor, isMenu: true))
    }

    /// Applies pressed colors. Call inside a CATransaction with actions disabled.
    func show(pressed: SNESButtons, menu: Bool) {
        for part in parts {
            let on = part.isMenu ? menu : pressed.isSuperset(of: part.buttons)
            part.shape.fillColor = on ? part.pressedFill : part.fill
            part.label?.foregroundColor = on ? part.pressedLabelColor : part.labelColor
        }
    }

    // MARK: Builders

    private static func shape(_ path: UIBezierPath, fill: UIColor, stroke: UIColor?) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.path = path.cgPath
        layer.fillColor = fill.cgColor
        layer.strokeColor = stroke?.cgColor
        layer.lineWidth = stroke == nil ? 0 : 1.5
        return layer
    }

    private static func text(_ string: String, in rect: CGRect, size: CGFloat, color: UIColor,
                             scale: CGFloat) -> CATextLayer {
        let font = UIFont.systemFont(ofSize: size, weight: .bold)
        let layer = CATextLayer()
        layer.string = string
        layer.font = font
        layer.fontSize = size
        layer.alignmentMode = .center
        layer.foregroundColor = color.cgColor
        layer.contentsScale = scale
        // CATextLayer draws from the top; center the line box vertically in `rect`.
        let lineHeight = font.lineHeight
        layer.frame = CGRect(x: rect.minX, y: rect.midY - lineHeight / 2,
                             width: rect.width, height: lineHeight)
        return layer
    }

    /// Plus-shaped outline (single contour, so the stroke has no inner seams).
    private static func crossPath(center c: CGPoint, radius r: CGFloat, armWidth w: CGFloat) -> UIBezierPath {
        let h = w / 2
        let points = [
            CGPoint(x: c.x - h, y: c.y - r), CGPoint(x: c.x + h, y: c.y - r),
            CGPoint(x: c.x + h, y: c.y - h), CGPoint(x: c.x + r, y: c.y - h),
            CGPoint(x: c.x + r, y: c.y + h), CGPoint(x: c.x + h, y: c.y + h),
            CGPoint(x: c.x + h, y: c.y + r), CGPoint(x: c.x - h, y: c.y + r),
            CGPoint(x: c.x - h, y: c.y + h), CGPoint(x: c.x - r, y: c.y + h),
            CGPoint(x: c.x - r, y: c.y - h), CGPoint(x: c.x - h, y: c.y - h),
        ]
        let path = UIBezierPath()
        path.move(to: points[0])
        points.dropFirst().forEach { path.addLine(to: $0) }
        path.close()
        return path
    }

    /// Small triangle near the outer end of a d-pad arm.
    private static func arrowPath(in arm: CGRect, pointing dir: SNESButtons, size s: CGFloat) -> UIBezierPath {
        let path = UIBezierPath()
        let hs = s / 2
        switch dir {
        case .up:
            let tip = CGPoint(x: arm.midX, y: arm.minY + arm.height * 0.3)
            path.move(to: tip)
            path.addLine(to: CGPoint(x: tip.x + hs, y: tip.y + hs * 1.1))
            path.addLine(to: CGPoint(x: tip.x - hs, y: tip.y + hs * 1.1))
        case .down:
            let tip = CGPoint(x: arm.midX, y: arm.maxY - arm.height * 0.3)
            path.move(to: tip)
            path.addLine(to: CGPoint(x: tip.x + hs, y: tip.y - hs * 1.1))
            path.addLine(to: CGPoint(x: tip.x - hs, y: tip.y - hs * 1.1))
        case .left:
            let tip = CGPoint(x: arm.minX + arm.width * 0.3, y: arm.midY)
            path.move(to: tip)
            path.addLine(to: CGPoint(x: tip.x + hs * 1.1, y: tip.y - hs))
            path.addLine(to: CGPoint(x: tip.x + hs * 1.1, y: tip.y + hs))
        default:
            let tip = CGPoint(x: arm.maxX - arm.width * 0.3, y: arm.midY)
            path.move(to: tip)
            path.addLine(to: CGPoint(x: tip.x - hs * 1.1, y: tip.y - hs))
            path.addLine(to: CGPoint(x: tip.x - hs * 1.1, y: tip.y + hs))
        }
        path.close()
        return path
    }

    private static func lighten(_ color: UIColor) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return UIColor(red: r + (1 - r) * 0.35, green: g + (1 - g) * 0.35, blue: b + (1 - b) * 0.35, alpha: 1)
    }
}
