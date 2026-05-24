import Foundation
import AVFoundation

/// Watches mic energy while TTS is speaking and fires a barge-in trigger
/// when sustained voice is detected. Owns its own tiny AVAudioEngine so it
/// can run independently of the dictation engine and not double-tap the
/// same input node. Stops when TTS stops or when `stop()` is called.
final class BargeInMonitor {

    /// Sustained-voice threshold. RMS over a ~100ms window; tuned for a
    /// desk mic at normal speaking volume. Tunable later via settings.
    var energyThreshold: Float = 0.025
    var sustainedFrames: Int = 3        // ~300ms with 100ms hop

    private let engineCore = AVAudioEngine()
    private var continuation: AsyncStream<String>.Continuation?
    private var aboveThresholdFrames: Int = 0
    private(set) var isRunning: Bool = false

    let triggers: AsyncStream<String>

    init() {
        var cont: AsyncStream<String>.Continuation!
        self.triggers = AsyncStream { c in cont = c }
        self.continuation = cont
    }

    func start(preferredDeviceUID: String?) throws {
        if isRunning { stop() }
        switch CoreAudioInputRouter.route(engine: engineCore, toUID: preferredDeviceUID) {
        case .failed(let why):
            Log.audio.error("barge-in mic routing failed: \(why)")
        default: break
        }
        let input = engineCore.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.evaluate(buffer)
        }
        engineCore.prepare()
        try engineCore.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        engineCore.inputNode.removeTap(onBus: 0)
        if engineCore.isRunning { engineCore.stop() }
        aboveThresholdFrames = 0
    }

    private func evaluate(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        var sum: Float = 0
        for i in 0..<n { sum += channel[i] * channel[i] }
        let rms = sqrt(sum / Float(n))
        if rms > energyThreshold {
            aboveThresholdFrames += 1
            if aboveThresholdFrames >= sustainedFrames {
                continuation?.yield("voice (rms=\(String(format: "%.3f", rms)))")
                aboveThresholdFrames = 0
                // Tearing down AVAudioEngine from inside its own tap thread
                // can deadlock. Hop off the audio I/O thread first.
                DispatchQueue.main.async { [weak self] in self?.stop() }
            }
        } else {
            aboveThresholdFrames = max(0, aboveThresholdFrames - 1)
        }
    }
}
