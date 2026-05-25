import Foundation

// MARK: - TurnRoute

enum TurnRoute: String, Codable, CaseIterable {
    case fastCommand   = "fast_command"    // phrase-store / InstantRouter match
    case llmFallback   = "llm_fallback"    // LLM required, no tool
    case llmWithTool   = "llm_with_tool"   // LLM + tool execution
    case directCommand = "direct_command"  // execute() with no LLM involved
    case unknown       = "unknown"
}

// MARK: - TtsKind

enum TtsKind: String, Codable {
    case local  = "local"   // Piper or Apple AVSpeech
    case cloud  = "cloud"   // any cloud TTS
    case system = "system"  // AVSpeechSynthesizer fallback
}

// MARK: - SpeechTurnTrace

/// Full timing and metadata snapshot for one voice-to-voice pipeline turn.
/// Stored in a 20-turn ring buffer by SpeechTurnStore.
struct SpeechTurnTrace: Identifiable, Codable {
    let id: UUID
    let startedAt: Date
    var timestamps: [String: Date] = [:]
    var route: TurnRoute = .unknown
    var transcriptLength: Int = 0
    var replyLength: Int = 0
    var llmUsed: Bool = false
    var toolUsed: Bool = false
    var ttsKind: TtsKind = .system
    let device: String = "mac"

    // MARK: Derived timings (ms)

    var totalMs: Double? {
        delta(LatencyStage.wakeDetect.rawValue, LatencyStage.playbackStarted.rawValue)
        ?? delta(LatencyStage.wakeDetect.rawValue, LatencyStage.ttsComplete.rawValue)
    }
    var firstAudioMs: Double? { delta(LatencyStage.wakeDetect.rawValue, LatencyStage.ttsStart.rawValue) }
    var sttMs: Double?    { delta(LatencyStage.sttStart.rawValue, LatencyStage.sttFinal.rawValue) }
    var intentMs: Double? { delta(LatencyStage.sttFinal.rawValue, LatencyStage.intentRoute.rawValue) }
    var llmMs: Double?    { delta(LatencyStage.llmStart.rawValue, LatencyStage.llmComplete.rawValue) }
    var llmFirstTokenMs: Double? { delta(LatencyStage.llmStart.rawValue, LatencyStage.llmFirstToken.rawValue) }
    var ttsMs: Double?    { delta(LatencyStage.ttsStart.rawValue, LatencyStage.ttsComplete.rawValue) }
    var toolMs: Double?   { delta(LatencyStage.toolStart.rawValue, LatencyStage.toolEnd.rawValue) }
    var replyLoggerMs: Double? {
        delta(LatencyStage.replyLoggerStart.rawValue, LatencyStage.replyLoggerEnd.rawValue)
    }

    private func delta(_ from: String, _ to: String) -> Double? {
        guard let a = timestamps[from], let b = timestamps[to] else { return nil }
        return b.timeIntervalSince(a) * 1000.0
    }

    /// Stage with the longest duration in this turn.
    var slowestStage: (stage: String, ms: Double)? {
        let pairs: [(String, String, String)] = [
            ("stt",          LatencyStage.sttStart.rawValue,   LatencyStage.sttFinal.rawValue),
            ("intent",       LatencyStage.sttFinal.rawValue,   LatencyStage.intentRoute.rawValue),
            ("llm",          LatencyStage.llmStart.rawValue,   LatencyStage.llmComplete.rawValue),
            ("tool",         LatencyStage.toolStart.rawValue,  LatencyStage.toolEnd.rawValue),
            ("tts",          LatencyStage.ttsStart.rawValue,   LatencyStage.ttsComplete.rawValue),
            ("replyLogger",  LatencyStage.replyLoggerStart.rawValue, LatencyStage.replyLoggerEnd.rawValue),
        ]
        return pairs
            .compactMap { (label, from, to) -> (String, Double)? in
                guard let ms = delta(from, to) else { return nil }
                return (label, ms)
            }
            .max(by: { $0.1 < $1.1 })
    }
}

// MARK: - SpeechTurnStore

/// Thread-safe 20-turn ring buffer.
/// JarvisController calls `beginTurn()` at wake and `completeTurn()` after TTS finishes.
final class SpeechTurnStore {
    static let shared = SpeechTurnStore()
    private init() {}

    private let lock = NSLock()
    private var traces: [SpeechTurnTrace] = []
    private var current: SpeechTurnTrace?
    let cap = 20

    @discardableResult
    func beginTurn() -> UUID {
        let trace = SpeechTurnTrace(id: UUID(), startedAt: Date())
        lock.lock(); defer { lock.unlock() }
        current = trace
        return trace.id
    }

    func mark(_ stage: LatencyStage, at: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        current?.timestamps[stage.rawValue] = at
    }

    func update(_ mutate: (inout SpeechTurnTrace) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard var t = current else { return }
        mutate(&t)
        current = t
    }

    func completeTurn() {
        lock.lock(); defer { lock.unlock() }
        guard let t = current else { return }
        current = nil
        traces.append(t)
        if traces.count > cap { traces.removeFirst(traces.count - cap) }
    }

    /// Most-recent first.
    func recentTraces() -> [SpeechTurnTrace] {
        lock.lock(); defer { lock.unlock() }
        return traces.reversed()
    }

    // MARK: Aggregate statistics

    func averageTotalMs() -> Double? {
        let vals = recentTraces().compactMap(\.totalMs)
        guard !vals.isEmpty else { return nil }
        return vals.reduce(0, +) / Double(vals.count)
    }

    func p50() -> Double? { percentile(0.50) }
    func p95() -> Double? { percentile(0.95) }

    private func percentile(_ p: Double) -> Double? {
        let vals = recentTraces().compactMap(\.totalMs).sorted()
        guard !vals.isEmpty else { return nil }
        let idx = max(0, min(Int(Double(vals.count) * p), vals.count - 1))
        return vals[idx]
    }

    func routeBreakdown() -> [TurnRoute: Int] {
        recentTraces().reduce(into: [:]) { acc, t in acc[t.route, default: 0] += 1 }
    }

    func averageMs(for keyPath: KeyPath<SpeechTurnTrace, Double?>) -> Double? {
        let vals = recentTraces().compactMap { $0[keyPath: keyPath] }
        guard !vals.isEmpty else { return nil }
        return vals.reduce(0, +) / Double(vals.count)
    }
}
