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
    /// Kept clear of controls (the DS touch screen); `.null` when there is none.
    let reserved: CGRect
    /// Center and outer radius of the d-pad cross.
    let dpadCenter: CGPoint
    let dpadRadius: CGFloat
    /// Center of the face-button cluster, center-to-button distance, and each button's radius.
    let faceCenter: CGPoint
    let faceSpacing: CGFloat
    let faceRadius: CGFloat
    let lRect: CGRect
    let rRect: CGRect
    let selectRect: CGRect
    let startRect: CGRect
    let menuRect: CGRect

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
         reserved: CGRect? = nil) {
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
                return
            }
            let clusterY = area.minY + topReserved + usable / 2
            dpadCenter = CGPoint(x: left.midX, y: clusterY)
            dpadRadius = cluster / 2
            faceCenter = CGPoint(x: right.midX, y: clusterY)
            faceSpacing = cluster * 0.32
            faceRadius = cluster * Self.faceRadiusScale(system)
            lRect = system.hasShoulderButtons
                ? CGRect(x: left.minX, y: area.minY, width: left.width, height: shoulderH) : .null
            rRect = system.hasShoulderButtons
                ? CGRect(x: right.minX, y: area.minY, width: right.width, height: shoulderH) : .null
            let w = min(ssW, gutter)
            selectRect = system.padStyle == .genesis
                ? .null : CGRect(x: left.midX - w / 2, y: area.maxY - ssH, width: w, height: ssH)
            startRect = CGRect(x: right.midX - w / 2, y: area.maxY - ssH, width: w, height: ssH)
            menuRect = .null
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
        dpadRadius = size / 2
        faceCenter = CGPoint(x: area.maxX - size / 2, y: clusterY)
        faceSpacing = size * 0.32
        // NES: two buttons, so each can be bigger.
        faceRadius = size * Self.faceRadiusScale(system)

        if system.hasShoulderButtons {
            lRect = CGRect(x: area.minX, y: area.minY, width: shoulderW, height: shoulderH)
            rRect = CGRect(x: area.maxX - shoulderW, y: area.minY, width: shoulderW, height: shoulderH)
        } else {
            lRect = .null
            rRect = .null
        }
        menuRect = CGRect(x: area.midX - menuSize / 2, y: area.minY + (shoulderH - menuSize) / 2,
                          width: menuSize, height: menuSize)

        let ssY: CGFloat
        if !ssBetween {
            ssY = area.maxY - ssH
        } else if isPanel {
            ssY = clusterY + size * 0.25 - ssH / 2
        } else {
            ssY = area.maxY - ssH
        }
        if system.padStyle == .genesis {
            // Start only, centered.
            selectRect = .null
            startRect = CGRect(x: area.midX - ssW / 2, y: ssY, width: ssW, height: ssH)
        } else {
            selectRect = CGRect(x: area.midX - ssGap / 2 - ssW, y: ssY, width: ssW, height: ssH)
            startRect = CGRect(x: area.midX + ssGap / 2, y: ssY, width: ssW, height: ssH)
        }
    }

    /// Face buttons. SNES: the diamond, X top, A right, B bottom, Y left. NES: B lower-left
    /// and A upper-right on a diagonal like the original pad; the gap between them is within
    /// both hit radii, so a thumb there presses B+A (run + jump).
    var faceButtons: [(button: SNESButtons, center: CGPoint)] {
        let c = faceCenter, d = faceSpacing
        if system.padStyle == .genesis {
            // A B C left to right, rising slightly like the 3-button pad. PicoDrive reads the
            // Genesis A/B/C from libretro's Y/B/A.
            return [
                (.y, CGPoint(x: c.x - d, y: c.y + d * 0.3)),
                (.b, CGPoint(x: c.x, y: c.y)),
                (.a, CGPoint(x: c.x + d, y: c.y - d * 0.3)),
            ]
        }
        if system.padStyle == .nes {
            return [
                (.b, CGPoint(x: c.x - d * 0.75, y: c.y + d * 0.3)),
                (.a, CGPoint(x: c.x + d * 0.75, y: c.y - d * 0.3)),
            ]
        }
        return [
            (.x, CGPoint(x: c.x, y: c.y - d)),
            (.a, CGPoint(x: c.x + d, y: c.y)),
            (.b, CGPoint(x: c.x, y: c.y + d)),
            (.y, CGPoint(x: c.x - d, y: c.y)),
        ]
    }

    /// Face-button radius as a fraction of the cluster size: fewer buttons can be bigger.
    private static func faceRadiusScale(_ system: GameSystem) -> CGFloat {
        switch system.padStyle {
        case .snes: 0.18
        case .nes: 0.21
        case .genesis: 0.17
        }
    }

    /// Text printed on a face button, as on that console's pad.
    func label(for button: SNESButtons) -> String {
        if system.padStyle == .genesis {
            switch button {
            case .y: return "A"
            case .b: return "B"
            case .a: return "C"
            default: return ""
            }
        }
        switch button {
        case .a: return "A"
        case .b: return "B"
        case .x: return "X"
        case .y: return "Y"
        default: return ""
        }
    }

    // MARK: Hit-testing

    /// The control a finger landing at `point` attaches to, or nil for empty space.
    func control(at point: CGPoint) -> TouchControl? {
        // Touch slop never reaches into the reserved area: those touches belong to the screen.
        if reserved.contains(point) { return nil }
        if isOnMenu(point) { return .menu }
        if dpadRadius > 0, Self.distance(point, dpadCenter) <= dpadRadius * Self.dpadGrabScale {
            return .dpad
        }
        if faceRadius > 0,
           Self.distance(point, faceCenter) <= faceSpacing + faceRadius * 1.4 { return .buttons }
        if !buttonsOutsideFace(at: point).isEmpty { return .buttons }
        return nil
    }

    /// Buttons pressed by a finger at `point` that is attached to `control`.
    func buttons(at point: CGPoint, for control: TouchControl) -> SNESButtons {
        switch control {
        case .dpad: return dpadDirection(at: point)
        case .buttons: return faceButtons(at: point).union(buttonsOutsideFace(at: point))
        case .menu: return []
        }
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
        let hit = faceSpacing * Self.faceHitScale
        var result: SNESButtons = []
        for (button, center) in faceButtons where Self.distance(point, center) <= hit {
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
