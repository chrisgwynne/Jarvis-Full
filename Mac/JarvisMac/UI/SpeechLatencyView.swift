import SwiftUI

/// Diagnostics overlay: last 20 speech turns with per-stage timings,
/// p50/p95, route breakdown, and STT vs TTS comparison.
/// Triggered by "show speech latency" / "latency diagnostics".
struct SpeechLatencyView: View {
    @State private var traces: [SpeechTurnTrace] = []
    private let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Color.orange.opacity(0.3))
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    summarySection
                    routeSection
                    stageComparisonSection
                    Divider().overlay(Color.white.opacity(0.1))
                    turnListSection
                }
                .padding(12)
            }
        }
        .background(Color.black.opacity(0.9))
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.white.opacity(0.9))
        .onReceive(refreshTimer) { _ in reload() }
        .onAppear { reload() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "timer")
                .foregroundStyle(.orange)
            Text("SPEECH LATENCY")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.orange)
            Spacer()
            Text("\(traces.count) turns")
                .foregroundStyle(.white.opacity(0.5))
                .font(.system(size: 10, design: .monospaced))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Summary

    private var summarySection: some View {
        let store = SpeechTurnStore.shared
        return VStack(alignment: .leading, spacing: 4) {
            Text("SUMMARY").sectionTitle
            HStack(spacing: 16) {
                statBox("avg",  msLabel(store.averageTotalMs()))
                statBox("p50",  msLabel(store.p50()))
                statBox("p95",  msLabel(store.p95()))
            }
        }
    }

    // MARK: - Route breakdown

    private var routeSection: some View {
        let breakdown = SpeechTurnStore.shared.routeBreakdown()
        let total = max(1, breakdown.values.reduce(0, +))
        return VStack(alignment: .leading, spacing: 4) {
            Text("ROUTE BREAKDOWN").sectionTitle
            ForEach(TurnRoute.allCases, id: \.self) { route in
                let count = breakdown[route, default: 0]
                if count > 0 {
                    HStack(spacing: 6) {
                        routeDot(route)
                        Text(route.rawValue).frame(width: 110, alignment: .leading)
                        Text("\(count) (\(Int(Double(count) / Double(total) * 100))%)")
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
        }
    }

    // MARK: - Stage comparison

    private var stageComparisonSection: some View {
        let store = SpeechTurnStore.shared
        let sttAvg = store.averageMs(for: \.sttMs)
        let intentAvg = store.averageMs(for: \.intentMs)
        let llmAvg = store.averageMs(for: \.llmMs)
        let ttsAvg = store.averageMs(for: \.ttsMs)
        let loggerAvg = store.averageMs(for: \.replyLoggerMs)
        return VStack(alignment: .leading, spacing: 4) {
            Text("AVG STAGE TIMES").sectionTitle
            stageRow("STT",         sttAvg,    budget: 1500)
            stageRow("intent",      intentAvg, budget: 50)
            stageRow("LLM",         llmAvg,    budget: 800)
            stageRow("TTS",         ttsAvg,    budget: 200)
            stageRow("replyLogger", loggerAvg, budget: 5)
        }
    }

    // MARK: - Turn list

    private var turnListSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("RECENT TURNS").sectionTitle
            if traces.isEmpty {
                Text("No turns recorded yet.")
                    .foregroundStyle(.white.opacity(0.4))
            } else {
                ForEach(traces.prefix(20)) { trace in
                    TurnRowView(trace: trace)
                }
            }
        }
    }

    // MARK: - Helpers

    private func reload() { traces = SpeechTurnStore.shared.recentTraces() }

    private func msLabel(_ ms: Double?) -> String {
        guard let ms else { return "—" }
        return String(format: "%.0fms", ms)
    }

    private func statBox(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundStyle(.orange)
            Text(label)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(minWidth: 60)
    }

    private func routeDot(_ route: TurnRoute) -> some View {
        Circle()
            .fill(routeColor(route))
            .frame(width: 6, height: 6)
    }

    private func routeColor(_ route: TurnRoute) -> Color {
        switch route {
        case .fastCommand:   return .green
        case .directCommand: return .mint
        case .llmFallback:   return .yellow
        case .llmWithTool:   return .orange
        case .unknown:       return .gray
        }
    }

    private func stageRow(_ name: String, _ ms: Double?, budget: Double) -> some View {
        HStack {
            Text(name).frame(width: 80, alignment: .leading)
            if let ms {
                let over = ms > budget
                Text(String(format: "%.0fms", ms))
                    .foregroundStyle(over ? .red : .green)
                if over {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.system(size: 9))
                }
            } else {
                Text("—").foregroundStyle(.white.opacity(0.3))
            }
        }
    }
}

// MARK: - TurnRowView

private struct TurnRowView: View {
    let trace: SpeechTurnTrace
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                routeBadge
                if let total = trace.totalMs {
                    Text(String(format: "%.0fms", total))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(total > 2000 ? .red : .white)
                }
                if trace.llmUsed { tag("LLM", .yellow) }
                if trace.toolUsed { tag("TOOL", .orange) }
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }

            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    detailRow("stt",         trace.sttMs)
                    detailRow("intent",      trace.intentMs)
                    detailRow("llm",         trace.llmMs)
                    detailRow("llm_1st_tok", trace.llmFirstTokenMs)
                    detailRow("tool",        trace.toolMs)
                    detailRow("tts",         trace.ttsMs)
                    detailRow("replyLogger", trace.replyLoggerMs)
                    if let (stage, ms) = trace.slowestStage {
                        Text("slowest: \(stage) (\(String(format: "%.0f", ms))ms)")
                            .foregroundStyle(.red.opacity(0.8))
                    }
                    if trace.transcriptLength > 0 {
                        Text("transcript: \(trace.transcriptLength) chars → reply: \(trace.replyLength) chars")
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
                .padding(.leading, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
    }

    private var routeBadge: some View {
        Text(trace.route.rawValue.replacingOccurrences(of: "_", with: " "))
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(routeBadgeColor.opacity(0.2))
            .foregroundStyle(routeBadgeColor)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var routeBadgeColor: Color {
        switch trace.route {
        case .fastCommand, .directCommand: return .green
        case .llmFallback: return .yellow
        case .llmWithTool: return .orange
        case .unknown: return .gray
        }
    }

    private func tag(_ label: String, _ color: Color) -> some View {
        Text(label)
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 2))
    }

    private func detailRow(_ label: String, _ ms: Double?) -> some View {
        guard let ms, ms > 0 else { return AnyView(EmptyView()) }
        return AnyView(
            HStack {
                Text(label).frame(width: 80, alignment: .leading).foregroundStyle(.white.opacity(0.5))
                Text(String(format: "%.1fms", ms)).foregroundStyle(.white.opacity(0.8))
            }
            .font(.system(size: 10, design: .monospaced))
        )
    }
}

// MARK: - Text extension

private extension Text {
    var sectionTitle: some View {
        self.font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.4))
            .padding(.bottom, 2)
    }
}
