import XCTest
@testable import Duomulator

/// The NES variant of the on-screen pad: A/B only, on a diagonal, no shoulders.
final class NESInputTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 400, height: 380)

    func testNoShouldersOrXY() {
        for style in [ControllerLayout.Style.panel, .overlay] {
            let layout = ControllerLayout(bounds: bounds, style: style, system: .nes)
            XCTAssertTrue(layout.lRect.isNull)
            XCTAssertTrue(layout.rRect.isNull)
            XCTAssertEqual(layout.faceButtons.map(\.button), [.b, .a])
            // Sweep the whole view: nothing may ever press X, Y, L or R.
            for x in stride(from: 0, to: bounds.width, by: 4) {
                for y in stride(from: 0, to: bounds.height, by: 4) {
                    let point = CGPoint(x: x, y: y)
                    guard let control = layout.control(at: point) else { continue }
                    XCTAssertTrue(layout.buttons(at: point, for: control).isDisjoint(with: [.x, .y, .l, .r]))
                }
            }
        }
    }

    func testDiagonalAndChord() {
        let layout = ControllerLayout(bounds: bounds, style: .panel, system: .nes)
        let b = layout.faceButtons[0].center, a = layout.faceButtons[1].center
        XCTAssertLessThan(b.x, a.x, "B is left of A")
        XCTAssertGreaterThan(b.y, a.y, "B sits lower than A")
        XCTAssertEqual(layout.buttons(at: b, for: .buttons), .b)
        XCTAssertEqual(layout.buttons(at: a, for: .buttons), .a)
        let middle = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        XCTAssertEqual(layout.buttons(at: middle, for: .buttons), [.a, .b], "the gap presses both")
    }

    func testSNESLayoutUnchanged() {
        let layout = ControllerLayout(bounds: bounds, style: .panel)
        XCTAssertEqual(layout.system, .snes)
        XCTAssertFalse(layout.lRect.isNull)
        XCTAssertEqual(Set(layout.faceButtons.map(\.button.rawValue)),
                       Set([SNESButtons.a, .b, .x, .y].map(\.rawValue)))
    }
}
