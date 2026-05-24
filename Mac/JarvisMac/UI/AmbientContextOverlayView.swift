import SwiftUI
import AppKit

// MARK: - AmbientContextOverlayView

/// Developer/debug overlay for AmbientContextEngine state.
/// Shows live app tracking, semantic summary, watch mode status,
/// OCR confidence, and recent SystemBus events.
/// Hidden by default — open with "show ambient context" or from DevTools.
struct AmbientContextOverlayView: View {

    let engine: AmbientContextEngine
    @State private var events: [EventRow] = []
    @State private var refreshTick: Int = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                headerSection
                activeAppSection
                summarySection
                watchModeSection
                recentEventsSection
            }
            .padding(16)
        }
        .onAppear { refreshEvents() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            refreshEvents()
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        HStack {
            Label("Ambient Context Engine", systemImage: "eye.circle")
                .font(.headline)
                .foregroundColor(.white)
            Spacer()
            Circle()
                .fill(engine.isEnabled ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            Text(engine.isEnabled ? "Active" : "Paused")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var activeAppSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("Active App")
            let app = engine.context.activeApp
            if app.isEmpty {
                Text("Unknown").foregroundColor(.secondary)
            } else {
                Text(app.name).foregroundColor(.white).bold()
                if !app.bundleID.isEmpty {
                    Text(app.bundleID).font(.caption2).foregroundColor(.secondary)
                }
                if !app.windowTitle.isEmpty {
                    Text("↳ \(app.windowTitle)").font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.05))
        .cornerRadius(8)
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("Latest Summary")
            let s = engine.context.latestSummary
            if s.isEmpty {
                Text("No summary yet").foregroundColor(.secondary)
            } else {
                if s.isRedacted {
                    Label("Redacted — private app", systemImage: "lock.fill")
                        .foregroundColor(.orange)
                } else {
                    if !s.detectedTask.isEmpty {
                        Text(s.detectedTask).foregroundColor(.white)
                    }
                    if !s.visibleErrors.isEmpty {
                        ForEach(s.visibleErrors.prefix(3), id: \.self) { err in
                            Label(err.prefix(80).description, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                    if !s.visibleEntities.isEmpty {
                        Text("Entities: " + s.visibleEntities.prefix(5).joined(separator: ", "))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text(String(format: "Confidence: %.0f%%", s.confidence * 100))
                        Spacer()
                        if let at = engine.context.lastSummaryAt {
                            Text(relativeTime(at)).foregroundColor(.secondary)
                        }
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.05))
        .cornerRadius(8)
    }

    private var watchModeSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("Watch Mode")
            switch engine.context.watchMode {
            case .inactive:
                Text("Inactive").foregroundColor(.secondary)
            case .active(let started, let expires, let app):
                HStack {
                    Image(systemName: "eye.fill").foregroundColor(.orange)
                    Text("ACTIVE").foregroundColor(.orange).bold()
                }
                if let app { Text("Watching: \(app)").font(.caption) }
                Text("Expires: \(relativeTime(expires))").font(.caption).foregroundColor(.secondary)
                Text("Started: \(relativeTime(started))").font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.05))
        .cornerRadius(8)
    }

    private var recentEventsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("Recent SystemBus Events")
            if events.isEmpty {
                Text("No events yet").foregroundColor(.secondary)
            } else {
                ForEach(events.prefix(12)) { row in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(row.color)
                            .frame(width: 6, height: 6)
                        Text(row.label)
                            .font(.caption2)
                            .foregroundColor(.white)
                        Spacer()
                        Text(row.time)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.05))
        .cornerRadius(8)
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundColor(.secondary)
            .textCase(.uppercase)
    }

    private func refreshEvents() {
        events = SystemBus.shared.recentEvents
            .prefix(20)
            .map { event in
                EventRow(
                    id: event.id,
                    label: "\(event.category.rawValue).\(type(of: event))",
                    color: colorFor(category: event.category),
                    time: relativeTime(event.timestamp)
                )
            }
    }

    private func colorFor(category: SystemEventCategory) -> Color {
        switch category {
        case .app:         return .blue
        case .screen:      return .green
        case .speech:      return .yellow
        case .overlay:     return .purple
        case .memory:      return .orange
        case .proactivity: return .pink
        case .device:      return .cyan
        case .ci:          return .red
        case .system:      return .gray
        case .privacy:     return .orange
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "\(Int(interval))s ago" }
        if interval < 3600 { return "\(Int(interval/60))m ago" }
        return "\(Int(interval/3600))h ago"
    }

    // MARK: - Row model

    struct EventRow: Identifiable {
        let id: UUID
        let label: String
        let color: Color
        let time: String
    }
}
