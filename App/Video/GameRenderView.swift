import UIKit
import Metal
import QuartzCore

/// Draws the latest `FrameBuffer` frame with Metal, letterboxed inside its bounds.
///
/// The SNES outputs 8:7 pixels, so a 256x224 frame is shown as 4:3 (hi-res 512-wide and
/// interlaced 448/478-tall frames are halved first, so they keep the same shape). A
/// CADisplayLink locked to 60 Hz pulls frames and skips the GPU entirely when the frame
/// sequence hasn't moved, which matters for battery on a long flight.
final class GameRenderView: UIView {
    enum Scaling { case aspectFit, integer }
    enum Filter { case nearest, linear }
    /// Which part of the frame to show. Dual-screen (DS) frames stack the top screen above
    /// the touch screen; two views can show one screen each, e.g. on either side of the fold.
    enum Region { case full, topHalf, bottomHalf }

    var scaling: Scaling = .aspectFit {
        didSet { if scaling != oldValue { updateContentRect(); needsRedraw = true } }
    }
    var filter: Filter = .nearest {
        didSet { if filter != oldValue { needsRedraw = true } }
    }
    var region: Region = .full {
        didSet { if region != oldValue { updateContentRect(); needsRedraw = true } }
    }
    /// Square pixels (DS) instead of the SNES/NES 8:7 pixel aspect.
    var squarePixels = false {
        didSet { if squarePixels != oldValue { updateContentRect(); needsRedraw = true } }
    }
    /// Show every frame at this aspect whatever its width (Sega: 256 and 320 wide are both 4:3).
    var fixedAspect: CGFloat? {
        didSet { if fixedAspect != oldValue { updateContentRect(); needsRedraw = true } }
    }

    /// Where the game image is drawn, in this view's coordinates. Black letterbox elsewhere.
    private(set) var contentRect: CGRect = .zero
    /// Called on the main thread whenever `contentRect` changes (bounds, scaling, or the core
    /// switching to a mode with a different shape, e.g. 239-line overscan).
    var onContentRectChange: ((CGRect) -> Void)?

    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    private let frameBuffer: FrameBuffer
    private let gpu: GPU?

    private var displayLink: CADisplayLink?
    /// What the owner asked for; the link itself is also paused while backgrounded/offscreen.
    private var wantsRendering = false
    private var isInBackground = false

    private var lastSequence: UInt64?
    private var needsRedraw = true
    /// Size of the last frame uploaded (drives aspect and integer steps).
    private var frameSize = (width: 256, height: 224)

    /// Size of the part of the frame `region` shows.
    private var visibleFrameSize: (width: Int, height: Int) {
        region == .full ? frameSize : (frameSize.width, frameSize.height / 2)
    }
    /// Texture slot holding the last uploaded frame; nil until the first upload.
    private var currentSlot: Int?

    init(frameBuffer: FrameBuffer) {
        self.frameBuffer = frameBuffer
        gpu = GPU()
        super.init(frame: .zero)
        backgroundColor = .black
        isOpaque = true
        metalLayer.device = gpu?.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.maximumDrawableCount = 3

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(appDidEnterBackground),
                           name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(appWillEnterForeground),
                           name: UIApplication.willEnterForegroundNotification, object: nil)
        registerForTraitChanges([UITraitDisplayScale.self]) { (view: GameRenderView, _) in
            view.setNeedsLayout()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        displayLink?.invalidate()
    }

    // MARK: Lifecycle

    /// Starts/stops the display link that pulls frames.
    func startRendering() {
        wantsRendering = true
        needsRedraw = true
        updateLinkState()
    }

    func stopRendering() {
        wantsRendering = false
        updateLinkState()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        setNeedsLayout()
        updateLinkState()
    }

    @objc private func appDidEnterBackground() {
        // GPU work submitted from the background is rejected; stop pulling frames entirely.
        isInBackground = true
        updateLinkState()
    }

    @objc private func appWillEnterForeground() {
        isInBackground = false
        needsRedraw = true
        updateLinkState()
    }

    private func updateLinkState() {
        let shouldRun = wantsRendering && !isInBackground && window != nil && gpu != nil
        if shouldRun {
            if displayLink == nil {
                let link = CADisplayLink(target: LinkTarget(self), selector: #selector(LinkTarget.tick))
                // A fixed 60 Hz keeps ProMotion panels from spinning up to 120 Hz for a 60 fps game.
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
            needsRedraw = true
        } else {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    /// Breaks the CADisplayLink → target retain cycle.
    private final class LinkTarget: NSObject {
        weak var view: GameRenderView?
        init(_ view: GameRenderView) { self.view = view }
        @objc func tick() { view?.drawIfNeeded() }
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale
                                                     : (window?.screen.scale ?? 1)
        contentScaleFactor = scale
        metalLayer.contentsScale = scale
        let pixels = CGSize(width: (bounds.width * scale).rounded(),
                            height: (bounds.height * scale).rounded())
        if metalLayer.drawableSize != pixels {
            metalLayer.drawableSize = pixels
        }
        updateContentRect()
        needsRedraw = true
    }

    /// Recomputes `contentRect` from the current bounds, scaling mode and frame shape.
    private func updateContentRect() {
        let scale = metalLayer.contentsScale
        let visible = visibleFrameSize
        let pixelRect = Self.displayRect(frameWidth: visible.width, frameHeight: visible.height,
                                         drawableSize: metalLayer.drawableSize, scaling: scaling,
                                         squarePixels: squarePixels, fixedAspect: fixedAspect)
        let rect = CGRect(x: pixelRect.minX / scale, y: pixelRect.minY / scale,
                          width: pixelRect.width / scale, height: pixelRect.height / scale)
        if rect != contentRect {
            contentRect = rect
            onContentRectChange?(rect)
        }
    }

    /// The frame's on-screen rect in drawable pixels, whole-pixel aligned and centered.
    /// - aspectFit: largest rect with the frame's display aspect that fits.
    /// - integer: largest whole multiple of the (de-interlaced) line count that fits, keeping
    ///   the same aspect; falls back to aspectFit when not even 1x fits.
    static func displayRect(frameWidth: Int, frameHeight: Int, drawableSize: CGSize,
                            scaling: Scaling, squarePixels: Bool = false,
                            fixedAspect: CGFloat? = nil) -> CGRect {
        let W = drawableSize.width.rounded(.down), H = drawableSize.height.rounded(.down)
        guard W > 0, H > 0, frameWidth > 0, frameHeight > 0 else { return .zero }
        let baseW: CGFloat, baseH: CGFloat, aspect: CGFloat
        if let fixedAspect {
            baseH = CGFloat(frameHeight > 240 ? frameHeight / 2 : frameHeight)
            aspect = fixedAspect
            baseW = baseH * aspect
        } else if squarePixels {
            baseW = CGFloat(frameWidth)
            baseH = CGFloat(frameHeight)
            aspect = baseW / baseH
        } else {
            // Hi-res (512 wide) and interlaced (448/478 tall) frames cover the same screen
            // area as their 256 x 224/239 counterparts.
            baseW = CGFloat(frameWidth > 256 ? frameWidth / 2 : frameWidth)
            baseH = CGFloat(frameHeight > 240 ? frameHeight / 2 : frameHeight)
            // 256x224 → exactly 4:3; other shapes scale from there (8:7 pixel aspect).
            aspect = (4.0 / 3.0) * (baseW / 256) * (224 / baseH)
        }

        var w: CGFloat = 0, h: CGFloat = 0
        if scaling == .integer {
            var n = (H / baseH).rounded(.down)
            while n >= 1, (n * baseH * aspect).rounded() > W { n -= 1 }
            if n >= 1 {
                h = n * baseH
                w = (h * aspect).rounded()
            }
        }
        if w == 0 {
            if W / H > aspect {
                h = H
                w = min(W, (H * aspect).rounded())
            } else {
                w = W
                h = min(H, (W / aspect).rounded())
            }
        }
        return CGRect(x: ((W - w) / 2).rounded(.down), y: ((H - h) / 2).rounded(.down),
                      width: w, height: h)
    }

    // MARK: Drawing

    private func drawIfNeeded() {
        guard let gpu else { return }
        let sequence = frameBuffer.latestSequence
        let hasNewFrame = sequence != lastSequence
        guard hasNewFrame || needsRedraw else { return }
        let drawableSize = metalLayer.drawableSize
        guard drawableSize.width >= 1, drawableSize.height >= 1 else { return }

        // All slots busy (GPU behind): try again next tick rather than block the main thread.
        guard gpu.inFlight.wait(timeout: .now()) == .success else { return }

        var slot = currentSlot ?? 0
        if hasNewFrame || currentSlot == nil {
            slot = ((currentSlot ?? -1) + 1) % GPU.slotCount
            let texture = gpu.textures[slot]
            // Lock held only for the copy into the texture.
            let uploaded = frameBuffer.withLatestFrame { frame, pixels -> (Int, Int, UInt64) in
                let count = frame.width * frame.height
                let src = pixels.assumingMemoryBound(to: UInt16.self)
                let dst = gpu.staging
                for i in 0..<count {
                    let p = UInt32(src[i])
                    let r = (p >> 11) & 0x1F, g = (p >> 5) & 0x3F, b = p & 0x1F
                    dst[i] = 0xFF00_0000
                        | ((r << 3 | r >> 2) << 16) | ((g << 2 | g >> 4) << 8) | (b << 3 | b >> 2)
                }
                texture.replace(region: MTLRegionMake2D(0, 0, frame.width, frame.height),
                                mipmapLevel: 0, withBytes: dst, bytesPerRow: frame.width * 4)
                return (frame.width, frame.height, frame.sequence)
            }
            currentSlot = slot
            lastSequence = uploaded.2
            if uploaded.0 != frameSize.width || uploaded.1 != frameSize.height {
                frameSize = (uploaded.0, uploaded.1)
                updateContentRect()
            }
        }

        guard let drawable = metalLayer.nextDrawable(),
              let commands = gpu.queue.makeCommandBuffer() else {
            gpu.inFlight.signal()
            needsRedraw = true
            return
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        if let encoder = commands.makeRenderCommandEncoder(descriptor: pass) {
            let visible = visibleFrameSize
            let rect = Self.displayRect(frameWidth: visible.width, frameHeight: visible.height,
                                        drawableSize: drawableSize, scaling: scaling,
                                        squarePixels: squarePixels, fixedAspect: fixedAspect)
            if rect.width > 0, rect.height > 0 {
                encoder.setViewport(MTLViewport(originX: Double(rect.minX), originY: Double(rect.minY),
                                                width: Double(rect.width), height: Double(rect.height),
                                                znear: 0, zfar: 1))
                encoder.setRenderPipelineState(gpu.pipeline)
                encoder.setFragmentTexture(gpu.textures[slot], index: 0)
                encoder.setFragmentSamplerState(filter == .linear ? gpu.linearSampler : gpu.nearestSampler,
                                                index: 0)
                // The visible rows of the frame, in texture coordinates.
                let texW = Float(FrameBuffer.maxWidth), texH = Float(FrameBuffer.maxHeight)
                let top: Float = region == .bottomHalf ? Float(frameSize.height - visible.height) : 0
                var uniforms = Uniforms(
                    uvMin: SIMD2(0, top / texH),
                    uvMax: SIMD2(Float(frameSize.width) / texW, (top + Float(visible.height)) / texH),
                    texel: SIMD2(1 / texW, 1 / texH))
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
            encoder.endEncoding()
        }
        let semaphore = gpu.inFlight
        commands.addCompletedHandler { _ in semaphore.signal() }
        commands.present(drawable)
        commands.commit()
        needsRedraw = false
    }

    /// Mirrors `GameUniforms` in GameShaders.metal.
    private struct Uniforms {
        var uvMin: SIMD2<Float>
        var uvMax: SIMD2<Float>
        var texel: SIMD2<Float>
    }

    /// Long-lived Metal objects. Frames are uploaded into a ring of max-size textures so the
    /// CPU never overwrites a texture the GPU is still sampling.
    private final class GPU {
        static let slotCount = 3

        let device: MTLDevice
        let queue: MTLCommandQueue
        let pipeline: MTLRenderPipelineState
        let nearestSampler: MTLSamplerState
        let linearSampler: MTLSamplerState
        let textures: [MTLTexture]
        /// BGRA8 conversion buffer for one max-size frame; main thread only.
        let staging = UnsafeMutablePointer<UInt32>.allocate(capacity: FrameBuffer.maxWidth * FrameBuffer.maxHeight)
        let inFlight = DispatchSemaphore(value: slotCount)

        init?() {
            guard let device = MTLCreateSystemDefaultDevice(),
                  let queue = device.makeCommandQueue(),
                  let library = device.makeDefaultLibrary() else { return nil }
            self.device = device
            self.queue = queue

            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "game_vertex")
            desc.fragmentFunction = library.makeFunction(name: "game_fragment_rgb565")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            guard let pipeline = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
            self.pipeline = pipeline

            func sampler(_ filter: MTLSamplerMinMagFilter) -> MTLSamplerState? {
                let s = MTLSamplerDescriptor()
                s.minFilter = filter
                s.magFilter = filter
                s.sAddressMode = .clampToEdge
                s.tAddressMode = .clampToEdge
                return device.makeSamplerState(descriptor: s)
            }
            guard let nearest = sampler(.nearest), let linear = sampler(.linear) else { return nil }
            nearestSampler = nearest
            linearSampler = linear

            // RGB565 is expanded to BGRA8 on upload: b5g6r5Unorm would avoid that, but the
            // iOS Simulator's Metal rejects it, and one path that's testable everywhere is worth
            // the ~57K pixel conversion per frame.
            let tex = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: FrameBuffer.maxWidth,
                height: FrameBuffer.maxHeight, mipmapped: false)
            tex.usage = .shaderRead
            tex.storageMode = .shared
            var textures: [MTLTexture] = []
            for _ in 0..<Self.slotCount {
                guard let t = device.makeTexture(descriptor: tex) else { return nil }
                textures.append(t)
            }
            self.textures = textures
        }

        deinit { staging.deallocate() }
    }
}
