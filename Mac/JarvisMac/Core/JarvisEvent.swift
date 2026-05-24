import Foundation

// MARK: - JarvisEvent

/// A small, type-safe event record for in-app telemetry.
///
/// Used to diagnose the "thinking forever" / "idle listening" / "slow
/// WhatsApp" / "HA misroute" / "wake gate" class of bugs by surfacing the
/// last N notable things the app did, with timestamps and short labels —
/// **never** transcripts, prompts, tokens, caller names, or message bodies.
///
/// Emit sites call `JarvisTelemetry.shared.record(...)`.  The store is a
/// MainActor-isolated ring buffer (size 500) so any UI surfacing (Debug
/// HUD, future event-stream view) reads without locking.
struct JarvisEvent: Identifiable, Sendable, Hashable {

    /// Stable kinds — exhaustive enum so we can pattern-match in diagnostics
    /// and add per-kind colours / icons in the HUD without parsing strings.
    enum Kind: String, Sendable, Hashable, CaseIterable {
        case wakeDetected           = "wake_detected"
        case wakeRejected           = "wake_rejected"
        case sttStarted             = "stt_started"
        case sttPartial             = "stt_partial"
        case sttFinal               = "stt_final"
        case intentResolved         = "intent_resolved"
        case toolExecuted           = "tool_executed"
        case ttsStarted             = "tts_started"
        case ttsInterrupted         = "tts_interrupted"
        case providerFailed         = "provider_failed"
        case overlayOpened          = "overlay_opened"
        case haCommandSent          = "ha_command_sent"
        case bridgeFrameRejected    = "bridge_frame_rejected"
        case bridgeAuthFailed       = "bridge_auth_failed"
        case proactivityAlertEmitted = "proactivity_alert_emitted"
    }

    let id: UUID
    let kind: Kind
    let timestamp: Date
    /// Short, non-PII labels.  Examples:
    /// `["intent": "weatherCurrent", "source": "phrase_match"]`,
    /// `["provider": "MiniMax", "reason": "timeout"]`,
    /// `["overlay": "calendar"]`.
    /// Values are bounded — keep them short and bounded; the telemetry
    /// store doesn't trim them.
    let detail: [String: String]

    init(_ kind: Kind, _ detail: [String: String] = [:]) {
        self.id = UUID()
        self.kind = kind
        self.timestamp = Date()
        self.detail = detail
    }

    /// Single-line representation for the Debug HUD.
    var debugLine: String {
        let detailStr = detail
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        let ms = Int(timestamp.timeIntervalSince1970 * 1000) % 1_000_000
        return detailStr.isEmpty
            ? "\(ms) \(kind.rawValue)"
            : "\(ms) \(kind.rawValue) — \(detailStr)"
    }
}

// MARK: - JarvisTelemetry

/// MainActor-isolated ring buffer of recent events.
///
/// Lives as a process-global (`shared`) because emit sites are scattered
/// across many MainActor classes; making each take an injected ref would
/// touch every file in the audit.  The buffer is bounded to `maxEvents`,
/// so memory cost is constant.
@MainActor
final class JarvisTelemetry {

    /// Process-global shared instance.  Tests can instantiate their own
    /// `JarvisTelemetry()` if they want isolated state.
    static let shared = JarvisTelemetry()

    /// Maximum events kept in the ring buffer.
    let maxEvents: Int

    /// Newest-first list of recent events.  UI binds to this via `@Observable`
    /// downstream wrappers; this class itself is plain — observers can poll
    /// or wrap it as they need.
    private(set) var events: [JarvisEvent] = []

    /// Total events recorded since launch (including those evicted from the
    /// ring buffer).  Useful for the "events per minute" rate in DebugHUD.
    private(set) var totalRecorded: Int = 0

    init(maxEvents: Int = 500) {
        self.maxEvents = maxEvents
    }

    /// Record a new event.  Cheap — array prepend + tail trim — runs in
    /// the order of microseconds and is safe to call from every emit site.
    func record(_ event: JarvisEvent) {
        events.insert(event, at: 0)
        if events.count > maxEvents {
            events.removeLast(events.count - maxEvents)
        }
        totalRecorded &+= 1
    }

    /// Convenience overload — emit sites can write
    /// `JarvisTelemetry.shared.record(.intentResolved, ["intent": "weatherCurrent"])`
    /// without constructing a `JarvisEvent` value.
    func record(_ kind: JarvisEvent.Kind,
                _ detail: [String: String] = [:]) {
        record(JarvisEvent(kind, detail))
    }

    /// Returns the most recent `n` events.  Cheap snapshot for the HUD.
    func recent(_ n: Int = 50) -> [JarvisEvent] {
        Array(events.prefix(n))
    }

    /// Filtered view — last `n` events of a specific kind.  Used by feature
    /// timelines (e.g. "last 10 intent_resolved" in the Debug HUD).
    func recent(of kind: JarvisEvent.Kind, limit: Int = 20) -> [JarvisEvent] {
        events.lazy.filter { $0.kind == kind }.prefix(limit).map { $0 }
    }

    func clear() {
        events.removeAll()
        totalRecorded = 0
    }
}
