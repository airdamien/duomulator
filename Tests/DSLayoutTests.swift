import XCTest
@testable import Duomulator

/// DS touch-screen coordinate mapping and the controls that flank the touch screen.
final class DSLayoutTests: XCTestCase {
    /// melonDS's own conversion (src/libretro/input.cpp, Top/Bottom layout, 256x384 frame):
    /// returns the touch-screen pixel a pointer lands on, or nil if it misses the screen.
    private func melonTouch(_ p: (x: Int16, y: Int16)) -> (x: Int, y: Int)? {
        let x = (Int(p.x) + 0x8000) * 256 / 0x10000
        let y = (Int(p.y) + 0x8000) * 384 / 0x10000
        guard (0..<256).contains(x), (192..<384).contains(y) else { return nil }
        return (x, y - 192)
    }

    func testTouchMappingHitsTheRightPixels() throws {
        let topLeft = try XCTUnwrap(melonTouch(DSTouch.pointer(u: 0, v: 0)))
        XCTAssertEqual(topLeft.x, 0); XCTAssertEqual(topLeft.y, 0)
        let bottomRight = try XCTUnwrap(melonTouch(DSTouch.pointer(u: 1, v: 1)))
        XCTAssertEqual(bottomRight.x, 255); XCTAssertEqual(bottomRight.y, 191)
        let center = try XCTUnwrap(melonTouch(DSTouch.pointer(u: 0.5, v: 0.5)))
        XCTAssertEqual(center.x, 128, accuracy: 1); XCTAssertEqual(center.y, 96, accuracy: 1)
        // Out-of-range input is clamped onto the screen, never onto the top screen.
        XCTAssertNotNil(melonTouch(DSTouch.pointer(u: -1, v: -1)))
    }

    func testControlsFlankTheTouchScreen() {
        let bounds = CGRect(x: 0, y: 0, width: 669, height: 400)
        let screen = CGRect(x: 160, y: 20, width: 349, height: 262)
        let layout = ControllerLayout(bounds: bounds, style: .panel, system: .nds, reserved: screen)
        XCTAssertGreaterThan(layout.dpadRadius, 30)
        XCTAssertLessThan(layout.dpadCenter.x + layout.dpadRadius, screen.minX)
        XCTAssertGreaterThan(layout.faceCenter.x - layout.faceSpacing - layout.faceRadius, screen.maxX)
        for rect in [layout.lRect, layout.rRect, layout.selectRect, layout.startRect] {
            XCTAssertFalse(rect.isNull)
            XCTAssertFalse(rect.intersects(screen), "\(rect) overlaps the touch screen")
        }
        XCTAssertTrue(layout.menuRect.isNull, "the quick bar has the menu in DS layouts")
        // Every press anywhere in the gutters stays off the screen, and all buttons are reachable.
        var reachable: SNESButtons = []
        for x in stride(from: 0, to: bounds.width, by: 3) {
            for y in stride(from: 0, to: bounds.height, by: 3) {
                let p = CGPoint(x: x, y: y)
                guard let control = layout.control(at: p) else { continue }
                XCTAssertFalse(screen.contains(p), "control at \(p) is on the touch screen")
                reachable.formUnion(layout.buttons(at: p, for: control))
            }
        }
        XCTAssertTrue(reachable.isSuperset(of: [.a, .b, .x, .y, .l, .r, .start, .select, .up, .down, .left, .right]))
    }

    func testDualScreenLayoutSplitsAtTheFold() throws {
        let bounds = CGRect(x: 0, y: 0, width: 669, height: 951)
        let division = CGRect(x: 0, y: 455.5, width: 669, height: 40)
        let frames = GameLayout.frames(system: .nds, posture: .tent(division: division), bounds: bounds,
                                       safeArea: .zero, occlusions: [])
        let bottom = try XCTUnwrap(frames.secondScreen)
        XCTAssertLessThanOrEqual(frames.game.maxY, division.minY, "top screen above the crease")
        XCTAssertGreaterThanOrEqual(bottom.minY, division.maxY, "touch screen below it")
        XCTAssertEqual(frames.game.width / frames.game.height, 4.0 / 3.0, accuracy: 0.02)
        XCTAssertEqual(bottom.width / bottom.height, 4.0 / 3.0, accuracy: 0.02)
        let controls = try XCTUnwrap(frames.controls)
        XCTAssertTrue(controls.contains(bottom), "controls panel surrounds the touch screen")
        XCTAssertGreaterThanOrEqual(bottom.minX - controls.minX, 110, "room for the d-pad")
    }

    func testControlsStayWithAGamepadConnected() throws {
        let bounds = CGRect(x: 0, y: 0, width: 669, height: 951)
        for posture in [Posture.tent(division: CGRect(x: 0, y: 455.5, width: 669, height: 40)), .flat, .closed] {
            let frames = GameLayout.frames(system: .nds, posture: posture, bounds: bounds,
                                           safeArea: .zero, occlusions: [])
            XCTAssertNotNil(frames.controls, "\(posture)")
            XCTAssertNotNil(frames.secondScreen, "\(posture)")
        }
    }
}

/// Duo outer display: the quick bar stands at the right edge and nothing overlaps it.
final class OuterDisplayLayoutTests: XCTestCase {
    func testQuickBarMovesToTheRightEdge() {
        for size in [CGSize(width: 466, height: 678), CGSize(width: 678, height: 466)] {
            let bounds = CGRect(origin: .zero, size: size)
            let insets = UIEdgeInsets(top: 0, left: 0, bottom: 20, right: 0)
            let frames = GameLayout.frames(system: .snes, posture: .closed, bounds: bounds,
                                           safeArea: insets, occlusions: [])
            let bar = try! XCTUnwrap(frames.quickBar)
            XCTAssertTrue(frames.quickBarVertical)
            XCTAssertLessThanOrEqual(bar.maxX, bounds.maxX)
            XCTAssertGreaterThan(bar.minX, bounds.midX)
            XCTAssertGreaterThan(bar.height, bar.width)
            XCTAssertFalse(frames.game.intersects(bar), "\(size)")
            XCTAssertFalse(try! XCTUnwrap(frames.controls).intersects(bar), "\(size)")
        }
    }

    func testQuickBarUsesTheSystemSideStrip() {
        // The outer display reserves a strip on the right for system bars.
        let bounds = CGRect(x: 0, y: 0, width: 466, height: 678)
        let insets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 84)
        let frames = GameLayout.frames(system: .snes, posture: .closed, bounds: bounds,
                                       safeArea: insets, occlusions: [])
        let bar = try! XCTUnwrap(frames.quickBar)
        XCTAssertGreaterThanOrEqual(bar.minX, bounds.maxX - 84)
        XCTAssertEqual(frames.game.width, 466 - 84, accuracy: 1)
    }

    func testRegularIPhoneKeepsHorizontalBar() {
        let bounds = CGRect(x: 0, y: 0, width: 393, height: 852)
        let frames = GameLayout.frames(system: .snes, posture: .flat, bounds: bounds,
                                       safeArea: UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0),
                                       occlusions: [])
        XCTAssertFalse(frames.quickBarVertical)
    }
}

/// DS in landscape: screens over/under in a center column, controls present on both sides.
final class DSLandscapeTests: XCTestCase {
    func testLandscapeKeepsControls() {
        for size in [CGSize(width: 956, height: 440), CGSize(width: 852, height: 393), CGSize(width: 951, height: 669)] {
            let bounds = CGRect(origin: .zero, size: size)
            let safe = UIEdgeInsets(top: 0, left: 62, bottom: 21, right: 62)
            for posture in [Posture.flat, .closed] {
                let f = GameLayout.frames(system: .nds, posture: posture, bounds: bounds, safeArea: safe, occlusions: [])
                let bottom = try! XCTUnwrap(f.secondScreen)
                XCTAssertEqual(f.game.minX, bottom.minX, "\(size): screens over/under")
                XCTAssertLessThanOrEqual(f.game.maxY, bottom.minY)
                XCTAssertTrue(f.quickBarVertical)
                XCTAssertEqual(f.controlStyle, .overlay)
                let reserved = try! XCTUnwrap(f.controlsReserved)
                let layout = ControllerLayout(bounds: try! XCTUnwrap(f.controls), safeArea: safe,
                                              style: .overlay, system: .nds, reserved: reserved)
                XCTAssertGreaterThan(layout.dpadRadius, 30, "\(size): d-pad drawn")
                XCTAssertGreaterThan(layout.faceRadius, 10, "\(size): face buttons drawn")
                XCTAssertLessThan(layout.dpadCenter.x + layout.dpadRadius, reserved.minX)
                XCTAssertGreaterThan(layout.faceCenter.x - layout.faceSpacing, reserved.maxX)
                XCTAssertTrue(reserved.contains(try! XCTUnwrap(f.quickBar)))
            }
        }
    }
}
