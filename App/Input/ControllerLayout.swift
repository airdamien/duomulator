import UIKit

// MARK: - Touch ownership

/// What a finger on the touch controller is attached to. Decided when the finger lands (see
/// `ControllerLayout.control(at:)`) and kept while it slides, so a thumb that starts on the
/// d-pad keeps steering even after drifting off it.
enum TouchControl: Equatable, Sendable {
    /// Steers the d-pad by angle from its center until lifted.
    case dpad
    /// Re-hit-tested on every move against face, shoulder, Start and Select buttons, so
    /// sliding from B to A (or resting between two face buttons) behaves like a real pad.
    case buttons
    /// The small menu button; fires on lift if the finger is still on it.
    case menu
    /// A DualShock analog stick (0 = left, 1 = right), tilted by the finger's offset from its
    /// center until lifted.
    case stick(Int)
}

// MARK: - Geometry

/// Pure geometry for the on-screen controller: where every control sits for a given size and
/// style, and which buttons a point presses. NES and Genesis layouts drop L/R and use two or
/// three face buttons. No UIKit state, so it is unit-testable and
/// shared by drawing and hit-testing (what you see is exactly what you can press).
struct ControllerLayout: Equatable, Sendable {
    enum Style: Equatable, Sendable { case overlay, panel }

    let style: Style
    let system: GameSystem
    /// Which pad to draw; usually `system.padStyle`, but Sega games choose 3 or 6 buttons.
    let pad: GameSystem.PadStyle
    /// Kept clear of controls (the DS touch screen); `.null` when there is none.
    let reserved: CGRect
    /// Center and outer radius of the d-pad cross.
    private(set) var dpadCenter: CGPoint
    private(set) var dpadRadius: CGFloat
    /// Center of the face-button cluster, center-to-button distance, and each button's radius.
    private(set) var faceCenter: CGPoint
    private(set) var faceSpacing: CGFloat
    private(set) var faceRadius: CGFloat
    private(set) var lRect: CGRect
    private(set) var rRect: CGRect
    private(set) var selectRect: CGRect
    /// N64 Z trigger, beside L (`.null` on other pads).
    private(set) var zRect: CGRect
    private(set) var startRect: CGRect
    private(set) var menuRect: CGRect
    /// PlayStation analog sticks (radius 0 = none): lower center, between the clusters.
    private(set) var stickRadius: CGFloat
    private(set) var leftStickCenter: CGPoint
    private(set) var rightStickCenter: CGPoint

    // MARK: Tuning

    /// Fraction of `dpadRadius` around the center where no direction is pressed.
    static let dpadDeadZone: CGFloat = 0.2
    /// A finger landing within this multiple of `dpadRadius` grabs the d-pad.
    static let dpadGrabScale: CGFloat = 1.25
    /// A face button is pressed while the finger is within this multiple of `faceSpacing` of
    /// its center. 0.85 makes the gap between two adjacent buttons press both (B+Y, B+A, …)
    /// while opposite buttons (B/X, Y/A) can never be pressed by one finger.
    static let faceHitScale: CGFloat = 0.85
    /// Extra touch slop around rectangular buttons, in points.
    static let shoulderSlop: CGFloat = 14
    static let smallButtonSlop = CGSize(width: 8, height: 12)
    static let menuSlop: CGFloat = 10

    // MARK: Layout

    /// Lays out controls inside `bounds` minus `safeArea`. Control sizes scale with the
    /// available space, clamped so they stay thumb-sized on both small and large areas.
    /// `reserved` (in the same coordinates as `bounds`) is kept clear of controls: the DS
    /// touch screen sits there, and the controls flank it the way they do on the handheld.
    init(bounds: CGRect, safeArea: UIEdgeInsets = .zero, style: Style, system: GameSystem = .snes,
         pad: GameSystem.PadStyle? = nil, reserved: CGRect? = nil) {
        let pad = pad ?? system.padStyle
        self.pad = pad
        self.style = style
        self.system = system
        self.reserved = reserved ?? .null
        let isPanel = style == .panel
        let margin: CGFloat = isPanel ? 14 : 10
        let area = bounds.inset(by: safeArea).insetBy(dx: margin, dy: margin)
        let gap: CGFloat = 12

        guard area.width > 60, area.height > 60 else {
            // Too small to host a controller; everything collapses and nothing hit-tests.
            let c = CGPoint(x: bounds.midX, y: bounds.midY)
            dpadCenter = c; dpadRadius = 0
            faceCenter = c; faceSpacing = 0; faceRadius = 0
            lRect = .null; rRect = .null; selectRect = .null; startRect = .null; menuRect = .null
            zRect = .null
            stickRadius = 0; leftStickCenter = c; rightStickCenter = c
            return
        }

        let shoulderH: CGFloat = isPanel ? 44 : 34
        let shoulderW = isPanel ? Self.clamp(area.width * 0.34, 90, 200)
                                : Self.clamp(area.width * 0.22, 64, 120)
        let menuSize: CGFloat = isPanel ? 34 : 30
        let ssW: CGFloat = isPanel ? 66 : 58
        let ssH: CGFloat = isPanel ? 28 : 24
        let ssGap: CGFloat = 20
        let topReserved = shoulderH + gap

        if let reserved, !reserved.isNull, !reserved.isEmpty {
            // Flanking layout: d-pad (with L and Select) left of the reserved rect, face
            // buttons (with R and Start) right of it. No menu button; the quick bar has one.
            let left = CGRect(x: area.minX, y: area.minY,
                              width: max(0, reserved.minX - gap - area.minX), height: area.height)
            let right = CGRect(x: reserved.maxX + gap, y: area.minY,
                               width: max(0, area.maxX - reserved.maxX - gap), height: area.height)
            let gutter = min(left.width, right.width)
            let usable = area.height - topReserved - (ssH + gap)
            let cluster = min(gutter, usable, isPanel ? 210 : 190)
            guard cluster >= 60 else {
                let c = CGPoint(x: bounds.midX, y: bounds.midY)
                dpadCenter = c; dpadRadius = 0
                faceCenter = c; faceSpacing = 0; faceRadius = 0
                lRect = .null; rRect = .null; selectRect = .null; startRect = .null; menuRect = .null
                zRect = .null
                stickRadius = 0; leftStickCenter = c; rightStickCenter = c
                return
            }
            let clusterY = area.minY + topReserved + usable / 2
            dpadCenter = CGPoint(x: left.midX, y: clusterY)
            dpadRadius = cluster / 2
            faceCenter = CGPoint(x: right.midX, y: clusterY)
            faceSpacing = cluster * Self.faceSpacingScale(pad)
            faceRadius = cluster * Self.faceRadiusScale(pad)
            lRect = pad.isDiamond
                ? CGRect(x: left.minX, y: area.minY, width: left.width, height: shoulderH) : .null
            rRect = pad.isDiamond
                ? CGRect(x: right.minX, y: area.minY, width: right.width, height: shoulderH) : .null
            let w = min(ssW, gutter)
            selectRect = pad.isGenesis
                ? .null : CGRect(x: left.midX - w / 2, y: area.maxY - ssH, width: w, height: ssH)
            startRect = CGRect(x: right.midX - w / 2, y: area.maxY - ssH, width: w, height: ssH)
            menuRect = .null
            zRect = .null
            stickRadius = 0; leftStickCenter = .zero; rightStickCenter = .zero
            return
        }

        // Cluster size S: the d-pad's diameter and the face diamond's outer extent.
        var size = isPanel ? Self.clamp(min(area.width * 0.44, area.height * 0.7), 140, 210)
                           : Self.clamp(min(area.width * 0.40, area.height * 0.62), 120, 190)
        size = min(size, (area.width - gap) / 2)
        var ssBetween = area.width - 2 * size - 2 * gap >= 2 * ssW + ssGap
        let needed = topReserved + size + (ssBetween ? 0 : gap + ssH)
        if needed > area.height {
            size = max(60, size - (needed - area.height))
            ssBetween = area.width - 2 * size - 2 * gap >= 2 * ssW + ssGap
        }

        // PlayStation: leave the middle for two analog sticks side by side.
        let wantsSticks = pad == .playstation
        let stickR: CGFloat = wantsSticks ? Self.clamp(area.width * 0.075, 30, 50) : 0
        // Room for thumbs: a clear gap between the two sticks, and between each stick and
        // the cluster beside it.
        let stickGap = max(24, stickR * 0.9), clusterGap: CGFloat = 16
        if wantsSticks {
            size = max(60, min(size, (area.width - 4 * stickR - stickGap - 2 * clusterGap) / 2))
        }
        // N64: d-pad left, analog stick in the middle (the pad's centre prong), buttons right.
        let n64StickR: CGFloat = pad == .n64 ? Self.clamp(area.width * 0.11, 36, 70) : 0
        if pad == .n64 {
            size = max(60, min(size, (area.width - 2 * n64StickR - 2 * clusterGap) / 2))
        }

        // Vertical placement: overlay hugs the bottom edge; the panel centers the clusters in
        // the space below the shoulder bar.
        let bottom = ssBetween ? area.maxY : area.maxY - ssH - gap
        let clusterY: CGFloat
        if isPanel {
            clusterY = max((area.minY + topReserved + bottom) / 2, area.minY + topReserved + size / 2)
        } else {
            clusterY = bottom - size / 2
        }

        dpadCenter = CGPoint(x: area.minX + size / 2, y: clusterY)
        dpadRadius = pad == .n64 ? size * 0.42 : size / 2
        faceCenter = CGPoint(x: area.maxX - size / 2, y: clusterY)
        faceSpacing = size * Self.faceSpacingScale(pad)
        faceRadius = size * Self.faceRadiusScale(pad)

        if pad.isDiamond {
            lRect = CGRect(x: area.minX, y: area.minY, width: shoulderW, height: shoulderH)
            rRect = CGRect(x: area.maxX - shoulderW, y: area.minY, width: shoulderW, height: shoulderH)
            zRect = .null
        } else if pad == .n64 {
            // L and Z side by side on the left, with a thumb's gap between them and clear of
            // the menu button; R on the right.
            let lzGap: CGFloat = 16
            let room = area.midX - menuSize / 2 - 12 - area.minX
            let each = max(44, min(shoulderW * 0.62, (room - lzGap) / 2))
            lRect = CGRect(x: area.minX, y: area.minY, width: each, height: shoulderH)
            zRect = CGRect(x: area.minX + each + lzGap, y: area.minY, width: each, height: shoulderH)
            rRect = CGRect(x: area.maxX - shoulderW, y: area.minY, width: shoulderW, height: shoulderH)
        } else {
            lRect = .null
            rRect = .null
            zRect = .null
        }
        menuRect = CGRect(x: area.midX - menuSize / 2, y: area.minY + (shoulderH - menuSize) / 2,
                          width: menuSize, height: menuSize)

        var ssY: CGFloat
        if !ssBetween {
            ssY = area.maxY - ssH
        } else if isPanel {
            ssY = clusterY + size * 0.25 - ssH / 2
        } else {
            ssY = area.maxY - ssH
        }

        if pad == .n64 {
            // One analog stick in the middle, low, with Start above it.
            let y = min(clusterY + size / 2 - n64StickR, area.maxY - n64StickR)
            stickRadius = n64StickR
            leftStickCenter = CGPoint(x: area.midX, y: y)
            rightStickCenter = .zero
            // Start just below the menu button.
            ssY = menuRect.maxY + 8
        } else if wantsSticks {
            // Sticks as low as the area allows, with a thumb's clearance up to Select/Start.
            let y = area.maxY - stickR
            stickRadius = stickR
            leftStickCenter = CGPoint(x: area.midX - stickR - stickGap / 2, y: y)
            rightStickCenter = CGPoint(x: area.midX + stickR + stickGap / 2, y: y)
            ssY = max(area.minY + topReserved, y - stickR - max(24, stickR * 0.6) - ssH)
        } else {
            stickRadius = 0
            leftStickCenter = .zero
            rightStickCenter = .zero
        }

        if pad.isGenesis || pad == .n64 {
            // Start only, centered.
            selectRect = .null
            startRect = CGRect(x: area.midX - ssW / 2, y: ssY, width: ssW, height: ssH)
        } else {
            selectRect = CGRect(x: area.midX - ssGap / 2 - ssW, y: ssY, width: ssW, height: ssH)
            startRect = CGRect(x: area.midX + ssGap / 2, y: ssY, width: ssW, height: ssH)
        }
    }

    /// Radii of the rounded screen corners at each corner of the layout's bounds (0 where a
    /// bounds corner isn't a screen corner).
    struct ScreenCorners: Equatable, Sendable {
        var topLeft: CGFloat = 0, topRight: CGFloat = 0, bottomLeft: CGFloat = 0, bottomRight: CGFloat = 0
    }

    /// Slides controls that poke into a rounded screen corner sideways until they're fully on
    /// screen (the R shoulder in the top-right corner of a landscape overlay, say).
    mutating func keepClear(of corners: ScreenCorners, in bounds: CGRect) {
        guard corners != ScreenCorners() else { return }
        // Signed horizontal shift that brings a circle at `center` inside the corner's curve,
        // with a little clearance for the outline stroke.
        func shift(_ center: CGPoint, radius: CGFloat) -> CGFloat {
            let r = radius + 4
            let left = center.x < bounds.midX, top = center.y < bounds.midY
            let big = left ? (top ? corners.topLeft : corners.bottomLeft)
                           : (top ? corners.topRight : corners.bottomRight)
            let u = left ? center.x - bounds.minX : bounds.maxX - center.x
            let v = top ? center.y - bounds.minY : bounds.maxY - center.y
            let dv = big - v
            // Inside the curve: (R - u)^2 + (R - v)^2 <= (R - r)^2.
            guard big > r, dv > 0, big - r > dv else { return 0 }
            let s = max(0, big - ((big - r) * (big - r) - dv * dv).squareRoot() - u)
            return left ? s : -s
        }
        // A rounded rect: check the circle that rounds its corner nearest the screen corner.
        func shift(_ rect: CGRect, cornerRadius k: CGFloat) -> CGFloat {
            guard !rect.isNull, !rect.isEmpty else { return 0 }
            let left = rect.midX < bounds.midX, top = rect.midY < bounds.midY
            return shift(CGPoint(x: left ? rect.minX + k : rect.maxX - k,
                                 y: top ? rect.minY + k : rect.maxY - k), radius: k)
        }
        let shoulderRadius = { (r: CGRect) in min(r.height / 2, 14) }

        let ls = shift(lRect, cornerRadius: shoulderRadius(lRect))
        lRect = lRect.offsetBy(dx: ls, dy: 0)
        zRect = zRect.offsetBy(dx: ls, dy: 0)   // Z sits beside L and moves with it
        rRect = rRect.offsetBy(dx: shift(rRect, cornerRadius: shoulderRadius(rRect)), dy: 0)
        menuRect = menuRect.offsetBy(dx: shift(menuRect, cornerRadius: menuRect.height / 2), dy: 0)
        selectRect = selectRect.offsetBy(dx: shift(selectRect, cornerRadius: selectRect.height / 2), dy: 0)
        startRect = startRect.offsetBy(dx: shift(startRect, cornerRadius: startRect.height / 2), dy: 0)
        if dpadRadius > 0 { dpadCenter.x += shift(dpadCenter, radius: dpadRadius) }
        let face = faceButtons.map { shift($0.center, radius: radius(for: $0.button)) }
        if let most = face.max(by: { abs($0) < abs($1) }) { faceCenter.x += most }
        if stickRadius > 0 {
            leftStickCenter.x += shift(leftStickCenter, radius: stickRadius)
            if stickCount > 1 { rightStickCenter.x += shift(rightStickCenter, radius: stickRadius) }
        }
    }

    /// Face buttons. SNES: the diamond, X top, A right, B bottom, Y left. NES: B lower-left
    /// and A upper-right on a diagonal like the original pad; the gap between them is within
    /// both hit radii, so a thumb there presses B+A (run + jump).
    var faceButtons: [(button: SNESButtons, center: CGPoint)] {
        let c = faceCenter, d = faceSpacing
        // Genesis rows rise to the right like the real pad. PicoDrive reads A/B/C from
        // libretro Y/B/A and X/Y/Z from L/X/R.
        func row(_ buttons: [SNESButtons], y: CGFloat) -> [(button: SNESButtons, center: CGPoint)] {
            buttons.enumerated().map { i, button in
                let k = CGFloat(i - 1)
                return (button, CGPoint(x: c.x + k * d, y: y - k * d * 0.2))
            }
        }
        switch pad {
        case .genesis3:
            return row([.y, .b, .a], y: c.y)
        case .genesis6:
            return row([.l, .x, .r], y: c.y - d * 0.56) + row([.y, .b, .a], y: c.y + d * 0.56)
        case .n64:
            // A (big, lower left), B (above-left of it) and the C buttons in a diamond to the
            // upper right, as on the N64 pad. d is the cluster size here.
            let cc = CGPoint(x: c.x + d * 0.22, y: c.y - d * 0.12)
            let k = d * 0.165
            return [
                (.b, CGPoint(x: c.x - d * 0.2, y: c.y + d * 0.22)),
                (.y, CGPoint(x: c.x - d * 0.34, y: c.y - d * 0.1)),
                (.cUp, CGPoint(x: cc.x, y: cc.y - k)),
                (.cDown, CGPoint(x: cc.x, y: cc.y + k)),
                (.cLeft, CGPoint(x: cc.x - k, y: cc.y)),
                (.cRight, CGPoint(x: cc.x + k, y: cc.y)),
            ]
        case .nes:
            return [
                (.b, CGPoint(x: c.x - d * 0.75, y: c.y + d * 0.3)),
                (.a, CGPoint(x: c.x + d * 0.75, y: c.y - d * 0.3)),
            ]
        case .snes, .playstation:
            return [
                (.x, CGPoint(x: c.x, y: c.y - d)),
                (.a, CGPoint(x: c.x + d, y: c.y)),
                (.b, CGPoint(x: c.x, y: c.y + d)),
                (.y, CGPoint(x: c.x - d, y: c.y)),
            ]
        }
    }

    /// Center-to-center button distance as a fraction of the cluster size.
    private static func faceSpacingScale(_ pad: GameSystem.PadStyle) -> CGFloat {
        switch pad {
        case .n64: 1.0   // faceSpacing is the cluster size; positions scale from it
        case .snes, .nes, .playstation: 0.32
        case .genesis3: 0.355
        case .genesis6: 0.34
        }
    }

    /// Face-button radius as a fraction of the cluster size: fewer buttons can be bigger.
    /// Genesis buttons sit in rows, so they're kept small enough to leave a visible gap.
    private static func faceRadiusScale(_ pad: GameSystem.PadStyle) -> CGFloat {
        switch pad {
        case .n64: 0.15
        case .snes, .playstation: 0.18
        case .nes: 0.21
        case .genesis3: 0.135
        case .genesis6: 0.125
        }
    }

    /// A face button is pressed within this distance of its center.
    var faceHitRadius: CGFloat { Self.faceHitRadius(pad: pad, spacing: faceSpacing) }

    /// Drawn radius of one face button: all the same, except the N64's big A, smaller B and
    /// small C buttons.
    func radius(for button: SNESButtons) -> CGFloat {
        guard pad == .n64 else { return faceRadius }
        switch button {
        case .b: return faceRadius
        case .y: return faceRadius * 0.85
        default: return faceRadius * 0.6
        }
    }

    /// SNES/NES: 0.85 x spacing, so the gap between two adjacent buttons presses both while
    /// opposite buttons never can. Genesis rows are tighter: 0.6 x the neighbor distance
    /// only overlaps in a thin band halfway between two buttons.
    private static func faceHitRadius(pad: GameSystem.PadStyle, spacing: CGFloat) -> CGFloat {
        pad.isGenesis ? spacing * 1.02 * 0.6 : spacing * faceHitScale
    }

    /// Text printed on a face button, as on that console's pad.
    func label(for button: SNESButtons) -> String {
        // The N64's yellow buttons just show their arrow (the mapping screen says "C▲").
        if pad == .n64 {
            switch button {
            case .cUp: return "▲"
            case .cDown: return "▼"
            case .cLeft: return "◀"
            case .cRight: return "▶"
            default: break
            }
        }
        return ButtonLabels.label(button, pad: pad, system: system)
    }

    // MARK: Hit-testing

    /// The control a finger landing at `point` attaches to, or nil for empty space.
    func control(at point: CGPoint) -> TouchControl? {
        // Touch slop never reaches into the reserved area: those touches belong to the screen.
        if reserved.contains(point) { return nil }
        if isOnMenu(point) { return .menu }
        if stickRadius > 0 {
            for (i, center) in [leftStickCenter, rightStickCenter].prefix(stickCount).enumerated()
            where Self.distance(point, center) <= stickRadius * 1.25 {
                return .stick(i)
            }
        }
        if dpadRadius > 0, Self.distance(point, dpadCenter) <= dpadRadius * Self.dpadGrabScale {
            return .dpad
        }
        if faceRadius > 0 {
            // Grab radius: the farthest button's far edge plus a little slop.
            let reach = faceButtons.map { Self.distance($0.center, faceCenter) }.max() ?? 0
            if Self.distance(point, faceCenter) <= reach + faceRadius * 1.4 { return .buttons }
        }
        if !buttonsOutsideFace(at: point).isEmpty { return .buttons }
        return nil
    }

    /// Buttons pressed by a finger at `point` that is attached to `control`.
    func buttons(at point: CGPoint, for control: TouchControl) -> SNESButtons {
        switch control {
        case .dpad: return dpadDirection(at: point)
        case .buttons: return faceButtons(at: point).union(buttonsOutsideFace(at: point))
        case .menu, .stick: return []
        }
    }

    /// Number of on-screen analog sticks: two on the DualShock, one on the N64 pad.
    var stickCount: Int {
        guard stickRadius > 0 else { return 0 }
        return pad == .n64 ? 1 : 2
    }

    /// Analog value of stick `index` for a finger at `point`: offset from the stick's center
    /// over its radius, clamped to the unit circle, in libretro units (-0x7FFF...0x7FFF,
    /// +y down). A small dead zone keeps a resting thumb at zero.
    func stickValue(_ index: Int, at point: CGPoint) -> (x: Int16, y: Int16) {
        guard stickRadius > 0 else { return (0, 0) }
        let center = index == 0 ? leftStickCenter : rightStickCenter
        var dx = (point.x - center.x) / stickRadius, dy = (point.y - center.y) / stickRadius
        let length = hypot(dx, dy)
        if length < 0.12 { return (0, 0) }
        if length > 1 { dx /= length; dy /= length }
        return (Int16((dx * 32767).rounded()), Int16((dy * 32767).rounded()))
    }

    /// 8-way direction from the d-pad center: eight equal 45° sectors, nothing inside the
    /// dead zone. Works at any distance so a finger that slides off the cross keeps steering.
    func dpadDirection(at point: CGPoint) -> SNESButtons {
        let dx = point.x - dpadCenter.x
        let dy = dpadCenter.y - point.y   // up is positive
        guard dpadRadius > 0, hypot(dx, dy) >= dpadRadius * Self.dpadDeadZone else { return [] }
        var degrees = atan2(dy, dx) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        let sector = Int((degrees + 22.5) / 45) % 8
        let directions: [SNESButtons] = [
            .right, [.up, .right], .up, [.up, .left],
            .left, [.down, .left], .down, [.down, .right],
        ]
        return directions[sector]
    }

    /// Face buttons whose centers are within the hit radius; up to two adjacent ones at once.
    func faceButtons(at point: CGPoint) -> SNESButtons {
        guard faceRadius > 0 else { return [] }
        let hit = faceHitRadius
        var result: SNESButtons = []
        for (button, center) in faceButtons
        where Self.distance(point, center) <= (pad == .n64 ? radius(for: button) * 1.2 : hit) {
            result.insert(button)
        }
        return result
    }

    /// Whether `point` is on the menu button (including slop).
    func isOnMenu(_ point: CGPoint) -> Bool {
        menuRect.insetBy(dx: -Self.menuSlop, dy: -Self.menuSlop).contains(point)
    }

    private func buttonsOutsideFace(at point: CGPoint) -> SNESButtons {
        var result: SNESButtons = []
        let s = Self.shoulderSlop, b = Self.smallButtonSlop
        if lRect.insetBy(dx: -s, dy: -s).contains(point) { result.insert(.l) }
        if zRect.insetBy(dx: -s / 2, dy: -s).contains(point) { result.insert(.l2) }
        if rRect.insetBy(dx: -s, dy: -s).contains(point) { result.insert(.r) }
        if selectRect.insetBy(dx: -b.width, dy: -b.height).contains(point) { result.insert(.select) }
        if startRect.insetBy(dx: -b.width, dy: -b.height).contains(point) { result.insert(.start) }
        return result
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
    private static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(max(v, lo), hi) }

}

// MARK: - Settings

/// User-facing input preferences, persisted in UserDefaults so the library's settings screen
/// can toggle them without touching the input module.
enum InputSettings {
    static let hapticsEnabledKey = "hapticsEnabled"

    /// Haptic tick on every new on-screen button press. Defaults to on.
    static var hapticsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: hapticsEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: hapticsEnabledKey) }
    }
}
