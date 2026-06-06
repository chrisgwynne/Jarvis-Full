import SwiftUI

// MARK: - CommandDashboardView

/// Modern command centre panel. Opens from the dock (☰ button).
///
/// Slides up from bottom. Fades out on dismiss.
/// Shows: greeting, live status, suggested actions, recent activity, system health.
struct CommandDashboardView: View {
    let state: AppState
    let controller: JarvisController
    @Binding var isVisible: Bool

    var body: some View {
        ZStack {
            // Scrim — tapping outside dismisses
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(JarvisMotion.normalEase) { isVisible = false }
                }

            VStack {
                Spacer()
                dashboardPanel
            }
        }
    }

    // MARK: - Panel

    private var dashboardPanel: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header ──────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 4) {
                Text("Jarvis")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .tracking(1.5)
                Text(greeting)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)

            dividerLine

            // ── Status ──────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("Status")
                statusRows
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            dividerLine

            // ── Suggested Actions ────────────────────────────────────────
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("Suggested Actions")
                suggestedActions
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            dividerLine

            // ── System Health ────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("System Health")
                healthRows
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 20)
        }
        .frame(width: 320)
        .background(panelBackground)
        .shadow(color: .black.opacity(0.50), radius: 40, x: 0, y: -8)
        .padding(.bottom, 90)      // clear the dock
    }

    // MARK: - Greeting

    private var greeting: String {
        let name = controller.prefs.current.userName.map { ", \($0)" } ?? ""
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12:  return "Good Morning\(name)"
        case 12..<17: return "Good Afternoon\(name)"
        case 17..<21: return "Good Evening\(name)"
        default:      return "Good Night\(name)"
        }
    }

    // MARK: - Status rows

    @ViewBuilder
    private var statusRows: some View {
        statusRow(dot: state.phase.accentColor,
                  label: "Assistant",
                  value: state.phase.shortLabel)
        statusRow(dot: brainColor,
                  label: "Intelligence",
                  value: brainStatus)
        statusRow(dot: state.cameraStatus.isHealthy ? .green : .orange,
                  label: "Cameras",
                  value: state.cameraStatus.isHealthy ? "Active" : "Unavailable")
        if state.isOffline {
            statusRow(dot: .green, label: "Network", value: "Local Only")
        }
    }

    private var brainColor: Color {
        state.wakeWordStatus.isHealthy && state.microphoneStatus.isHealthy ? .green : .orange
    }

    private var brainStatus: String {
        guard state.wakeWordStatus.isHealthy else { return "Wake Word Offline" }
        guard state.microphoneStatus.isHealthy else { return "Mic Unavailable" }
        return "Online"
    }

    private func statusRow(dot: Color, label: String, value: String) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(dot)
                .frame(width: 6, height: 6)
                .shadow(color: dot.opacity(0.6), radius: 3)
            Text(label)
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Suggested actions

    private var suggestedActions: some View {
        FlowLayout(spacing: 8) {
            ForEach(actionChips, id: \.label) { chip in
                ActionChip(label: chip.label) {
                    withAnimation(JarvisMotion.normalEase) { isVisible = false }
                    Task { await controller.handleTranscript(chip.action) }
                }
            }
        }
    }

    private var actionChips: [(label: String, action: String)] {
        let hour = Calendar.current.component(.hour, from: Date())
        var chips: [(String, String)] = []

        if hour >= 6 && hour < 11 {
            chips.append(("Morning Briefing", "give me a morning briefing"))
        } else if hour >= 18 {
            chips.append(("Evening Summary", "give me an evening summary"))
        }

        chips.append(("Today's Schedule", "what's on my calendar today"))
        chips.append(("What's Changed", "what's changed today"))

        if controller.prefs.current.todoistAPIToken != nil {
            chips.append(("Today's Tasks", "show my tasks"))
        }
        if !(controller.prefs.current.smartHomeBaseURL ?? "").isEmpty {
            chips.append(("Home Status", "show home panel"))
        }
        if controller.prefs.current.shopifyAccessToken != nil {
            chips.append(("Recent Orders", "check recent orders"))
        }

        chips.append(("Open Cameras", "open cameras"))

        return Array(chips.prefix(6))
    }

    // MARK: - Health rows

    @ViewBuilder
    private var healthRows: some View {
        healthRow(icon: "waveform",     label: "Wake Word",  healthy: state.wakeWordStatus.isHealthy)
        healthRow(icon: "mic",          label: "Microphone", healthy: state.microphoneStatus.isHealthy)
        healthRow(icon: "camera",       label: "Camera",     healthy: state.cameraStatus.isHealthy)
        if let ms = state.latencyMillis["stt"], ms > 0 {
            HStack(spacing: 10) {
                Image(systemName: "timer")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text("STT Latency")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.0f ms", ms))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(ms < 500 ? Color.secondary : Color.orange)
            }
        }
    }

    private func healthRow(icon: String, label: String, healthy: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(healthy ? Color.secondary : Color.orange)
                .frame(width: 16)
            Text(label)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.secondary)
            Spacer()
            Text(healthy ? "OK" : "Check")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(healthy ? Color.secondary : Color.orange)
        }
    }

    // MARK: - Helpers

    private var dividerLine: some View {
        Rectangle()
            .fill(Color.white.opacity(0.07))
            .frame(height: 0.5)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.tertiary)
            .tracking(1.2)
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(.regularMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
            )
    }
}

// MARK: - ActionChip

private struct ActionChip: View {
    let label: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(isHovered ? Color.primary : Color.primary.opacity(0.80))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isHovered ? Color.white.opacity(0.11) : Color.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.09), lineWidth: 0.5)
                        )
                )
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(JarvisMotion.fastEase) { isHovered = h } }
    }
}

// MARK: - FlowLayout

/// Simple wrapping horizontal layout for action chips.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 280
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width && x > 0 {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxWidth = max(maxWidth, x - spacing)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
