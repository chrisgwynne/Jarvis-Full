import Foundation

/// One wake-phrase detection. `confidence` is the model's score for this
/// hit (sherpa-onnx KWS returns a per-keyword score); UI surfaces it so
/// the user can tune `WakeWordSettings.threshold`.
struct WakeWordEvent: Equatable {
    let timestamp: Date
    let keyword: String
    let confidence: Double
}

/// Per-feedback signal used to grow a labelled log of false
/// accepts/rejects. Phase-2's tuning UI reads this and Phase-3 fine-tuning
/// (if we ever go there) consumes it.
enum WakeWordFeedback: String {
    case falseAccept   // detector fired, user didn't say it
    case falseReject   // user said it, detector missed
}

/// User-tunable wake-word configuration. Stored in `Preferences`.
struct WakeWordSettings: Codable, Equatable {
    var enabled: Bool
    var keywords: [String]           // sherpa-onnx accepts >1; default ["Jarvis"]
    var threshold: Double            // global threshold; 0.0…1.0
    var modelIdentifier: String?     // path or identifier of installed KWS model

    static let `default` = WakeWordSettings(
        enabled: true,
        keywords: ["Jarvis"],
        threshold: 0.5,
        modelIdentifier: nil
    )
}

/// Phase-2 swap target: sherpa-onnx keyword spotting (offline, no key,
/// no cloud, no account). The protocol mirrors what sherpa-onnx KWS
/// exposes — streaming start/stop, per-detection scores, runtime keyword
/// reconfiguration, threshold tuning, and a feedback hook so the UI can
/// label false accepts/rejects.
protocol WakeWordDetecting: AnyObject {
    var isRunning: Bool { get }
    var triggers: AsyncStream<WakeWordEvent> { get }

    /// Apply settings (threshold, keywords, model). Safe to call while
    /// running — implementations should reconfigure in place.
    func configure(_ settings: WakeWordSettings) throws

    func start() throws
    func stop()

    /// Record a labelled outcome for tuning. Implementations may persist
    /// these alongside the audio buffer that produced them (Phase-3).
    func recordFeedback(_ feedback: WakeWordFeedback, for event: WakeWordEvent?)
}

/// Optional health-check extension for wake-word engines that can report
/// whether audio buffers are actively arriving from CoreAudio.
///
/// `WakeWordDetecting.isRunning` only indicates the engine *was started*.
/// A running engine can silently stall (device route change, App Nap, HAL
/// reset, SFSpeechRecognitionTask silent death). This protocol lets the
/// health watchdog detect that and force a restart before the user notices.
protocol WakeWordHealthCheckable: WakeWordDetecting {
    /// Timestamp of the most recent audio buffer received from CoreAudio.
    /// `nil` if no buffer has ever arrived (engine just started or stalled
    /// before the first buffer could be delivered).
    var lastAudioBufferTime: Date? { get }
}

extension WakeWordHealthCheckable {
    /// Maximum age before a buffer timestamp is considered stale (seconds).
    static var maxBufferAgeSecs: TimeInterval { 3.0 }

    /// `true` when a buffer arrived within the last 3 seconds.
    /// A `false` result while `isRunning == true` is a health-check failure.
    var isReceivingAudioBuffers: Bool {
        guard let t = lastAudioBufferTime else { return false }
        return Date().timeIntervalSince(t) < Self.maxBufferAgeSecs
    }
}

/// Phase-1 placeholder: never fires. Push-to-talk drives the MVP.
/// Swap with a `SherpaOnnxWakeWord` implementation in Phase 2 — call sites
/// won't notice because they only see `WakeWordDetecting`.
final class NoopWakeWord: WakeWordDetecting {
    private(set) var isRunning: Bool = false
    let triggers: AsyncStream<WakeWordEvent>
    private let continuation: AsyncStream<WakeWordEvent>.Continuation
    private(set) var settings: WakeWordSettings = .default

    init() {
        var cont: AsyncStream<WakeWordEvent>.Continuation!
        self.triggers = AsyncStream { c in cont = c }
        self.continuation = cont
    }

    func configure(_ settings: WakeWordSettings) throws {
        self.settings = settings
    }

    func start() { isRunning = true }
    func stop()  { isRunning = false }

    func recordFeedback(_ feedback: WakeWordFeedback, for event: WakeWordEvent?) {
        // No-op for the placeholder; the real impl will write to a JSONL
        // log under Application Support for later inspection.
    }
}
