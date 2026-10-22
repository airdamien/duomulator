import XCTest
import GameController
@testable import Duomulator

/// Geometry → buttons mapping for the touch controller, plus the physical-device mappings.
final class InputTests: XCTestCase {
    private let portrait = CGRect(x: 0, y: 0, width: 393, height: 360)
    private let landscape = CGRect(x: 0, y: 0, width: 852, height: 393)

    private func offset(_ p: CGPoint, _ dx: CGFloat, _ dy: CGFloat) -> CGPoint {
        CGPoint(x: p.x + dx, y: p.y + dy)
    }

    // MARK: D-pad

    func testDpadEightWaysAndDeadZone() {
        let l = ControllerLayout(bounds: portrait, style: .overlay)
        let c = l.dpadCenter, r = l.dpadRadius * 0.7
        XCTAssertEqual(l.dpadDirection(at: c), [])
        XCTAssertEqual(l.dpadDirection(at: offset(c, l.dpadRadius * 0.1, 0)), [])
        XCTAssertEqual(l.dpadDirection(at: offset(c, 0, -r)), .up)
        XCTAssertEqual(l.dpadDirection(at: offset(c, 0, r)), .down)
        XCTAssertEqual(l.dpadDirection(at: offset(c, -r, 0)), .left)
        XCTAssertEqual(l.dpadDirection(at: offset(c, r, 0)), .right)
        XCTAssertEqual(l.dpadDirection(at: offset(c, r, -r)), [.up, .right])
        XCTAssertEqual(l.dpadDirection(at: offset(c, -r, -r)), [.up, .left])
        XCTAssertEqual(l.dpadDirection(at: offset(c, -r, r)), [.down, .left])
        XCTAssertEqual(l.dpadDirection(at: offset(c, r, r)), [.down, .right])
        // A thumb that drifted far off the cross keeps steering.
        XCTAssertEqual(l.dpadDirection(at: offset(c, l.dpadRadius * 3, 0)), .right)
    }

    // MARK: Face buttons

    func testFaceDiamondPositions() {
        let l = ControllerLayout(bounds: portrait, style: .overlay)
        let byButton = Dictionary(uniqueKeysWithValues: l.faceButtons.map { ($0.button.rawValue, $0.center) })
        let x = byButton[SNESButtons.x.rawValue]!, a = byButton[SNESButtons.a.rawValue]!
        let b = byButton[SNESButtons.b.rawValue]!, y = byButton[SNESButtons.y.rawValue]!
        XCTAssertLessThan(x.y, l.faceCenter.y)    // X top
        XCTAssertGreaterThan(a.x, l.faceCenter.x) // A right
        XCTAssertGreaterThan(b.y, l.faceCenter.y) // B bottom
        XCTAssertLessThan(y.x, l.faceCenter.x)    // Y left
        XCTAssertEqual(l.buttons(at: a, for: .buttons), .a)
        XCTAssertEqual(l.buttons(at: b, for: .buttons), .b)
    }

    func testBetweenAdjacentFaceButtonsPressesBoth() {
        for bounds in [portrait, landscape] {
            for style in [ControllerLayout.Style.overlay, .panel] {
                let l = ControllerLayout(bounds: bounds, style: style)
                let c = l.faceCenter, d = l.faceSpacing / 2
                XCTAssertEqual(l.buttons(at: offset(c, -d, d), for: .buttons), [.b, .y])
                XCTAssertEqual(l.buttons(at: offset(c, d, d), for: .buttons), [.b, .a])
                XCTAssertEqual(l.buttons(at: offset(c, d, -d), for: .buttons), [.x, .a])
                // Dead center never presses opposite buttons.
                let center = l.buttons(at: c, for: .buttons)
                XCTAssertFalse(center.contains([.a, .y]) || center.contains([.b, .x]))
            }
        }
    }

    // MARK: Ownership & other buttons

    func testControlOwnership() {
        let l = ControllerLayout(bounds: portrait, style: .overlay)
        XCTAssertEqual(l.control(at: l.dpadCenter), .dpad)
        XCTAssertEqual(l.control(at: l.faceCenter), .buttons)
        XCTAssertEqual(l.control(at: CGPoint(x: l.menuRect.midX, y: l.menuRect.midY)), .menu)
        XCTAssertEqual(l.control(at: CGPoint(x: l.lRect.midX, y: l.lRect.midY)), .buttons)
        // Empty space between the clusters, above Start/Select, belongs to nothing.
        XCTAssertNil(l.control(at: CGPoint(x: portrait.midX, y: l.dpadCenter.y - l.dpadRadius)))
    }

    func testShouldersStartSelect() {
        for style in [ControllerLayout.Style.overlay, .panel] {
            let l = ControllerLayout(bounds: landscape, style: style)
            func mid(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }
            XCTAssertEqual(l.buttons(at: mid(l.lRect), for: .buttons), .l)
            XCTAssertEqual(l.buttons(at: mid(l.rRect), for: .buttons), .r)
            XCTAssertEqual(l.buttons(at: mid(l.startRect), for: .buttons), .start)
            XCTAssertEqual(l.buttons(at: mid(l.selectRect), for: .buttons), .select)
            XCTAssertLessThan(l.lRect.midX, l.rRect.midX)
            XCTAssertLessThan(l.selectRect.maxX, l.startRect.minX)
        }
    }

    func testControlsStayInsideSafeArea() {
        let insets = UIEdgeInsets(top: 0, left: 59, bottom: 21, right: 59)
        let l = ControllerLayout(bounds: landscape, safeArea: insets, style: .overlay)
        let safe = landscape.inset(by: insets)
        XCTAssertGreaterThanOrEqual(l.dpadCenter.x - l.dpadRadius, safe.minX)
        XCTAssertLessThanOrEqual(l.faceCenter.x + l.faceSpacing + l.faceRadius, safe.maxX + 0.5)
        XCTAssertLessThanOrEqual(l.startRect.maxY, safe.maxY)
        XCTAssertTrue(safe.contains(l.lRect) && safe.contains(l.rRect))
    }

    func testControlsDoNotOverlap() {
        for bounds in [portrait, landscape, CGRect(x: 0, y: 0, width: 320, height: 240)] {
            for style in [ControllerLayout.Style.overlay, .panel] {
                let l = ControllerLayout(bounds: bounds, style: style)
                let dpad = CGRect(x: l.dpadCenter.x - l.dpadRadius, y: l.dpadCenter.y - l.dpadRadius,
                                  width: l.dpadRadius * 2, height: l.dpadRadius * 2)
                let e = l.faceSpacing + l.faceRadius
                let face = CGRect(x: l.faceCenter.x - e, y: l.faceCenter.y - e, width: e * 2, height: e * 2)
                let all = [dpad, face, l.lRect, l.rRect, l.selectRect, l.startRect, l.menuRect]
                for i in all.indices {
                    for j in all.indices where j > i {
                        XCTAssertFalse(all[i].intersects(all[j]), "\(style) \(bounds.size): \(i) vs \(j)")
                    }
                }
            }
        }
    }

    func testTinyBoundsHitNothing() {
        let l = ControllerLayout(bounds: CGRect(x: 0, y: 0, width: 40, height: 40), style: .overlay)
        XCTAssertNil(l.control(at: CGPoint(x: 20, y: 20)))
        XCTAssertEqual(l.buttons(at: CGPoint(x: 20, y: 20), for: .buttons), [])
    }

    // MARK: View integration

    func testOverlayPassesThroughEmptySpace() {
        let view = TouchControllerView(style: .overlay, hub: InputHub())
        view.frame = portrait
        view.layoutIfNeeded()
        let l = view.layout
        XCTAssertTrue(view.point(inside: l.dpadCenter, with: nil))
        XCTAssertFalse(view.point(inside: CGPoint(x: portrait.midX, y: l.dpadCenter.y - l.dpadRadius), with: nil))
        view.style = .panel
        view.layoutIfNeeded()
        XCTAssertTrue(view.point(inside: CGPoint(x: portrait.midX, y: portrait.midY), with: nil))
        XCTAssertTrue(view.isMultipleTouchEnabled)
    }

    // MARK: Physical devices

    func testGamepadPositionalMapping() {
        var s = GamepadSnapshot()
        s.south = true; s.east = true
        XCTAssertEqual(s.buttons, [.b, .a])
        s = GamepadSnapshot(); s.west = true; s.north = true
        XCTAssertEqual(s.buttons, [.y, .x])
        s = GamepadSnapshot(); s.leftTrigger = true; s.rightShoulder = true; s.menu = true; s.options = true
        XCTAssertEqual(s.buttons, [.l, .r, .start, .select])
        s = GamepadSnapshot(); s.stickX = 0.6; s.stickY = -0.7
        XCTAssertEqual(s.buttons, [.right, .down])
        s = GamepadSnapshot(); s.stickX = 0.4; s.up = true
        XCTAssertEqual(s.buttons, .up)
    }

    func testKeyboardMapping() {
        let held: Set<GCKeyCode> = [.keyZ, .keyX, .leftArrow, .returnOrEnter, .rightShift, .keyQ]
        XCTAssertEqual(KeyboardMapping.buttons { held.contains($0) }, [.b, .a, .left, .start, .select, .l])
        XCTAssertEqual(KeyboardMapping.buttons { $0 == .keyA || $0 == .keyS || $0 == .keyW }, [.y, .x, .r])
    }

    func testHapticsSettingDefaultsOn() {
        let key = InputSettings.hapticsEnabledKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertTrue(TouchControllerView.hapticsEnabled)
        TouchControllerView.hapticsEnabled = false
        XCTAssertFalse(InputSettings.hapticsEnabled)
    }
}
