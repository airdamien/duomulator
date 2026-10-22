import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Reports when fingers go down on the view and when the last one lifts, without
/// recognising anything: touches reach the views below undelayed and uncancelled.
final class TouchWatcher: UIGestureRecognizer {
    private let onChange: (_ fingersDown: Bool) -> Void
    private var fingers = 0

    init(onChange: @escaping (_ fingersDown: Bool) -> Void) {
        self.onChange = onChange
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if fingers == 0 { onChange(true) }
        fingers += touches.count
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches) }

    private func lift(_ touches: Set<UITouch>) {
        fingers = max(0, fingers - touches.count)
        guard fingers == 0 else { return }
        onChange(false)
        state = .failed   // resets for the next touch sequence
    }

    override func reset() {
        super.reset()
        fingers = 0
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}
