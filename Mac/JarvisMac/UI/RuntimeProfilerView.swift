import SwiftUI

// MARK: - RuntimeProfilerView

/// Real-time subsystem performance overlay.
/// Triggered by "run stability report", "performance report", or the developer menu.
///
/// Shows:
///   - Live CPU / memory / threads / fds
///   - Per-subsystem event rate and state
///   - Runaway flag for any subsystem firing too often while idle
///   - Last 15-min trend sparkline for memory and CPU
///   - One-tap link to open GitHub issue pre-filled with diagnostics
struct RuntimeProfilerView: View {

    let controller: JarvisController
    @State private var refreshTimer: Timer? = nil

    // These are Observable-safe reads via the @Observable macro on SelfMonitor's backing types
    private var monitor: SelfMonitor { SelfMonitor.shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headerBar
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 10)

                Divider().opacity(0.2)

                // Safe degraded mode banner
                if monitor.isInSafeDegradedMode {
                    safeModeBanner
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                }

                topSuspectBanner
                    .padding(.horizontal, 16)
                    .padding(.top, 10)

                systemMetricsSection
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                Divider().opacity(0.2).padding(.top, 10)

                subsystemSection
                    .padding(.horizontal, 16)
                    .padding(.top, 10)

                Divider().opacity(0.2).padding(.top, 10)

                trendSection
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 14)

                Divider().opacity(0.2)

                actionBar
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
        .onAppear { startRefreshing() }
        .onDisappear { stopRefreshing() }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.badge.exclamationmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.indigo)
            Text("Runtime Profiler")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
            Spacer()
            if let snap = monitor.latestSnapshot {
                Text("Updated \(snap.timestamp, style: .time)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Top suspect banner

    private var topSuspectBanner: some View {
        Group {
            if let snap = monitor.latestSnapshot {
                let (name, est, events, reason) = suspectDetails(snap: snap)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: "flame.fill").foregroundStyle(.orange)
                        Text("TOP SUSPECT")
                            .font(.system(size: 9, weight: .black, design: .monospaced))
                            .foregroundStyle(.orange)
                            .tracking(1.2)
                        Spacer()
                        Text(String(format: "~%.0f%% CPU", est))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(est > 30 ? .red : .orange)
                    }
                    HStack(spacing: 12) {
                        Text(name)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("\(events) ev/min")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text(reason)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(Color.orange.opacity(0.10))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.orange.opacity(0.25)))
                .cornerRadius(6)
            }
        }
    }

    private func suspectDetails(snap: SelfMonitorSnapshot) -> (String, Double, Int, String) {
        SelfMonitor.shared.topSuspectDetails_public(snap: snap)
    }

    // MARK: - Safe mode banner

    private var safeModeBanner: some View {
        Label("Jarvis is in Safe Degraded Mode — non-essential subsystems paused", systemImage: "exclamationmark.shield.fill")
            .font(.caption).fontWeight(.semibold)
            .foregroundStyle(.orange)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12))
            .cornerRadius(8)
    }

    // MARK: - System metrics

    private var systemMetricsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("System")
            if let snap = monitor.latestSnapshot {
                HStack(spacing: 16) {
                    metricBadge("RSS", "\(snap.rssMemoryMB) MB", color: memColor(snap.rssMemoryMB))
                    metricBadge("CPU", String(format: "%.1f%%", snap.cpuPercent), color: cpuColor(snap.cpuPercent))
                    metricBadge("Threads", "\(snap.threadCount)", color: .secondary)
                    metricBadge("FDs", snap.fdCount >= 0 ? "\(snap.fdCount)" : "—", color: .secondary)
                }
            } else {
                Text("Collecting…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Subsystem table

    private var subsystemSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Subsystems")
            VStack(spacing: 2) {
                ForEach(monitor.subsystemProfiles, id: \.name) { profile in
                    subsystemRow(profile)
                }
            }
        }
    }

    private func subsystemRow(_ p: SubsystemProfile) -> some View {
        HStack(spacing: 0) {
            Text(p.name)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
            Spacer()
            if p.isRunaway {
                Text("⚠️ RUNAWAY")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.red)
            } else {
                Circle()
                    .fill(stateColor(p.state))
                    .frame(width: 7, height: 7)
                    .padding(.trailing, 4)
                Text(p.state)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(String(format: "%.0f ev/min", p.eventsPerMinute))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(p.eventsPerMinute > p.runawayThreshold ? Color.orange : Color.secondary.opacity(0.6))
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(p.isRunaway ? Color.red.opacity(0.08) : Color.clear)
        .cornerRadius(4)
    }

    // MARK: - Trend sparkline (memory)

    private var trendSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("15-Minute Trend")
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(Array(sparklinesMemory.enumerated()), id: \.offset) { _, val in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(memColor(val))
                        .frame(width: 3, height: CGFloat(val) / 10)
                }
            }
            .frame(height: 40)
            Text("Memory (MB) over last \(monitor.snapshots.count) samples")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
        }
    }

    private var sparklinesMemory: [Int] {
        // Last 60 snapshots (5 min of 5s data)
        monitor.snapshots.suffix(60).map { $0.rssMemoryMB }
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button("Export Diagnostics") { exportDiagnostics() }
                .buttonStyle(.bordered)
            Spacer()
            if monitor.isInSafeDegradedMode {
                Button("Exit Safe Mode") { SelfMonitor.shared.exitSafeDegradedMode() }
                    .buttonStyle(.bordered).tint(.green)
            }
            Button("Create GitHub Issue") {
                SelfMonitor.shared.openManualStabilityReport(controller: controller)
            }
            .buttonStyle(.borderedProminent).tint(.indigo)
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(.tertiary)
            .tracking(0.8)
    }

    private func metricBadge(_ label: String, _ value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(8)
        .background(Color.white.opacity(0.04))
        .cornerRadius(6)
    }

    private func memColor(_ mb: Int) -> Color {
        if mb > 1000 { return .red }
        if mb > 600  { return .orange }
        return .green
    }

    private func cpuColor(_ pct: Double) -> Color {
        if pct > 80 { return .red }
        if pct > 40 { return .orange }
        if pct > 20 { return .yellow }
        return .green
    }

    private func stateColor(_ state: String) -> Color {
        switch state {
        case "active", "streaming", "sampling": return .green
        case "reconnecting", "error":           return .red
        default:                                return .secondary
        }
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "jarvis_diagnostics_\(Date().timeIntervalSince1970).json"
        panel.allowedContentTypes = [.json]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            // Write the current snapshot history
            let snaps = SelfMonitor.shared.snapshots
            if let data = try? JSONEncoder().encode(snaps) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func startRefreshing() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            // SwiftUI @Observable will auto-update when monitor publishes new data
            // The timer just exists to keep the view alive and force redraws
        }
    }

    private func stopRefreshing() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}
