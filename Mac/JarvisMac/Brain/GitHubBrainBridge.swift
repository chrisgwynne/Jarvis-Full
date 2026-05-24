import Foundation
import os

// MARK: - GitHubBrainBridge

/// Routes GitHub SystemBus events into BrainMemoryStore and EpisodeStore.
///
/// Subscriptions:
/// - `GitHubBuildFailedEvent` → commits a `.bugReport` memory (CI failure is high-signal).
/// - `AppFocusChangedEvent` for GitHub-family apps → hints EpisodeStore so the active
///   work session is labelled with the app context.
///
/// Only commits memories whose `confidence × importance` score clears `autoCommitThreshold`.
@MainActor
final class GitHubBrainBridge {

    private var tokens: [SystemBus.SubscriptionToken] = []
    private let log = Logger(subsystem: "com.jarvis", category: "brain.github-bridge")

    // Bundle-ID substrings treated as GitHub-family apps.
    private let githubBundleHints = ["github", "linear", "jira", "shortcut"]

    // MARK: - Lifecycle

    func start() {
        tokens.append(
            SystemBus.shared.subscribe(GitHubBuildFailedEvent.self) { [weak self] event in
                self?.handleBuildFailed(event)
            }
        )
        tokens.append(
            SystemBus.shared.subscribe(AppFocusChangedEvent.self) { [weak self] event in
                self?.handleAppFocus(event)
            }
        )
        log.info("brain.github-bridge: started")
    }

    func stop() {
        tokens.forEach { SystemBus.shared.unsubscribe($0) }
        tokens.removeAll()
    }

    // MARK: - Handlers

    private func handleBuildFailed(_ event: GitHubBuildFailedEvent) {
        var candidate = MemoryCandidate(
            type: .bugReport,
            tier: .projectMemory,
            title: "CI failure: \(event.repo) [\(event.branch)]",
            summary: event.message.isEmpty ? "Build failed on \(event.branch)" : event.message,
            rawText: event.message,
            confidence: 0.90,
            tags: ["github", "ci", "build-failure"],
            createdAt: event.timestamp
        )
        candidate.source     = .github
        candidate.importance = 0.80

        guard candidate.confidence * candidate.importance >= BrainMemoryStore.autoCommitThreshold else { return }

        Task {
            let committed = await BrainMemoryStore.shared.commit(candidate)
            if committed {
                EpisodeStore.shared.recordTopic("build failure")
                EpisodeStore.shared.recordApp("GitHub")
                log.info("brain.github-bridge: committed CI failure memory for \(event.repo)")
            }
        }
    }

    private func handleAppFocus(_ event: AppFocusChangedEvent) {
        let bundleLower = event.activeBundleID.lowercased()
        guard githubBundleHints.contains(where: { bundleLower.contains($0) }) else { return }
        EpisodeStore.shared.maybeAutoStart(appName: event.activeApp)
        EpisodeStore.shared.recordApp(event.activeApp)
    }
}
