import Foundation

/// One named stage in the assistant pipeline.
enum LatencyStage: String, CaseIterable {
    // Local Mac pipeline stages
    case wakeDetect       = "wake_detect"
    case sttStart         = "stt_start"
    case sttFirstPartial  = "stt_first_partial"
    case sttFinal         = "stt_final"
    case intentRoute      = "intent_route"
    case fastRoute        = "fast_route"       // FastResponseRouter returned a deterministic answer
    case llmStart         = "llm_start"        // LLM request sent
    case llmComplete      = "llm_complete"     // Full LLM response received
    case actionExecute    = "action_execute"
    case ttsStart         = "tts_start"
    case ttsComplete      = "tts_complete"
    case bargeIn          = "barge_in"

    // Cross-device pipeline stages
    case transcriptSent       = "transcript_sent"       // Android sent transcript.final to daemon
    case daemonReceived       = "daemon_received"        // daemon received transcript.final
    case daemonRouted         = "daemon_routed"          // daemon delivered to Mac client
    case replyGenerated       = "reply_generated"        // Mac generated reply
    case replySentToDaemon    = "reply_sent_to_daemon"   // Mac sent reply to daemon
    case daemonReplyRouted    = "daemon_reply_routed"    // daemon delivered reply to Android
    case androidReplyReceived = "android_reply_received" // Android received reply from daemon
    case daemonRtt            = "daemon_rtt"             // total daemon websocket round-trip
}

/// The set of cross-device stages, in pipeline order.
private let crossDeviceStages: [LatencyStage] = [
    .transcriptSent, .daemonReceived, .daemonRouted,
    .replyGenerated, .replySentToDaemon, .daemonReplyRouted,
    .androidReplyReceived, .daemonRtt,
]

/// Lightweight, thread-safe latency recorder. We capture sparse spans
/// rather than full traces — each `mark(_:)` records the timestamp of a
/// named event, and `measure(from:to:)` returns the delta in ms.
/// Rolling per-stage averages feed the latency widget.
final class LatencyTracker {

    private struct Span {
        let stage: LatencyStage
        let ms: Double
        let at: Date
    }

    private let lock = NSLock()
    private var marks: [LatencyStage: Date] = [:]
    private var recent: [LatencyStage: [Double]] = [:]
    private let perStageWindow = 20

    /// Record an instantaneous timestamp for `stage`.
    func mark(_ stage: LatencyStage, at: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        marks[stage] = at
    }

    /// Record a measured duration (ms) directly.
    func record(_ stage: LatencyStage, ms: Double) {
        lock.lock(); defer { lock.unlock() }
        var bucket = recent[stage] ?? []
        bucket.append(ms)
        if bucket.count > perStageWindow {
            bucket.removeFirst(bucket.count - perStageWindow)
        }
        recent[stage] = bucket
    }

    /// Convenience: measure the gap between two named marks and record it
    /// under `recordAs`. Returns the millisecond delta (or nil if either
    /// mark is missing).
    @discardableResult
    func measure(from start: LatencyStage,
                 to end: LatencyStage,
                 recordAs: LatencyStage? = nil) -> Double? {
        lock.lock()
        let a = marks[start]
        let b = marks[end]
        lock.unlock()
        guard let a, let b else { return nil }
        let ms = b.timeIntervalSince(a) * 1000.0
        if let recordAs { record(recordAs, ms: ms) }
        return ms
    }

    func average(for stage: LatencyStage) -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard let bucket = recent[stage], !bucket.isEmpty else { return nil }
        return bucket.reduce(0, +) / Double(bucket.count)
    }

    /// Snapshot suitable for stuffing into `AppState.latencyMillis`.
    func snapshot() -> [String: Double] {
        lock.lock(); defer { lock.unlock() }
        var out: [String: Double] = [:]
        for stage in LatencyStage.allCases {
            if let bucket = recent[stage], !bucket.isEmpty {
                out[stage.rawValue] = bucket.reduce(0, +) / Double(bucket.count)
            }
        }
        return out
    }

    /// Snapshot of cross-device stages only (transcriptSent … daemonRtt).
    /// Returns averages for any stage that has recorded data.
    func crossDeviceSnapshot() -> [String: Double] {
        lock.lock(); defer { lock.unlock() }
        var out: [String: Double] = [:]
        for stage in crossDeviceStages {
            if let bucket = recent[stage], !bucket.isEmpty {
                out[stage.rawValue] = bucket.reduce(0, +) / Double(bucket.count)
            }
        }
        return out
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        marks.removeAll()
        recent.removeAll()
    }
}
