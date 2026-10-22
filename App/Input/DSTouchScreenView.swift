import UIKit

/// The DS touch screen: turns one finger on the bottom-screen image into `InputHub` pointer
/// state. Added over the GameRenderView that shows the bottom screen; `screenRect` reports
/// where that view draws the image, in this view's coordinates.
final class DSTouchScreenView: UIView {
    var screenRect: () -> CGRect = { .zero }

    private let hub: InputHub
    /// The finger driving the stylus; other fingers are ignored until it lifts.
    private var stylus: UITouch?

    init(hub: InputHub = .shared) {
        self.hub = hub
        super.init(frame: .zero)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        screenRect().contains(point)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard stylus == nil, let touch = touches.first else { return }
        stylus = touch
        update(touch)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let stylus, touches.contains(stylus) { update(stylus) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let stylus, touches.contains(stylus) { release() }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let stylus, touches.contains(stylus) { release() }
    }

    override var isHidden: Bool {
        didSet { if isHidden { release() } }
    }

    private func update(_ touch: UITouch) {
        let rect = screenRect()
        guard rect.width > 0, rect.height > 0 else { return }
        // A stylus dragged off the edge keeps pressing at the nearest edge pixel.
        let p = touch.location(in: self)
        let u = min(max((p.x - rect.minX) / rect.width, 0), 1)
        let v = min(max((p.y - rect.minY) / rect.height, 0), 1)
        let pointer = DSTouch.pointer(u: u, v: v)
        hub.setPointer(x: pointer.x, y: pointer.y, pressed: true)
    }

    private func release() {
        stylus = nil
        hub.setPointer(x: 0, y: 0, pressed: false)
    }
}

/// Maps a point on the DS touch screen to libretro pointer coordinates.
enum DSTouch {
    /// melonDS (Top/Bottom layout) scales pointer coordinates (-0x8000...0x7FFF) across its
    /// whole 256x384 frame and keeps touches that land on the lower 256x192 screen. `u`/`v`
    /// are 0...1 across the touch screen.
    static func pointer(u: CGFloat, v: CGFloat) -> (x: Int16, y: Int16) {
        let frameX = min(max(u, 0), 1) * 256                 // 0...256
        let frameY = 192 + min(max(v, 0), 1) * 192           // 192...384
        func scale(_ value: CGFloat, over size: CGFloat) -> Int16 {
            Int16(clamping: Int((value / size * 65536).rounded(.down)) - 32768)
        }
        return (scale(frameX, over: 256), scale(frameY, over: 384))
    }
}
