import SwiftUI

/// Live diagnostics panel for the distributed Jarvis execution pipeline.
///
/// Shown in Settings → Mac Brain API → Distributed Diagnostics.
/// Auto-refreshes every 2 seconds via a Timer so numbers stay current
/// without requiring @Observable access into daemon internals.
struct DistributedDiagnosticsView: View {

    @State private var snapshot = DiagnosticsSnapshot()
    @State private var refreshTimer: Timer? = nil
    @State private var showDeveloperDetail = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // ── Connected devices ────────────────────────────────────────
                GroupBox("Connected Devices") {
                    VStack(alignment: .leading, spacing: 4) {
                        row("Android clients",   value: "\(snapshot.androidClientCount)",
                            color: snapshot.androidClientCount > 0 ? .green : .secondary)
                        row("Windows clients",   value: "\(snapshot.windowsClientCount)",
                            color: snapshot.windowsClientCount > 0 ? .blue : .secondary)
                        row("Mac sessions",      value: "\(snapshot.macClientCount)",
                            color: snapshot.macClientCount > 0 ? .mint : .secondary)
                    }
                    .font(.system(.body, design: .monospaced))
                }

                // ── Execution pipeline ───────────────────────────────────────
                GroupBox("Execution Pipeline") {
                    VStack(alignment: .leading, spacing: 4) {
                        row("Pending continuations", value: "\(snapshot.pendingCount)",
                            color: snapshot.pendingCount > 0 ? .orange : .primary)
                        row("Peak pending",          value: "\(snapshot.pendingPeak)")
                        row("Successes",             value: "\(snapshot.successCount)", color: .green)
                        row("Failures",              value: "\(snapshot.failureCount)", color: .red)
                        row("Timeouts",              value: "\(snapshot.timeoutCount)", color: .orange)
                        row("Stale result drops",    value: "\(snapshot.staleResultDropCount)")
                        row("Duplicate routeId",     value: "\(snapshot.duplicateRouteIdCount)")
                        if snapshot.pendingClearCount > 0 {
                            row("Pending clears", value: "\(snapshot.pendingClearCount)",
                                color: .yellow)
                            row("Last clear reason", value: snapshot.lastClearReason)
                        }
                    }
                    .font(.system(.body, design: .monospaced))
                }

                // ── Latency ──────────────────────────────────────────────────
                GroupBox("Round-Trip Latency (execution.request → execution.result)") {
                    VStack(alignment: .leading, spacing: 4) {
                        row("p50 RTT",  value: "\(snapshot.p50RttMs) ms",
                            color: rttColor(snapshot.p50RttMs))
                        row("p95 RTT",  value: "\(snapshot.p95RttMs) ms",
                            color: rttColor(snapshot.p95RttMs))
                        row("Average",  value: "\(snapshot.avgRttMs) ms")
                        row("Last",     value: "\(snapshot.lastRttMs) ms")
                        row("Last command",  value: snapshot.lastCommand)
                        row("Last status",   value: snapshot.lastStatus,
                            color: snapshot.lastStatus == "ok" ? .green : .red)
                    }
                    .font(.system(.body, design: .monospaced))
                }

                // ── Confirmation flow ────────────────────────────────────────
                GroupBox("Confirmation Gate") {
                    VStack(alignment: .leading, spacing: 4) {
                        row("Requested",  value: "\(snapshot.confirmRequested)")
                        row("Granted",    value: "\(snapshot.confirmGranted)",  color: .green)
                        row("Rejected",   value: "\(snapshot.confirmRejected)", color: .red)
                        row("Timed out",  value: "\(snapshot.confirmTimedOut)", color: .orange)
                        row("Cap-rejected", value: "\(snapshot.confirmCapRejected)", color: .orange)
                        row("Dedup-rejected", value: "\(snapshot.confirmDedupRejected)")
                    }
                    .font(.system(.body, design: .monospaced))
                }

                // ── Offline queue ────────────────────────────────────────────
                GroupBox("Offline Queue") {
                    VStack(alignment: .leading, spacing: 4) {
                        row("Queue depth",         value: "\(snapshot.queueDepth)",
                            color: snapshot.queueDepth > 0 ? .yellow : .primary)
                        row("Dropped (overflow)",  value: "\(snapshot.queueDropped)")
                        row("Replay-unsafe drops", value: "\(snapshot.queueReplayUnsafeDropped)")
                        row("Expired evicted",     value: "\(snapshot.queueExpiredEvicted)")
                    }
                    .font(.system(.body, design: .monospaced))
                }

                // ── Daemon routing ───────────────────────────────────────────
                GroupBox("Daemon Router") {
                    VStack(alignment: .leading, spacing: 4) {
                        row("Routed total",    value: "\(snapshot.routedMessages)")
                        row("NACK sent",       value: "\(snapshot.nackCount)", color: snapshot.nackCount > 0 ? .orange : .primary)
                        row("Brain unavailable", value: "\(snapshot.brainUnavailable)")
                        row("Malformed drops", value: "\(snapshot.malformed)", color: snapshot.malformed > 0 ? .red : .primary)
                        row("Oversized drops", value: "\(snapshot.oversized)",  color: snapshot.oversized > 0 ? .red : .primary)
                        row("Unknown ignored", value: "\(snapshot.unknownIgnored)")
                        row("Last type seen",  value: snapshot.lastMessageType)
                        if snapshot.deprecatedTypeCount > 0 {
                            row("Deprecated type uses", value: "\(snapshot.deprecatedTypeCount)", color: .yellow)
                        }
                    }
                    .font(.system(.body, design: .monospaced))
                }

                // ── Developer detail toggle ──────────────────────────────────
                DisclosureGroup("Developer Detail", isExpanded: $showDeveloperDetail) {
                    VStack(alignment: .leading, spacing: 6) {

                        Text("Contract version: execution.* canonical (tool.result/command.result deprecated)")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let androidAt = snapshot.lastAndroidMessageAt {
                            row("Last Android msg", value: relativeTime(androidAt))
                        }
                        if let macAt = snapshot.lastMacAppMessageAt {
                            row("Last Mac app msg", value: relativeTime(macAt))
                        }
                        if let windowsAt = snapshot.lastWindowsMessageAt {
                            row("Last Windows msg", value: relativeTime(windowsAt))
                        }

                        Divider()

                        Text("Replay safety rules: execution.request is NEVER queued (destructive). " +
                             "execution.result queued up to 120s when Mac offline.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 4)
                }

                Spacer(minLength: 20)
            }
            .padding()
        }
        .onAppear { startTimer() }
        .onDisappear { stopTimer() }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private func row(_ label: String, value: String, color: Color = .primary) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(minWidth: 200, alignment: .leading)
            Spacer()
            Text(value)
                .foregroundStyle(color)
                .bold(color != .primary && color != .secondary)
        }
    }

    // MARK: - Timer

    private func startTimer() {
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor in refresh() }
        }
    }

    private func stopTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    @MainActor
    private func refresh() {
        snapshot = DiagnosticsSnapshot.current()
    }

    // MARK: - Helpers

    private func rttColor(_ ms: Int) -> Color {
        switch ms {
        case 0: return .secondary
        case 1..<500: return .green
        case 500..<1500: return .yellow
        default: return .red
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let secs = Int(-date.timeIntervalSinceNow)
        if secs < 60 { return "\(secs)s ago" }
        return "\(secs / 60)m ago"
    }
}

// MARK: - Snapshot model (MainActor-safe read at refresh time)

@MainActor
private struct DiagnosticsSnapshot {
    // Devices
    var androidClientCount: Int = 0
    var windowsClientCount: Int = 0
    var macClientCount: Int = 0

    // Execution
    var pendingCount: Int = 0
    var pendingPeak: Int = 0
    var successCount: Int = 0
    var failureCount: Int = 0
    var timeoutCount: Int = 0
    var staleResultDropCount: Int = 0
    var duplicateRouteIdCount: Int = 0
    var pendingClearCount: Int = 0
    var lastClearReason: String = ""

    // Latency
    var p50RttMs: Int = 0
    var p95RttMs: Int = 0
    var avgRttMs: Int = 0
    var lastRttMs: Int = 0
    var lastCommand: String = ""
    var lastStatus: String = ""

    // Confirmation
    var confirmRequested: Int = 0
    var confirmGranted: Int = 0
    var confirmRejected: Int = 0
    var confirmTimedOut: Int = 0
    var confirmCapRejected: Int = 0
    var confirmDedupRejected: Int = 0

    // Offline queue
    var queueDepth: Int = 0
    var queueDropped: Int = 0
    var queueReplayUnsafeDropped: Int = 0
    var queueExpiredEvicted: Int = 0

    // Daemon router
    var routedMessages: Int = 0
    var nackCount: Int = 0
    var brainUnavailable: Int = 0
    var malformed: Int = 0
    var oversized: Int = 0
    var unknownIgnored: Int = 0
    var lastMessageType: String = ""
    var deprecatedTypeCount: Int = 0

    // Timestamps
    var lastAndroidMessageAt: Date? = nil
    var lastMacAppMessageAt: Date? = nil
    var lastWindowsMessageAt: Date? = nil

    static func current() -> DiagnosticsSnapshot {
        var s = DiagnosticsSnapshot()

        // Orchestrator diagnostics
        let od = AndroidToolOrchestratorDiagnostics.shared
        s.pendingCount           = AndroidToolOrchestrator.shared.pendingCount
        s.pendingPeak            = od.pendingCapPeak
        s.successCount           = od.successCount
        s.failureCount           = od.failureCount
        s.timeoutCount           = od.timeoutCount
        s.staleResultDropCount   = od.staleResultDropCount
        s.duplicateRouteIdCount  = od.duplicateRouteIdCount
        s.pendingClearCount      = od.clearCount
        s.lastClearReason        = od.lastClearReason
        s.p50RttMs               = od.p50RttMs
        s.p95RttMs               = od.p95RttMs
        s.avgRttMs               = od.averageRttMs
        s.lastRttMs              = od.lastRttMs
        s.lastCommand            = od.lastCommand
        s.lastStatus             = od.lastStatus

        // Offline queue
        s.queueDepth             = DaemonOfflineQueue.shared.depth

        return s
    }
}

// MARK: - Preview

#Preview {
    DistributedDiagnosticsView()
        .frame(width: 520, height: 700)
}
