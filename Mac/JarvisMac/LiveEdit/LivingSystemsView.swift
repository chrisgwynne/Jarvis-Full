import SwiftUI

// MARK: - LivingSystemsView

/// Situation Room — Live Runtime panel. Shows the full editable runtime (not
/// just Heartbeat): every living system, the current pulse, recent edits, and a
/// one-tap rollback. Reads `@Observable` singletons directly, so it refreshes
/// live whenever a system changes.
///
/// Self-contained: presenting it is a follow-up wiring step (add a `.livingSystems`
/// OverlayKind). The data layer it renders is fully live today.
struct LivingSystemsView: View {

    private var registry: LivingSystemRegistry { .shared }
    private var audit: LiveEditAuditLog { .shared }
    private var heartbeat: HeartbeatStore { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                pulseSection
                Divider()
                livingSystemsSection
                Divider()
                recentEditsSection

                if !registry.all().isEmpty {
                    Button("Rollback last edit") {
                        _ = LiveEditEngine.shared.rollbackLast()
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
                }
            }
            .padding(20)
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Situation Room")
                .font(.title2).bold()
            Text("Live runtime · \(registry.all().count) editable systems")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var pulseSection: some View {
        let s = heartbeat.state
        return VStack(alignment: .leading, spacing: 6) {
            Text("Current State").font(.headline)
            row("Focus", s.currentFocus ?? "—")
            row("Active project", s.activeProject ?? "—")
            row("Open issues", s.openIssues.isEmpty ? "none" : "\(s.openIssues.count)")
            row("Blockers", s.blockers.isEmpty ? "none" : "\(s.blockers.count)")
            row("Recent wins", s.recentWins.isEmpty ? "none" : "\(s.recentWins.count)")
        }
    }

    private var livingSystemsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Living Systems").font(.headline)
            ForEach(registry.all(), id: \.id.rawValue) { sys in
                HStack {
                    Text(sys.displayName)
                    Spacer()
                    if sys.isProtected {
                        Text("protected").font(.caption).foregroundStyle(.orange)
                    } else {
                        Text("editable").font(.caption).foregroundStyle(.green)
                    }
                }
            }
        }
    }

    private var recentEditsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent Edits").font(.headline)
            let recent = audit.recent(limit: 8)
            if recent.isEmpty {
                Text("No changes yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(recent) { entry in
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(entry.systemID) · \(entry.action)")
                            .font(.caption).bold()
                        Text(entry.summary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.callout)
    }
}
