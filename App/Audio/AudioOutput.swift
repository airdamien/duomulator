import Foundation
import AVFoundation
import Synchronization

/// Plays samples from an `AudioRingBuffer` through AVAudioEngine.
///
/// The source node runs at the core's native rate (32040 Hz) and the engine's mixer resamples
/// to the hardware rate. Interruptions pause/resume the engine; route changes (headphones
/// pulled, AirPods dropping) never stop playback, the engine is simply restarted on the new
/// route. All public members are main-thread only.
final class AudioOutput {
    /// Outputs silence but keeps draining the ring so the producer never backs up.
    var isMuted: Bool {
        get { render.muted.load(ordering: .relaxed) }
        set { render.muted.store(newValue, ordering: .relaxed) }
    }

    /// Stereo frames waiting in the ring (diagnostics / pacing).
    var bufferedFrames: Int { ring.availableFrames }

    /// True between `start()` and `stop()`, even while an interruption has the engine paused.
    private(set) var isStarted = false

    private let ring: AudioRingBuffer
    private let sampleRate: Double
    private let render: RenderState
    private var engine: AVAudioEngine
    private var observers: [NSObjectProtocol] = []
    /// Set while a phone call / Siri / alarm owns the audio hardware.
    private var isInterrupted = false

    init(ring: AudioRingBuffer, sampleRate: Double) {
        self.ring = ring
        self.sampleRate = sampleRate > 0 ? sampleRate : 32040
        render = RenderState(ring: ring)
        engine = AVAudioEngine()
        buildGraph()
        observeSession()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        engine.stop()
    }

    /// Configures and activates the audio session and starts the engine. Safe to call again.
    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        // ~10 ms hardware buffer: modest latency without burning extra wakeups.
        try? session.setPreferredIOBufferDuration(0.01)
        try session.setActive(true)
        isStarted = true
        isInterrupted = false
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    /// Stops the engine and releases the session so other apps' audio can resume.
    func stop() {
        isStarted = false
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: Graph

    private func buildGraph() {
        // Standard format = Float32, non-interleaved.
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return }
        let state = render
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
            state.render(frameCount: Int(frameCount), into: bufferList)
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
    }

    /// Tries to (re)start the engine if we're supposed to be playing. Errors are swallowed:
    /// a later route change or interruption-end gives us another chance.
    private func resumeIfWanted() {
        guard isStarted, !isInterrupted, !engine.isRunning else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        engine.prepare()
        try? engine.start()
    }

    // MARK: Session events

    private func observeSession() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: session, queue: .main) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began:
                self.isInterrupted = true
                self.engine.pause()
            case .ended:
                // Resume regardless of .shouldResume: the game is still on screen and the
                // player expects its sound back (e.g. after a cabin announcement alarm/Siri).
                self.isInterrupted = false
                self.resumeIfWanted()
            @unknown default:
                break
            }
        })

        // Headphones unplugged etc.: keep playing on whatever the new route is.
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                            object: session, queue: .main) { [weak self] _ in
            self?.resumeIfWanted()
        })

        // The engine stops itself when the hardware format changes (e.g. new output device).
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange,
                                            object: nil, queue: .main) { [weak self] note in
            guard let self, (note.object as? AVAudioEngine) === self.engine else { return }
            self.resumeIfWanted()
        })

        // mediaserverd crashed: every engine/node is invalid, rebuild from scratch.
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                            object: session, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.engine.stop()
            self.engine = AVAudioEngine()
            self.buildGraph()
            if self.isStarted { try? self.start() }
        })
    }

    // MARK: Render state

    /// Everything the real-time render block touches. Owned separately from `AudioOutput` so
    /// the block doesn't retain it, and preallocated so the block never allocates or locks.
    private final class RenderState: @unchecked Sendable {
        /// Frames converted per pass; larger requests are handled in several passes.
        static let scratchFrames = 4096

        let ring: AudioRingBuffer
        let muted = Atomic<Bool>(false)
        private let scratch: UnsafeMutablePointer<Int16>

        init(ring: AudioRingBuffer) {
            self.ring = ring
            scratch = .allocate(capacity: Self.scratchFrames * 2)
            scratch.initialize(repeating: 0, count: Self.scratchFrames * 2)
        }

        deinit { scratch.deallocate() }

        /// Real-time thread. Fills two non-interleaved Float32 channels from the Int16 ring;
        /// underruns become silence.
        func render(frameCount: Int, into bufferList: UnsafeMutablePointer<AudioBufferList>) {
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count > 0, let left = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return }
            let right = buffers.count > 1
                ? (buffers[1].mData?.assumingMemoryBound(to: Float.self) ?? left) : left
            let silent = muted.load(ordering: .relaxed)
            let scale: Float = 1.0 / 32768.0

            var done = 0
            while done < frameCount {
                let chunk = min(Self.scratchFrames, frameCount - done)
                let got = ring.read(into: scratch, frames: chunk)
                if silent {
                    (left + done).update(repeating: 0, count: chunk)
                    if right != left { (right + done).update(repeating: 0, count: chunk) }
                } else {
                    for i in 0..<got {
                        left[done + i] = Float(scratch[i * 2]) * scale
                        right[done + i] = Float(scratch[i * 2 + 1]) * scale
                    }
                    if got < chunk {
                        (left + done + got).update(repeating: 0, count: chunk - got)
                        if right != left { (right + done + got).update(repeating: 0, count: chunk - got) }
                    }
                }
                done += chunk
                // Ring ran dry: the rest of this callback is silence, no need to keep polling.
                if got < chunk && done < frameCount {
                    (left + done).update(repeating: 0, count: frameCount - done)
                    if right != left { (right + done).update(repeating: 0, count: frameCount - done) }
                    break
                }
            }
        }
    }
}
