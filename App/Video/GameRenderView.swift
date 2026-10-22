import UIKit

// STUB — owned by the video module. Keep signatures.
/// Draws the latest `FrameBuffer` frame with Metal, letterboxed inside its bounds.
final class GameRenderView: UIView {
    enum Scaling { case aspectFit, integer }
    enum Filter { case nearest, linear }

    var scaling: Scaling = .aspectFit
    var filter: Filter = .nearest

    init(frameBuffer: FrameBuffer) { super.init(frame: .zero); backgroundColor = .black }
    required init?(coder: NSCoder) { fatalError() }

    /// Starts/stops the display link that pulls frames.
    func startRendering() {}
    func stopRendering() {}
}
