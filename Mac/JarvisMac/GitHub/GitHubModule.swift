import Foundation

// MARK: - GitHubModule
// Central coordinator that owns all GitHub sub-managers.
// JarvisController holds one instance and passes it to views/execute().

@MainActor
final class GitHubModule: ObservableObject {
    let client:      GitHubAPIClient
    let repoMgr:     GitHubRepoManager
    let issueMgr:    GitHubIssueManager
    let prMgr:       GitHubPRManager
    let actionsMgr:  GitHubActionsManager
    let reviewEngine: GitHubCodeReviewEngine
    let roadmapMgr:  GitHubRoadmapAnalyzer
    let projectMgr:  GitHubProjectCreationManager
    let localIndex:  GitHubLocalRepoIndex
    let safety:      GitHubSafetyManager

    // Diagnostics
    @Published var lastError: String? = nil
    @Published var isActive: Bool = false

    init(token: String, llmRouter: GHLLMCapable? = nil) {
        let c = GitHubAPIClient(token: token)
        client     = c
        repoMgr    = GitHubRepoManager(client: c)
        issueMgr   = GitHubIssueManager(client: c)
        prMgr      = GitHubPRManager(client: c)
        actionsMgr = GitHubActionsManager(client: c)
        projectMgr = GitHubProjectCreationManager(repoMgr: GitHubRepoManager(client: c))
        localIndex = GitHubLocalRepoIndex.shared
        safety     = GitHubSafetyManager.shared

        // Code review engine needs all sub-managers
        reviewEngine = GitHubCodeReviewEngine(
            client: c,
            prMgr: GitHubPRManager(client: c),
            repoMgr: GitHubRepoManager(client: c),
            llmRouter: llmRouter
        )

        roadmapMgr = GitHubRoadmapAnalyzer(
            issueMgr:   GitHubIssueManager(client: c),
            prMgr:      GitHubPRManager(client: c),
            actionsMgr: GitHubActionsManager(client: c),
            repoMgr:    GitHubRepoManager(client: c)
        )

        isActive = true
    }

    // MARK: - Default Repo Resolution
    // Resolves a partial name ("jarvis", "android") to a full_name.
    // Falls back to the first repo in the list.

    func resolveRepo(_ partial: String?) async throws -> String {
        if let p = partial {
            if let found = try await repoMgr.findRepo(named: p) { return found.full_name }
        }
        // Fallback: first repo
        if let first = try await repoMgr.myRepos().first { return first.full_name }
        throw GHError.notFound
    }

    // MARK: - Spoken Diagnostics

    var diagnosticSummary: String {
        let remaining = GitHubSafetyManager.shared.remainingCoreRequests
        let cacheValid = GitHubCacheStore.shared.validEntryCount
        let localSnaps = localIndex.snapshots.count
        return "GitHub module active. API calls remaining: \(remaining). Cache entries: \(cacheValid). Local repos indexed: \(localSnaps)."
    }
}
