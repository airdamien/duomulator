import Foundation

// STUB — owned by the audio module. Keep signatures.
/// Plays samples from an `AudioRingBuffer` through AVAudioEngine.
final class AudioOutput {
    var isMuted = false
    init(ring: AudioRingBuffer, sampleRate: Double) {}
    func start() throws {}
    func stop() {}
}
