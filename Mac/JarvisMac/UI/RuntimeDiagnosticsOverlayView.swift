import SwiftUI

// MARK: - RuntimeDiagnosticsOverlayView

/// Developer-only overlay showing the health of every registered RuntimeSubsystem,
/// live EventStore throughput, and the current TaskThread.
struct RuntimeDiagnosticsOverlayView: View {

    @State private var refreshTick: Int = 0
    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                readinessHeader
                subsystemGrid
                eventThroughput
                taskThreadSection
                contextGraphSection
            }
            .padding(16)
        }
        .onReceive(timer) { _ in refreshTick &+= 1 }
        .background(Color.black.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Readiness header

    @MainActor
    private var readinessHeader: some View {
        HStack(spacing: 10) {
            let coord = RuntimeCoordinator.shared
            Circle()
                .fill(readinessColor(coord.readiness))
                .frame(width: 12, height: 12)
            Text("Runtime: \(coord.readiness.displayName)")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
            Spacer()
            Text("Subsystems: \(coord.subsystems.count)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    // MARK: - Subsystem grid

    @MainActor
    private var subsystemGrid: some View {
        let coord = RuntimeCoordinator.shared
        return VStack(alignment: .leading, spacing: 4) {
            Text("SUBSYSTEMS")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.bottom, 2)

            ForEach(coord.sortedSubsystems, id: \.id) { subsystem in
                subsystemRow(subsystem, coord: coord)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @MainActor
    private func subsystemRow(_ subsystem: any RuntimeSubsystem, coord: RuntimeCoordinator) -> some View {
        HStack(spacing: 8) {
            Text(subsystem.state.icon)
                .font(.system(size: 12))
            Text(subsystem.displayName)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
            if let restarts = coord.restartCounts[subsystem.id], restarts > 0 {
                Text("↺\(restarts)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.orange)
            }
            if let health = coord.lastHealthSnapshot[subsystem.id],
               let reason = health.reason {
                Text(reason.prefix(30))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.yellow.opacity(0.7))
                    .lineLimit(1)
            }
            Text(stateLabel(subsystem.state))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(stateColor(subsystem.state))
        }
    }

    // MARK: - Event throughput

    private var eventThroughput: some View {
        let throughput = EventStore.shared.throughput(windowSeconds: 60)
        let total = throughput.values.reduce(0, +)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("EVENTS / 60s")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                Spacer()
                Text("\(total) total · \(EventStore.shared.count) buffered")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.bottom, 2)

            let sorted = throughput.sorted { $0.value > $1.value }
            ForEach(sorted, id: \.key.rawValue) { category, count in
                HStack(spacing: 6) {
                    Text(category.rawValue)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 90, alignment: .leading)
                    GeometryReader { geo in
                        let maxCount = sorted.first?.value ?? 1
                        RoundedRectangle(cornerRadius: 2)
                            .fill(categoryColor(category))
                            .frame(width: geo.size.width * CGFloat(count) / CGFloat(max(maxCount, 1)))
                    }
                    .frame(height: 10)
                    Text("\(count)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 28, alignment: .trailing)
                }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Task thread section

    private var taskThreadSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ACTIVE TASK")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.bottom, 2)

            let engine = TaskThreadEngine()
            if let thread = engine.currentThread {
                VStack(alignment: .leading, spacing: 3) {
                    Text(thread.title)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                    HStack(spacing: 8) {
                        Text("Apps: \(thread.apps.prefix(3).joined(separator: ", "))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.5))
                        Spacer()
                        Text("conf: \(String(format: "%.0f%%", thread.confidence * 100))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.cyan.opacity(0.7))
                    }
                    if !thread.errors.isEmpty {
                        Text("⚠️ \(thread.errors.first ?? "")")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                }
            } else {
                Text("No active thread")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Context graph section

    @MainActor
    private var contextGraphSection: some View {
        let diag = ProjectRelationshipIndex.shared.diagnostics
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("CONTEXT GRAPH")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                Spacer()
                if let t = diag.lastIngestionAt {
                    let s = Int(Date().timeIntervalSince(t))
                    Text(s < 60 ? "ingested \(s)s ago" : "ingested \(s / 60)m ago")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
            .padding(.bottom, 2)

            HStack(spacing: 16) {
                statChip(label: "nodes", value: "\(diag.nodeCount)", color: .cyan)
                statChip(label: "edges", value: "\(diag.edgeCount)", color: .indigo)
                statChip(label: "chain", value: "\(diag.activeContinuityChainLength)", color: .teal)
            }

            if let project = diag.topActiveProject {
                Text("Top project: \(project)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
            }

            let topSources = diag.contextBudgetBySource
                .sorted { $0.value > $1.value }
                .prefix(4)
            if !topSources.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(topSources, id: \.key) { source, chars in
                        HStack(spacing: 6) {
                            Text(source)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.5))
                                .frame(width: 120, alignment: .leading)
                            Text("\(chars) chars")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.35))
                        }
                    }
                }
            }

            // Persistence status
            Text(diag.persistenceOneLiner)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(diag.persistedGraphLoaded ? Color.green.opacity(0.6) : Color.yellow.opacity(0.5))

            // Focus state (Sprint V — hysteresis-stable project ranking)
            Text(diag.focusOneLiner)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(diag.focusConfidence > 0 ? Color.cyan.opacity(0.6) : Color.white.opacity(0.25))

            // Cap utilisation + safe-mode indicator
            let nodePct = diag.nodeCap > 0 ? Int(Double(diag.nodeCount) / Double(diag.nodeCap) * 100) : 0
            let edgePct = diag.edgeCap > 0 ? Int(Double(diag.edgeCount) / Double(diag.edgeCap) * 100) : 0
            let sizeKB  = diag.estimatedGraphBytes / 1024
            let safeModeTag = diag.graphSafeMode ? " ⚠ SAFE MODE" : ""
            Text("cap: \(diag.nodeCount)/\(diag.nodeCap) nodes (\(nodePct)%) · \(diag.edgeCount)/\(diag.edgeCap) edges (\(edgePct)%) · ~\(sizeKB)KB\(safeModeTag)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(diag.graphSafeMode ? Color.orange.opacity(0.9) : .white.opacity(0.35))

            // Refresh timing
            if diag.lastRefreshDuration > 0 {
                let ms = Int(diag.lastRefreshDuration * 1000)
                Text("last refresh: \(ms)ms")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(ms > 500 ? Color.orange.opacity(0.7) : Color.white.opacity(0.25))
            }

            if diag.nodeCount == 0 {
                Text("No nodes yet — refresh to ingest")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.25))
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func statChip(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    // MARK: - Helpers

    private func readinessColor(_ state: ReadinessState) -> Color {
        switch state {
        case .ready:    return .green
        case .degraded: return .orange
        case .booting:  return .yellow
        case .failed:   return .red
        }
    }

    private func stateLabel(_ state: RuntimeState) -> String {
        state.rawValue
    }

    private func stateColor(_ state: RuntimeState) -> Color {
        switch state {
        case .running:  return .green
        case .degraded: return .orange
        case .failed:   return .red
        case .starting: return .yellow
        case .stopped:  return .gray
        }
    }

    private func categoryColor(_ category: SystemEventCategory) -> Color {
        switch category {
        case .app:         return .blue
        case .screen:      return .teal
        case .speech:      return .purple
        case .overlay:     return .indigo
        case .memory:      return .cyan
        case .proactivity: return .orange
        case .device:      return .yellow
        case .ci:          return .red
        case .system:      return .green
        case .privacy:     return .pink
        }
    }
}
