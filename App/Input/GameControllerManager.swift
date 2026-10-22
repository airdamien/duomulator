import Foundation
import GameController
import UIKit

/// Feeds MFi / Xbox / PlayStation controllers and hardware keyboards into `InputHub`.
///
/// Gamepads become players in connection order (at most `InputHub.maxPlayers`); when one
/// disconnects the rest move up so player 1 is never left empty. Every input change
/// recomputes that device's whole mask and `set`s it, so a missed edge can't leave a button
/// stuck. All callbacks run on the main thread.
final class GameControllerManager {
    static let shared = GameControllerManager()
    /// True while at least one physical controller is connected (UI hides touch controls).
    /// Keyboards don't count: a docked keyboard shouldn't hide the touch pad.
    private(set) var isControllerConnected = false
    var onConnectionChange: ((Bool) -> Void)?
    /// Called on the controller's menu/home button.
    var onMenu: (() -> Void)?
    /// Which emulated button each physical button presses; set per game from its system's
    /// saved mapping (Settings > Controller Mapping).
    var mapping = ControllerMapping.defaults(for: .snes) {
        didSet { for pad in pads { if let g = pad.controller.extendedGamepad { gamepadChanged(g) } } }
    }

    private var hub: InputHub = .shared
    private var observers: [NSObjectProtocol] = []
    private var isStarted = false
    /// Connected gamepads in player order.
    private var pads: [PadState] = []
    private var keyboardMenuDown = false

    /// Per-controller edge tracking for the menu shortcuts.
    private final class PadState {
        let controller: GCController
        var homeDown = false
        /// Set when Options+Menu fired `onMenu`; Start/Select stay masked until both are up
        /// so the game doesn't also see a Start press.
        var chordLatched = false
        init(_ controller: GCController) { self.controller = controller }
    }

    /// Begins observing controllers and keyboards. Safe to call more than once.
    func start(hub: InputHub = .shared) {
        onMain { [self] in
            guard !isStarted else { return }
            isStarted = true
            self.hub = hub
            GCController.shouldMonitorBackgroundEvents = false

            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) {
                    [weak self] note in
                    guard let controller = note.object as? GCController else { return }
                    self?.attach(controller)
                },
                center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) {
                    [weak self] note in
                    guard let controller = note.object as? GCController else { return }
                    self?.detach(controller)
                },
                center.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) {
                    [weak self] note in
                    self?.attachKeyboard(note.object as? GCKeyboard ?? GCKeyboard.coalesced)
                },
                center.addObserver(forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) {
                    [weak self] _ in
                    self?.hub.set([], source: .keyboard)
                    self?.keyboardMenuDown = false
                },
                // Held buttons are meaningless once we're inactive; the next input event after
                // returning republishes the real state.
                center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil,
                                   queue: .main) { [weak self] _ in
                    self?.clearHub()
                },
            ]

            GCController.controllers().forEach(attach)
            attachKeyboard(GCKeyboard.coalesced)
        }
    }

    /// Stops observing, detaches handlers and releases everything this manager pressed.
    func stop() {
        onMain { [self] in
            guard isStarted else { return }
            isStarted = false
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            for pad in pads { pad.controller.extendedGamepad?.valueChangedHandler = nil }
            pads.removeAll()
            GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = nil
            keyboardMenuDown = false
            clearHub()
            publishConnection()
        }
    }

    // MARK: Gamepads

    private func attach(_ controller: GCController) {
        guard let gamepad = controller.extendedGamepad,
              !pads.contains(where: { $0.controller === controller }) else { return }
        pads.append(PadState(controller))
        controller.handlerQueue = .main
        gamepad.valueChangedHandler = { [weak self] gamepad, _ in
            self?.gamepadChanged(gamepad)
        }
        republishPads()
        publishConnection()
    }

    private func detach(_ controller: GCController) {
        guard let i = pads.firstIndex(where: { $0.controller === controller }) else { return }
        controller.extendedGamepad?.valueChangedHandler = nil
        pads.remove(at: i)
        republishPads()
        publishConnection()
    }

    /// Re-numbers players after a connect/disconnect and rewrites every gamepad slot.
    private func republishPads() {
        for player in 0..<InputHub.maxPlayers {
            hub.set([], source: .gamepad, player: player)
            for stick in 0..<2 { hub.setStick(stick, x: 0, y: 0, source: .gamepad, player: player) }
        }
        for (i, pad) in pads.enumerated() {
            pad.controller.playerIndex = i < InputHub.maxPlayers
                ? GCControllerPlayerIndex(rawValue: i) ?? .indexUnset : .indexUnset
            if let gamepad = pad.controller.extendedGamepad { gamepadChanged(gamepad) }
        }
    }

    private func gamepadChanged(_ gamepad: GCExtendedGamepad) {
        guard let player = pads.firstIndex(where: { $0.controller.extendedGamepad === gamepad })
        else { return }
        let pad = pads[player]
        let snapshot = GamepadSnapshot(gamepad)
        var mask = mapping.buttons(for: snapshot)

        // Options+Menu chord (Select+Start) opens the in-game menu once per press.
        if snapshot.menu && snapshot.options && !pad.chordLatched {
            pad.chordLatched = true
            onMenu?()
        }
        if pad.chordLatched {
            if !snapshot.menu && !snapshot.options { pad.chordLatched = false }
            // The chord isn't a game input: drop whatever Menu and View are bound to.
            var released = snapshot
            released.menu = false
            released.options = false
            mask = mapping.buttons(for: released)
        }
        // Home is often reserved by the system (Game Center overlay); honor it when delivered.
        if snapshot.home && !pad.homeDown { onMenu?() }
        pad.homeDown = snapshot.home

        if player < InputHub.maxPlayers {
            hub.set(mask, source: .gamepad, player: player)
            if mapping.usesAnalogSticks {
                for stick in 0..<2 {
                    let value = snapshot.analog(stick)
                    hub.setStick(stick, x: value.x, y: value.y, source: .gamepad, player: player)
                }
            }
        }
    }

    // MARK: Keyboard

    private func attachKeyboard(_ keyboard: GCKeyboard?) {
        guard let keyboard, let input = keyboard.keyboardInput else { return }
        keyboard.handlerQueue = .main
        input.keyChangedHandler = { [weak self] input, _, keyCode, pressed in
            self?.keyboardChanged(input, keyCode: keyCode, pressed: pressed)
        }
    }

    private func keyboardChanged(_ input: GCKeyboardInput, keyCode: GCKeyCode, pressed: Bool) {
        if keyCode == KeyboardMapping.menuKey {
            if pressed && !keyboardMenuDown { onMain { self.onMenu?() } }
            keyboardMenuDown = pressed
        }
        let mask = KeyboardMapping.buttons { input.button(forKeyCode: $0)?.isPressed ?? false }
        hub.set(mask, source: .keyboard)
    }

    // MARK: Helpers

    private func clearHub() {
        for player in 0..<InputHub.maxPlayers {
            for stick in 0..<2 { hub.setStick(stick, x: 0, y: 0, source: .gamepad, player: player) }
            hub.set([], source: .gamepad, player: player)
            hub.set([], source: .keyboard, player: player)
        }
    }

    private func publishConnection() {
        let connected = !pads.isEmpty
        guard connected != isControllerConnected else { return }
        isControllerConnected = connected
        onConnectionChange?(connected)
    }

    private func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread { body() } else { DispatchQueue.main.async(execute: body) }
    }
}

// MARK: - Mappings

/// Raw state of one extended gamepad, decoupled from GameController so the mapping is testable.
struct GamepadSnapshot: Equatable {
    var up = false, down = false, left = false, right = false
    /// Left and right stick axes, -1...1 (y up positive).
    var stickX: Float = 0, stickY: Float = 0
    var rightStickX: Float = 0, rightStickY: Float = 0
    /// Positional face buttons as GameController names them: south, east, west, north.
    var south = false, east = false, west = false, north = false
    var leftShoulder = false, leftTrigger = false, rightShoulder = false, rightTrigger = false
    var menu = false, options = false, home = false
    var leftStick = false, rightStick = false

    /// Stick deflection needed to count as a d-pad direction.
    static let stickThreshold: Float = 0.5

    init() {}

    init(_ g: GCExtendedGamepad) {
        up = g.dpad.up.isPressed; down = g.dpad.down.isPressed
        left = g.dpad.left.isPressed; right = g.dpad.right.isPressed
        stickX = g.leftThumbstick.xAxis.value; stickY = g.leftThumbstick.yAxis.value
        rightStickX = g.rightThumbstick.xAxis.value; rightStickY = g.rightThumbstick.yAxis.value
        south = g.buttonA.isPressed; east = g.buttonB.isPressed
        west = g.buttonX.isPressed; north = g.buttonY.isPressed
        leftShoulder = g.leftShoulder.isPressed; leftTrigger = g.leftTrigger.isPressed
        rightShoulder = g.rightShoulder.isPressed; rightTrigger = g.rightTrigger.isPressed
        menu = g.buttonMenu.isPressed
        options = g.buttonOptions?.isPressed ?? false
        home = g.buttonHome?.isPressed ?? false
        leftStick = g.leftThumbstickButton?.isPressed ?? false
        rightStick = g.rightThumbstickButton?.isPressed ?? false
    }

    /// Directions from the d-pad and left stick (never remapped).
    var directions: SNESButtons { directions(includingStick: true) }

    /// Directions from the d-pad, plus the left stick unless it's an analog stick of its own
    /// (PlayStation).
    func directions(includingStick: Bool) -> SNESButtons {
        var m: SNESButtons = []
        let t = includingStick ? Self.stickThreshold : .infinity
        if up || stickY >= t { m.insert(.up) }
        if down || stickY <= -t { m.insert(.down) }
        if left || stickX <= -t { m.insert(.left) }
        if right || stickX >= t { m.insert(.right) }
        return m
    }

    /// Libretro analog values (-0x7FFF...0x7FFF, +y down) for stick 0 (left) or 1 (right).
    func analog(_ stick: Int) -> (x: Int16, y: Int16) {
        let (x, y) = stick == 0 ? (stickX, stickY) : (rightStickX, rightStickY)
        func scale(_ v: Float) -> Int16 { Int16((max(-1, min(1, v)) * 32767).rounded()) }
        return (scale(x), scale(-y))
    }

    /// The default (SNES) mapping: Nintendo-style positional, the button where SNES B sits
    /// (south) is SNES B, etc. Games use their system's `ControllerMapping`.
    var buttons: SNESButtons { ControllerMapping.defaults(for: .snes).buttons(for: self) }
}

/// Hardware keyboard layout: arrows, Z/X/A/S face buttons, Q/W shoulders, Return/Right Shift
/// for Start/Select, Esc for the in-game menu.
enum KeyboardMapping {
    static let keys: [(GCKeyCode, SNESButtons)] = [
        (.upArrow, .up), (.downArrow, .down), (.leftArrow, .left), (.rightArrow, .right),
        (.keyZ, .b), (.keyX, .a), (.keyA, .y), (.keyS, .x),
        (.keyQ, .l), (.keyW, .r),
        (.returnOrEnter, .start), (.keypadEnter, .start), (.rightShift, .select),
    ]
    static let menuKey: GCKeyCode = .escape

    /// The full mask given a way to ask whether each key is held.
    static func buttons(isPressed: (GCKeyCode) -> Bool) -> SNESButtons {
        var m: SNESButtons = []
        for (key, button) in keys where isPressed(key) { m.insert(button) }
        return m
    }
}
