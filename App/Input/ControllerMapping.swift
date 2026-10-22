import Foundation

/// A physical game-controller button, by position (GameController names them the same way on
/// Xbox, PlayStation and MFi pads). The d-pad and left stick always steer; these can be
/// remapped per system.
enum PhysicalButton: String, CaseIterable, Sendable {
    case south, east, west, north
    case leftShoulder, rightShoulder, leftTrigger, rightTrigger
    case menu, options, leftStick, rightStick

    /// How the button is labelled on common pads: Xbox / PlayStation (position).
    var displayName: String {
        switch self {
        case .south: "A / ✕ (bottom)"
        case .east: "B / ○ (right)"
        case .west: "X / □ (left)"
        case .north: "Y / △ (top)"
        case .leftShoulder: "LB / L1"
        case .rightShoulder: "RB / R1"
        case .leftTrigger: "LT / L2"
        case .rightTrigger: "RT / R2"
        case .menu: "Menu / Options (≡)"
        case .options: "View / Share (⧉)"
        case .leftStick: "Left stick press (L3)"
        case .rightStick: "Right stick press (R3)"
        }
    }
}

/// Which emulated button each physical button presses, for one system. Unchanged buttons
/// use that system's defaults (Nintendo-style positional, as before), and changes are saved
/// per system in UserDefaults ("controllerMapping.<system>").
struct ControllerMapping: Equatable, Sendable {
    let system: GameSystem
    /// Physical button -> emulated button; an empty set means unbound.
    var bindings: [PhysicalButton: SNESButtons]

    // MARK: Defaults

    static func defaults(for system: GameSystem) -> ControllerMapping {
        var b: [PhysicalButton: SNESButtons] = [
            .south: .b, .east: .a, .west: .y, .north: .x,
            .leftShoulder: .l, .rightShoulder: .r, .leftTrigger: .l, .rightTrigger: .r,
            .menu: .start, .options: .select, .leftStick: [], .rightStick: [],
        ]
        switch system.padStyle {
        case .nes:
            // Two buttons: the left/top face buttons double as B/A.
            b[.west] = .b
            b[.north] = .a
            b[.leftShoulder] = []; b[.rightShoulder] = []; b[.leftTrigger] = []; b[.rightTrigger] = []
        case .playstation:
            b[.leftTrigger] = .l2
            b[.rightTrigger] = .r2
            b[.leftStick] = .l3
            b[.rightStick] = .r3
        case .genesis3:
            b[.north] = []
            b[.leftShoulder] = []; b[.rightShoulder] = []; b[.leftTrigger] = []; b[.rightTrigger] = []
        case .n64:
            // Mupen64Plus: A <- libretro B, B <- Y, Z <- L2; the right stick is the C buttons.
            b[.south] = .b; b[.west] = .y; b[.east] = .y; b[.north] = []
            b[.leftTrigger] = .l2; b[.rightTrigger] = .l2
            b[.options] = []
        case .snes, .genesis6:
            break
        }
        return ControllerMapping(system: system, bindings: b)
    }

    /// Emulated buttons this system's pad has, in a sensible display order.
    static func targets(for system: GameSystem, pad: GameSystem.PadStyle? = nil) -> [SNESButtons] {
        switch pad ?? system.padStyle {
        case .nes: [.b, .a, .select, .start]
        case .genesis3: [.y, .b, .a, .start]
        case .genesis6: [.y, .b, .a, .l, .x, .r, .start, .select]
        case .snes: [.b, .a, .y, .x, .l, .r, .select, .start]
        case .playstation: [.b, .a, .y, .x, .l, .r, .l2, .r2, .l3, .r3, .select, .start]
        case .n64: [.b, .y, .l2, .l, .r, .start, .cUp, .cDown, .cLeft, .cRight]
        }
    }

    // MARK: Use

    /// Emulated buttons held for a controller state: directions from the d-pad / left stick,
    /// plus whatever each pressed physical button is bound to.
    /// The pad has analog sticks of its own (PlayStation DualShock): the gamepad's sticks
    /// drive them instead of the d-pad.
    var usesAnalogSticks: Bool { system.padStyle == .playstation || system.padStyle == .n64 }

    func buttons(for s: GamepadSnapshot) -> SNESButtons {
        var m = s.directions(includingStick: !usesAnalogSticks)
        let pressed: [(PhysicalButton, Bool)] = [
            (.south, s.south), (.east, s.east), (.west, s.west), (.north, s.north),
            (.leftShoulder, s.leftShoulder), (.rightShoulder, s.rightShoulder),
            (.leftTrigger, s.leftTrigger), (.rightTrigger, s.rightTrigger),
            (.menu, s.menu), (.options, s.options), (.leftStick, s.leftStick), (.rightStick, s.rightStick),
        ]
        for (button, down) in pressed where down {
            m.formUnion(bindings[button] ?? [])
        }
        return m
    }

    // MARK: Persistence

    private static func key(for system: GameSystem) -> String { "controllerMapping." + system.rawValue }

    static func load(for system: GameSystem, defaults: UserDefaults = .standard) -> ControllerMapping {
        var mapping = Self.defaults(for: system)
        let saved = defaults.dictionary(forKey: key(for: system)) as? [String: String] ?? [:]
        for (physical, target) in saved {
            guard let button = PhysicalButton(rawValue: physical),
                  let buttons = SNESButtons(name: target) else { continue }
            mapping.bindings[button] = buttons
        }
        return mapping
    }

    /// Saves only the bindings that differ from the defaults, so improved defaults still
    /// reach buttons the player never changed.
    func save(defaults: UserDefaults = .standard) {
        let base = Self.defaults(for: system)
        var changed: [String: String] = [:]
        for (button, target) in bindings where base.bindings[button] != target {
            changed[button.rawValue] = target.name
        }
        defaults.set(changed.isEmpty ? nil : changed, forKey: Self.key(for: system))
    }

    static func reset(for system: GameSystem, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(for: system))
    }
}

// MARK: - Names and labels

extension SNESButtons {
    /// Stable storage name for a single button ("none" for no button).
    var name: String {
        switch self {
        case .b: "b"
        case .y: "y"
        case .select: "select"
        case .start: "start"
        case .a: "a"
        case .x: "x"
        case .l: "l"
        case .r: "r"
        case .l2: "l2"
        case .r2: "r2"
        case .l3: "l3"
        case .r3: "r3"
        case .cUp: "cup"
        case .cDown: "cdown"
        case .cLeft: "cleft"
        case .cRight: "cright"
        default: "none"
        }
    }

    init?(name: String) {
        let all: [SNESButtons] = [.b, .y, .select, .start, .a, .x, .l, .r, .l2, .r2, .l3, .r3,
                                  .cUp, .cDown, .cLeft, .cRight]
        if name == "none" { self = []; return }
        guard let match = all.first(where: { $0.name == name }) else { return nil }
        self = match
    }
}

/// What each emulated button is called on a system's own pad.
enum ButtonLabels {
    static func label(_ button: SNESButtons, pad: GameSystem.PadStyle, system: GameSystem? = nil) -> String {
        if button.isEmpty { return "None" }
        switch pad {
        case .genesis3, .genesis6:
            // PicoDrive: A/B/C <- libretro Y/B/A, X/Y/Z <- L/X/R, Mode <- Select.
            switch button {
            case .y: return "A"
            case .b: return "B"
            case .a: return "C"
            case .l: return "X"
            case .x: return "Y"
            case .r: return "Z"
            case .select: return "Mode"
            case .start: return "Start"
            default: return ""
            }
        case .playstation:
            switch button {
            case .x: return "△"
            case .a: return "○"
            case .b: return "✕"
            case .y: return "□"
            case .l: return "L1"
            case .r: return "R1"
            case .l2: return "L2"
            case .r2: return "R2"
            case .l3: return "L3"
            case .r3: return "R3"
            case .select: return "Select"
            case .start: return "Start"
            default: return ""
            }
        case .n64:
            switch button {
            case .b: return "A"
            case .y: return "B"
            case .l2: return "Z"
            case .l: return "L"
            case .r: return "R"
            case .start: return "Start"
            case .cUp: return "C▲"
            case .cDown: return "C▼"
            case .cLeft: return "C◀"
            case .cRight: return "C▶"
            default: return ""
            }
        case .snes, .nes:
            switch button {
            case .a: return "A"
            case .b: return "B"
            case .x: return "X"
            case .y: return "Y"
            case .l: return "L"
            case .r: return "R"
            case .select: return system?.isArcade == true ? "Coin" : "Select"
            case .start: return "Start"
            default: return ""
            }
        }
    }
}
