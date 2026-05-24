import Foundation

/// Polls GitHub notifications and surfaces PR review requests and @mentions
/// as ProactivitySignals.
///
/// Polls every 10 minutes. Only surfaces actionable notification reasons:
/// `review_requested`, `mention`, `assign`. Skips subscriptions and CI noise.
@MainActor
final class GitHubProactivityProvider: ProactivitySignalProvider {
    let source: SignalSource = .github

    private weak var engine: ProactivityEngine?
    private weak var appState: AppState?
    private var client: GitHubAPIClient?
    private var pollTask: Task<Void, Never>?
    /// Persistent dedup of GitHub notification IDs we've already announced.
    /// Survives restarts — without this, every relaunch can replay every
    /// unread notification that happens to still be unread on GitHub.
    private let dedup = ProactivityDedupStore(name: "github.notifications")

    init(token: String, engine: ProactivityEngine, appState: AppState) {
        self.client   = GitHubAPIClient(token: token)
        self.engine   = engine
        self.appState = appState
    }

    func start() {
        pollTask = Task {
            while !Task.isCancelled {
                await pollNow()
                try? await Task.sleep(for: .seconds(600)) // every 10 min
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func pollNow() async {
        guard let client = client else { return }

        guard let notifications = try? await client.getNotifications() else { return }
        client.lastFetchedNotifications = notifications

        for notif in notifications where notif.unread && !dedup.contains(notif.id) {
            // Persistent insert — handles cap + atomic write.
            dedup.insert(notif.id)

            let repoShort   = notif.repository.full_name.components(separatedBy: "/").last
                              ?? notif.repository.full_name
            let title       = notif.subject.title
            let subjectType = notif.subject.type

            let spokenText:  String
            let signalTitle: String
            let priority:    SignalPriority

            switch notif.reason {
            case "review_requested":
                spokenText  = "You have a PR review request in \(repoShort): \(title)"
                signalTitle = "Review requested: \(title)"
                priority    = .high
            case "mention":
                spokenText  = "You were mentioned in \(repoShort): \(title)"
                signalTitle = "Mentioned in \(repoShort)"
                priority    = .normal
            case "assign":
                spokenText  = "You've been assigned to '\(title)' in \(repoShort)"
                signalTitle = "Assigned: \(title)"
                priority    = .normal
            case "ci_activity":
                spokenText  = "CI activity on '\(title)' in \(repoShort)"
                signalTitle = "CI: \(title)"
                priority    = .low
            default:
                // Skip subscribed, state_change, etc. — not worth interrupting
                continue
            }

            let signal = ProactivitySignal(
                source: .github,
                title: signalTitle,
                body: "\(subjectType) in \(notif.repository.full_name)",
                category: notif.reason,
                priority: priority,
                dedupeKey: "github.\(notif.id)",
                spokenText: spokenText,
                requiresAttention: priority >= .high
            )
            ProactivityOrchestrator.shared.providerPublish(signal: signal)
        }
    }
}
