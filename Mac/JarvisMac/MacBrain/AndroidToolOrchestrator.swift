import Foundation
import OSLog

private let toolLogger = Logger(subsystem: "com.jarvis.jarvisapp", category: "androidtool")

// MARK: - Result model

/// Result of a remote Android capability execution.
struct ToolExecutionResult {
    let ok: Bool
    let status: String          // "ok" | "timeout" | "unsupported_capability" | "confirmation_rejected" | etc.
    let message: String?
    let resultPayload: [String: Any]
    let rttMilliseconds: Int?   // round-trip time; nil if unknown

    /// Build a natural-language follow-up sentence for Mac TTS, given the
    /// command that was executed and the params originally sent.
    func spokenSummary(for command: String, params: [String: Any] = [:]) -> String {
        guard ok else {
            return failurePhrase(command: command)
        }
        return Self.successPhrase(command: command, params: params)
    }

    private func failurePhrase(command: String) -> String {
        switch status {
        case "confirmation_rejected":
            return "Okay, I'll leave that."
        case "permission_denied":
            return "I couldn't do that — the app needs permission on your phone."
        case "capability_disabled":
            return "That capability is currently disabled on your phone."
        case "unsupported_capability":
            return "Your phone doesn't support that action."
        case "timeout":
            return "Your phone didn't respond in time — it may be offline."
        case "no_android_device":
            return "I couldn't reach your phone right now."
        default:
            return "I wasn't able to do that: \(message ?? status)."
        }
    }

    private static func successPhrase(command: String, params: [String: Any]) -> String {
        switch command {
        case MacBridgeCapabilityNames.sendSms:
            let to = params["recipient"] as? String ?? "them"
            return "Done — I've texted \(to)."
        case MacBridgeCapabilityNames.sendWhatsapp:
            let to = params["recipient"] as? String ?? "them"
            return "Done — sent a WhatsApp message to \(to)."
        case MacBridgeCapabilityNames.callContact:
            let who = params["contact"] as? String ?? "them"
            return "Calling \(who) now."
        case MacBridgeCapabilityNames.whatsappVoiceCall:
            let who = params["contact"] as? String ?? "them"
            return "Starting a WhatsApp call with \(who)."
        case MacBridgeCapabilityNames.whatsappVideoCall:
            let who = params["contact"] as? String ?? "them"
            return "Starting a WhatsApp video call with \(who)."
        case MacBridgeCapabilityNames.replyToContact:
            let who = params["contact"] as? String ?? "them"
            return "Sent — replied to \(who)."
        case MacBridgeCapabilityNames.replyLastMessage:
            return "Replied to the last message."
        case MacBridgeCapabilityNames.startNavigation:
            let dest = params["destination"] as? String ?? "your destination"
            return "Navigating to \(dest)."
        case MacBridgeCapabilityNames.captureCamera:
            return "Photo taken."
        case MacBridgeCapabilityNames.flashlightSet:
            let on = params["on"] as? Bool ?? true
            return on ? "Flashlight on." : "Flashlight off."
        case MacBridgeCapabilityNames.mediaPlay:
            return "Playing."
        case MacBridgeCapabilityNames.mediaPause:
            return "Paused."
        case MacBridgeCapabilityNames.mediaNext:
            return "Skipped to next track."
        case MacBridgeCapabilityNames.mediaPrevious:
            return "Going back to the previous track."
        case MacBridgeCapabilityNames.volumeSet:
            let pct = params["percent"] as? Int ?? 50
            return "Volume set to \(pct) percent."
        case MacBridgeCapabilityNames.appOpen:
            let app = params["appName"] as? String
                   ?? params["packageName"] as? String
                   ?? "the app"
            return "Opening \(app)."
        case MacBridgeCapabilityNames.timerCreate:
            if let mins = params["minutes"] as? Int, mins > 0 {
                return "Timer set for \(mins) \(mins == 1 ? "minute" : "minutes")."
            } else if let secs = params["seconds"] as? Int, secs > 0 {
                return "Timer set for \(secs) \(secs == 1 ? "second" : "seconds")."
            }
            return "Timer set."
        case MacBridgeCapabilityNames.ringPhone:
            return "Your phone is ringing."
        case MacBridgeCapabilityNames.readNotifications:
            return "I'll read those out."
        case MacBridgeCapabilityNames.speakerOn:
            return "Speaker on."
        case MacBridgeCapabilityNames.speakerOff:
            return "Speaker off."
        case MacBridgeCapabilityNames.toggleSpeaker:
            return "Speaker toggled."
        default:
            return "Done."
        }
    }
}

// MARK: - Capability name constants (mirrors Android MacBridgeCapability)

/// String constants for Android capability names, mirrored from
/// `MacBridgeCapability.kt`.  Keeps `ToolExecutionResult` decoupled from
/// any Android-specific types.
enum MacBridgeCapabilityNames {
    static let callContact        = "call_contact"
    static let sendSms            = "send_sms"
    static let sendWhatsapp       = "send_whatsapp"
    static let findContact        = "find_contact"
    static let ringPhone          = "ring_phone"
    static let whatsappVoiceCall  = "whatsapp.voice_call"
    static let whatsappVideoCall  = "whatsapp.video_call"
    static let replyToContact     = "reply.to_contact"
    static let replyLastMessage   = "reply.last_message"
    static let phoneLocation      = "phone_location"
    static let startNavigation    = "start_navigation"
    static let readNotifications  = "read_notifications"
    static let queryNotification  = "query_notification"
    static let captureCamera      = "capture_camera"
    static let speakerOn          = "audio.speaker_on"
    static let speakerOff         = "audio.speaker_off"
    static let toggleSpeaker      = "audio.toggle_speaker"
    static let flashlightSet      = "flashlight.set"
    static let mediaPlay          = "media.play"
    static let mediaPause         = "media.pause"
    static let mediaNext          = "media.next"
    static let mediaPrevious      = "media.previous"
    static let volumeSet          = "volume.set"
    static let appOpen            = "app.open"
    static let timerCreate        = "timer.create"
}

// MARK: - Clear reason (for diagnostics)

enum OrchestrationClearReason: String {
    case daemonRestart   = "daemon_restart"
    case androidReconnect = "android_reconnect"
    case macReconnect    = "mac_reconnect"
    case shutdown        = "shutdown"
    case test            = "test"
}

// MARK: - Diagnostics

/// Observable diagnostics for the distributed execution pipeline.
/// Exposed to `DistributedDiagnosticsView` and the debug HUD.
@Observable
@MainActor
final class AndroidToolOrchestratorDiagnostics {
    static let shared = AndroidToolOrchestratorDiagnostics()

    // Counts
    var successCount: Int = 0
    var failureCount: Int = 0
    var timeoutCount: Int = 0
    var staleResultDropCount: Int = 0   // result arrived after timeout already fired
    var duplicateRouteIdCount: Int = 0  // same routeId submitted twice
    var pendingCapCount: Int = 0        // current pending continuation count (≤ maxPending)
    var pendingCapPeak: Int = 0         // all-time peak pending count
    var clearCount: Int = 0             // times clearPending() was called (reconnects etc.)

    // Latency (ring buffer, last 100 samples)
    private var rttSamples: [Int] = []
    private let maxSamples = 100

    var p50RttMs: Int {
        sorted50thPercentile(rttSamples)
    }
    var p95RttMs: Int {
        sorted95thPercentile(rttSamples)
    }
    var averageRttMs: Int {
        guard !rttSamples.isEmpty else { return 0 }
        return rttSamples.reduce(0, +) / rttSamples.count
    }

    // Last events
    var lastCommand: String = ""
    var lastStatus: String = ""
    var lastRttMs: Int = 0
    var lastClearReason: String = ""

    func recordSuccess(command: String, rttMs: Int) {
        successCount += 1
        lastCommand = command
        lastStatus = "ok"
        lastRttMs = rttMs
        appendRtt(rttMs)
    }

    func recordFailure(command: String, status: String, rttMs: Int) {
        failureCount += 1
        if status == "timeout" { timeoutCount += 1 }
        lastCommand = command
        lastStatus = status
        lastRttMs = rttMs
        appendRtt(rttMs)
    }

    func recordStaleResultDrop() { staleResultDropCount += 1 }
    func recordDuplicateRouteId() { duplicateRouteIdCount += 1 }

    func updatePendingCount(_ n: Int) {
        pendingCapCount = n
        if n > pendingCapPeak { pendingCapPeak = n }
    }

    func recordClear(reason: OrchestrationClearReason, droppedCount: Int) {
        clearCount += 1
        lastClearReason = "\(reason.rawValue) (dropped \(droppedCount))"
    }

    func reset() {
        successCount = 0; failureCount = 0; timeoutCount = 0
        staleResultDropCount = 0; duplicateRouteIdCount = 0
        pendingCapCount = 0; pendingCapPeak = 0; clearCount = 0
        rttSamples.removeAll()
        lastCommand = ""; lastStatus = ""; lastRttMs = 0; lastClearReason = ""
    }

    private func appendRtt(_ ms: Int) {
        rttSamples.append(ms)
        if rttSamples.count > maxSamples { rttSamples.removeFirst() }
    }

    private func sorted50thPercentile(_ samples: [Int]) -> Int {
        guard !samples.isEmpty else { return 0 }
        let s = samples.sorted()
        return s[s.count / 2]
    }

    private func sorted95thPercentile(_ samples: [Int]) -> Int {
        guard !samples.isEmpty else { return 0 }
        let s = samples.sorted()
        let idx = max(0, Int(Double(s.count) * 0.95) - 1)
        return s[idx]
    }
}

// MARK: - Pending request tracking

private struct PendingRequest {
    let command: String
    let params: [String: Any]
    let startedAt: Date
}

// MARK: - Orchestrator

/// Mac-side orchestrator for Android capability execution.
///
/// Sends an `execution.request` envelope through `DaemonAppBridge` (daemon mode)
/// or via `onDirectSend` (direct/GatewayAndroidConnector mode) and awaits the
/// corresponding `execution.result` using a `CheckedContinuation`.
///
/// ## Safety properties
///   - Maximum `maxPendingRequests` concurrent executions; excess submissions fail immediately.
///   - Duplicate routeId detected and rejected.
///   - Stale results (arriving after timeout) are dropped safely — no double-resume.
///   - `clearPending(reason:)` resolves all in-flight requests as `.timeout` on reconnect
///     to prevent orphaned continuations after daemon/Android/Mac restart.
///
/// ## Usage
/// ```swift
/// let result = await AndroidToolOrchestrator.shared.submitTool(
///     command: MacBridgeCapabilityNames.sendSms,
///     params: ["recipient": "Cath", "message": "I'm on my way"]
/// )
/// speak(result.spokenSummary(for: MacBridgeCapabilityNames.sendSms, params: ["recipient": "Cath"]))
/// ```
@MainActor
final class AndroidToolOrchestrator {
    static let shared = AndroidToolOrchestrator()

    private typealias Cont = CheckedContinuation<ToolExecutionResult, Never>

    // MARK: - State

    /// Pending continuations keyed by correlationId / routeId.
    private var pending: [String: (cont: Cont, meta: PendingRequest)] = [:]

    /// Maximum number of concurrent in-flight executions.
    /// Excess `submitTool` calls resolve immediately with `.busy`.
    let maxPendingRequests = 20

    /// Seconds before a pending request auto-resolves as `.timeout`.
    /// Intentionally longer than Android's own 8s timeout to give
    /// the device time to reply even on slow Tailscale connections.
    var timeoutSeconds: Double = 15

    let diagnostics = AndroidToolOrchestratorDiagnostics.shared

    // MARK: - Callbacks

    /// Set by JarvisController when GatewayAndroidConnector (direct mode) is active.
    var onDirectSend: (([String: Any]) -> Void)?

    // MARK: - Submit

    /// Send `execution.request` to the connected Android device and await result.
    ///
    /// - Parameters:
    ///   - command: A capability constant from `MacBridgeCapabilityNames`.
    ///   - params: JSON-serialisable parameters for the capability.
    ///   - targetDeviceId: Specific Android device ID to target; `nil` = first connected.
    /// - Returns: `ToolExecutionResult` (never throws; on timeout/busy `ok == false`).
    func submitTool(
        command: String,
        params: [String: Any] = [:],
        targetDeviceId: String? = nil
    ) async -> ToolExecutionResult {
        // Capacity cap: reject if too many in-flight
        if pending.count >= maxPendingRequests {
            toolLogger.warning("androidTool: capacity limit (\(self.maxPendingRequests)) reached — rejecting command=\(command, privacy: .public)")
            diagnostics.recordFailure(command: command, status: "busy", rttMs: 0)
            return ToolExecutionResult(ok: false, status: "busy",
                                       message: "Too many pending executions (\(maxPendingRequests) max).",
                                       resultPayload: [:], rttMilliseconds: nil)
        }

        let routeId = UUID().uuidString
        let startedAt = Date()
        toolLogger.info("androidTool: submit command=\(command, privacy: .public) routeId=\(routeId, privacy: .public)")

        let envelope = buildEnvelope(command: command, params: params,
                                     targetDeviceId: targetDeviceId, routeId: routeId)

        return await withCheckedContinuation { (cont: Cont) in
            // Duplicate routeId guard (theoretically impossible with UUID but belt-and-suspenders)
            if pending[routeId] != nil {
                toolLogger.error("androidTool: duplicate routeId=\(routeId, privacy: .public) — dropping")
                self.diagnostics.recordDuplicateRouteId()
                cont.resume(returning: ToolExecutionResult(
                    ok: false, status: "error",
                    message: "Duplicate routeId — this is a bug.",
                    resultPayload: [:], rttMilliseconds: nil
                ))
                return
            }

            // Register BEFORE sending to avoid a race where the result arrives
            // before the continuation is stored.
            self.pending[routeId] = (cont: cont, meta: PendingRequest(
                command: command, params: params, startedAt: startedAt
            ))
            self.diagnostics.updatePendingCount(self.pending.count)

            // Daemon path
            DaemonAppBridge.shared.send(envelope)

            // Direct path (GatewayAndroidConnector, no daemon)
            self.onDirectSend?(envelope)

            // Timeout guard — fires on the MainActor after timeoutSeconds
            let timeoutSecs = self.timeoutSeconds
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeoutSecs))
                self?.timeoutPending(routeId: routeId, command: command, startedAt: startedAt)
            }
        }
    }

    // MARK: - Receive result

    /// Called when `DaemonAppBridge.onToolResult` fires with an `execution.result`
    /// frame (daemon mode) or when GatewayAndroidConnector forwards a result (direct mode).
    func handleResult(data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            toolLogger.warning("androidTool: malformed result data — ignoring")
            return
        }

        let correlationId = json["correlationId"] as? String ?? ""
        guard !correlationId.isEmpty else {
            toolLogger.warning("androidTool: result has no correlationId — ignoring")
            return
        }

        let payload   = json["payload"] as? [String: Any] ?? [:]
        let ok        = payload["ok"] as? Bool ?? false
        let status    = payload["status"] as? String ?? (ok ? "ok" : "error")
        let message   = payload["message"] as? String
        let resultPayload = payload["result"] as? [String: Any] ?? [:]

        guard let entry = pending.removeValue(forKey: correlationId) else {
            // Stale result: arrived after timeout already fired and cleared the entry.
            toolLogger.debug("androidTool: stale/unknown correlationId=\(correlationId, privacy: .public) — dropped")
            diagnostics.recordStaleResultDrop()
            return
        }

        let rttMs = Int(Date().timeIntervalSince(entry.meta.startedAt) * 1000)
        diagnostics.updatePendingCount(pending.count)

        let result = ToolExecutionResult(
            ok: ok, status: status, message: message,
            resultPayload: resultPayload, rttMilliseconds: rttMs
        )

        if ok {
            diagnostics.recordSuccess(command: entry.meta.command, rttMs: rttMs)
        } else {
            diagnostics.recordFailure(command: entry.meta.command, status: status, rttMs: rttMs)
        }

        toolLogger.info("androidTool: result ok=\(ok) status=\(status, privacy: .public) rtt=\(rttMs)ms")
        entry.cont.resume(returning: result)
    }

    // MARK: - Clear on reconnect

    /// Resolve all pending continuations as `.timeout` and discard them.
    ///
    /// Call this when:
    /// - The daemon restarts (pending requests can never resolve)
    /// - Android reconnects (its execution context was reset)
    /// - Mac app reconnects to daemon (stale correlationIds)
    ///
    /// This prevents orphaned `CheckedContinuation` leaks and ensures callers
    /// get a fast error rather than hanging for the full `timeoutSeconds`.
    func clearPending(reason: OrchestrationClearReason) {
        let dropped = pending.count
        guard dropped > 0 else { return }

        toolLogger.warning("androidTool: clearPending reason=\(reason.rawValue, privacy: .public) clearing \(dropped) pending requests")

        let snapshot = pending
        pending.removeAll()
        diagnostics.updatePendingCount(0)
        diagnostics.recordClear(reason: reason, droppedCount: dropped)

        for (routeId, entry) in snapshot {
            toolLogger.debug("androidTool: clearing routeId=\(routeId, privacy: .public) command=\(entry.meta.command, privacy: .public)")
            entry.cont.resume(returning: ToolExecutionResult(
                ok: false, status: "timeout",
                message: "Request cancelled: \(reason.rawValue). Android or daemon was restarted.",
                resultPayload: [:], rttMilliseconds: nil
            ))
        }
    }

    /// Current number of in-flight requests (for diagnostics).
    var pendingCount: Int { pending.count }

    // MARK: - Private helpers

    private func timeoutPending(routeId: String, command: String, startedAt: Date) {
        guard let entry = pending.removeValue(forKey: routeId) else {
            // Already resolved by handleResult — this is the happy path
            return
        }
        let rttMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        diagnostics.updatePendingCount(pending.count)
        diagnostics.recordFailure(command: command, status: "timeout", rttMs: rttMs)
        toolLogger.warning("androidTool: timeout command=\(command, privacy: .public) routeId=\(routeId, privacy: .public) after \(rttMs)ms")
        entry.cont.resume(returning: ToolExecutionResult(
            ok: false, status: "timeout",
            message: "Android device did not respond within \(Int(timeoutSeconds)) seconds.",
            resultPayload: [:], rttMilliseconds: rttMs
        ))
    }

    private func buildEnvelope(
        command: String,
        params: [String: Any],
        targetDeviceId: String?,
        routeId: String
    ) -> [String: Any] {
        var target: [String: Any] = ["type": "android"]
        if let did = targetDeviceId { target["deviceId"] = did }

        var payload: [String: Any] = ["command": command]
        if !params.isEmpty { payload["params"] = params }

        return [
            "id"            : routeId,
            "type"          : "execution.request",
            "sourceDeviceId": "mac",
            "sourcePlatform": "mac",
            "target"        : target,
            "timestamp"     : ISO8601DateFormatter().string(from: Date()),
            "correlationId" : routeId,
            "payload"       : payload,
        ]
    }
}
