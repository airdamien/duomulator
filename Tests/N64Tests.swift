import XCTest
@testable import Duomulator

/// N64: system wiring, the on-screen pad and controller mapping. (Running a game needs a
/// commercial ROM, so the OpenGL ES path is checked by hand.)
final class N64Tests: XCTestCase {
    func testSystem() {
        XCTAssertEqual(GameSystem(romExtension: "z64"), .n64)
        XCTAssertEqual(GameSystem(romExtension: "V64"), .n64)
        XCTAssertEqual(GameSystem.n64.manufacturer, "Nintendo")
        XCTAssertEqual(GameSystem.n64.coreName, "mupen64")
        XCTAssertEqual(BoxArtDownloader.folder(for: .n64), "Nintendo - Nintendo 64")
    }

    func testPadHasDpadStickAndButtons() {
        for size in [CGSize(width: 669, height: 401), CGSize(width: 466, height: 330)] {
            let l = ControllerLayout(bounds: CGRect(origin: .zero, size: size), style: .panel, system: .n64)
            XCTAssertGreaterThan(l.dpadRadius, 30, "the N64 pad has a d-pad (left prong)")
            XCTAssertEqual(l.control(at: l.dpadCenter), .dpad)
            XCTAssertEqual(l.stickCount, 1)
            XCTAssertEqual(l.leftStickCenter.x, size.width / 2, accuracy: 1, "stick in the middle prong")
            XCTAssertEqual(l.control(at: l.leftStickCenter), .stick(0))
            let stick = l.leftStickCenter, r = l.stickRadius
            XCTAssertGreaterThanOrEqual(hypot(stick.x - l.dpadCenter.x, stick.y - l.dpadCenter.y) - r - l.dpadRadius, 12,
                                        "stick crowds the d-pad at \(size)")
            for (button, center) in l.faceButtons {
                XCTAssertGreaterThanOrEqual(hypot(stick.x - center.x, stick.y - center.y) - r - l.radius(for: button), 12,
                                            "stick crowds a button at \(size)")
            }
            XCTAssertLessThanOrEqual(l.startRect.maxY, stick.y - r, "Start above the stick")
            XCTAssertEqual(l.startRect.minY - l.menuRect.maxY, 8, accuracy: 0.5, "Start just below the menu button")
            XCTAssertEqual(l.startRect.midX, l.menuRect.midX, accuracy: 0.5)
            XCTAssertEqual(l.label(for: .cUp), "▲", "arrows only on the yellow buttons")
            XCTAssertFalse(l.zRect.isNull)
            XCTAssertFalse(l.zRect.intersects(l.lRect), "Z beside L")
            XCTAssertTrue(l.selectRect.isNull)
            let buttons = l.faceButtons
            XCTAssertEqual(Set(buttons.map(\.button.rawValue)),
                           Set([SNESButtons.b, .y, .cUp, .cDown, .cLeft, .cRight].map(\.rawValue)))
            for i in buttons.indices {
                for j in buttons.indices where j > i {
                    let gap = hypot(buttons[i].center.x - buttons[j].center.x, buttons[i].center.y - buttons[j].center.y)
                        - l.radius(for: buttons[i].button) - l.radius(for: buttons[j].button)
                    XCTAssertGreaterThan(gap, 2, "\(size): buttons \(i) and \(j) touch")
                }
                // Each button presses itself at its center, and only itself.
                XCTAssertEqual(l.buttons(at: buttons[i].center, for: .buttons), buttons[i].button, "\(size) button \(i)")
            }
            XCTAssertGreaterThan(l.radius(for: .b), l.radius(for: .cUp), "A is bigger than the C buttons")
            XCTAssertEqual(l.buttons(at: CGPoint(x: l.zRect.midX, y: l.zRect.midY), for: .buttons), .l2)
        }
    }

    func testMappingAndLabels() {
        let m = ControllerMapping.defaults(for: .n64)
        XCTAssertTrue(m.usesAnalogSticks)
        var s = GamepadSnapshot()
        s.south = true; s.leftTrigger = true
        XCTAssertEqual(m.buttons(for: s), [.b, .l2], "A and Z")
        XCTAssertEqual(ButtonLabels.label(.b, pad: .n64), "A")
        XCTAssertEqual(ButtonLabels.label(.l2, pad: .n64), "Z")
        XCTAssertEqual(ButtonLabels.label(.cLeft, pad: .n64), "C◀")
        XCTAssertEqual(SNESButtons(name: "cup"), .cUp)
        XCTAssertTrue(ControllerMapping.targets(for: .n64).contains(.cDown))
    }
}
