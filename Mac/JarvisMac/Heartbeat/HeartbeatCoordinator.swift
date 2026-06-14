import Foundation

// MARK: - HeartbeatCoordinator

/// Keeps `HeartbeatStore` continuously up to date from live system signals.
///
/// Self-contained: it subscribes to the `SystemBus` and runs a low-frequency
/// refresh loop that pulls project focus and today's activity from existing
/// singletons. Nothing in `JarvisController` needs to change — start/stop is
/// owned by `BrainRuntime`, mirroring `EntityLifecycleCoordinator`.
///
/// Cheap by design: event handlers are O(1) string work, and the refresh loop
/// only reads already-computed state every `refreshInterval`.
@MainActor
final class HeartbeatCoordinator {

    static let shared = HeartbeatCoordinator()

    private let store: HeartbeatStore
    private var tokens: [SystemBus.SubscriptionToken] = []
    private var refreshLoop: Task<Void, Never>?

    private let refreshInterval: UInt64 = 30 * 1_000_000_000  // 30s

    init(store: HeartbeatStore = .shared) {
        self.store = store
    }

    // MARK: - Lifecycle

    func start() {
        guard tokens.isEmpty else { return }

        tokens.append(SystemBus.shared.subscribe(IntentResolvedEvent.self) { [weak self] event in
            self?.handleIntent(event)
        })
        tokens.append(SystemBus.shared.subscribe(ConversationStartedEvent.self) { [weak self] _ in
            self?.store.recordSessionStart()
        })
        tokens.append(SystemBus.shared.subscribe(ProactiveSignalGeneratedEvent.self) { [weak self] event in
            self?.handleProactive(event)
        })
        tokens.append(SystemBus.shared.subscribe(GitHubBuildFailedEvent.self) { [weak self] event in
            self?.handleBuildFailure(event)
        })

        // Seed once immediately, then refresh on a loop.
        refresh()
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self?.refreshInterval ?? 30_000_000_000)
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
        Log.app.info("[Heartbeat] coordinator started")
    }

    func stop() {
        refreshLoop?.cancel()
        refreshLoop = nil
        for token in tokens { SystemBus.shared.unsubscribe(token) }
        tokens.removeAll()
        Log.app.info("[Heartbeat] coordinator stopped")
    }

    // MARK: - Event handlers

    private func handleIntent(_ event: IntentResolvedEvent) {
        store.recordInteraction(focus: Self.humanizeIntent(event.intentLabel))
    }

    private func handleProactive(_ event: ProactiveSignalGeneratedEvent) {
        // Only genuinely-pressing signals belong on the attention list.
        guard event.priority >= .high else { return }
        store.addAttention(event.title, source: event.signalSource, confidence: 0.85)
    }

    private func handleBuildFailure(_ event: GitHubBuildFailedEvent) {
        let repo = event.repo.isEmpty ? "build" : event.repo
        let branch = event.branch.isEmpty ? "" : " (\(event.branch))"
        store.addOpenIssue("CI failing on \(repo)\(branch)", source: "github", confidence: 0.9)
        store.addBlocker("CI failing on \(repo)\(branch)", source: "github", confidence: 0.9)
    }

    // MARK: - Periodic refresh

    /// Pulls higher-level derived state that isn't event-driven: the dominant
    /// project (from the context-graph focus engine) and today's timeline
    /// summary (from the episode store).
    private func refresh() {
        let focus = ProjectRelationshipIndex.shared.activeFocusContext()
        if let project = focus.dominantProject, focus.confidence >= 0.40 {
            store.setActiveProject(project, confidence: focus.confidence)
        } else if focus.confidence < 0.20 {
            // Focus has dissipated — clear the stale project so we don't claim
            // certainty we no longer have.
            store.setActiveProject(nil, confidence: 0)
        }

        let summary = EpisodeStore.shared.todaysSummary()
        store.setTodaySummary(summary.isEmpty ? nil : summary)
    }

    // MARK: - Helpers

    /// Turns an intent label like `homeTurnOff` or `show_brain_overlay` into a
    /// short human phrase for the focus line ("home turn off", "show brain overlay").
    static func humanizeIntent(_ label: String) -> String {
        guard !label.isEmpty else { return "interacting" }
        // Strip any associated-value suffix the label may carry.
        let base = label.split(whereSeparator: { $0 == "(" }).first.map(String.init) ?? label
        var out = ""
        for ch in base {
            if ch == "_" || ch == "." || ch == "-" {
                out.append(" ")
            } else if ch.isUppercase, let last = out.last, last != " " {
                out.append(" ")
                out.append(Character(ch.lowercased()))
            } else {
                out.append(Character(ch.lowercased()))
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}
