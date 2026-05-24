import Foundation

// MARK: - GitHubIssueManager

@MainActor
final class GitHubIssueManager {
    private let client: GitHubAPIClient
    private let safety = GitHubSafetyManager.shared
    private let cache  = GitHubCacheStore.shared

    init(client: GitHubAPIClient) { self.client = client }

    // MARK: - Read

    func openIssues(repo: String, forceRefresh: Bool = false) async throws -> [GHIssue] {
        let key = GitHubCacheStore.key(repo: repo, resource: "issues.open")
        if !forceRefresh, let cached = cache.get([GHIssue].self, key: key) { return cached }
        let issues = try await client.listIssues(repo: repo, state: "open")
        cache.set(issues, key: key, ttl: GitHubCacheStore.TTL.issues)
        return issues
    }

    func staleIssues(repo: String) async throws -> [GHIssue] {
        let all = try await openIssues(repo: repo)
        return all.filter(\.isStale).sorted { $0.daysSinceUpdate > $1.daysSinceUpdate }
    }

    func getIssue(repo: String, number: Int) async throws -> GHIssue {
        try await client.getIssue(repo: repo, number: number)
    }

    func milestones(repo: String) async throws -> [GHMilestone] {
        let key = GitHubCacheStore.key(repo: repo, resource: "milestones")
        if let cached = cache.get([GHMilestone].self, key: key) { return cached }
        let ms = try await client.listMilestones(repo: repo)
        cache.set(ms, key: key, ttl: GitHubCacheStore.TTL.repos)
        return ms
    }

    // MARK: - Spoken

    func spokenIssueSummary(repo: String) async throws -> String {
        let issues = try await openIssues(repo: repo)
        let stale  = issues.filter(\.isStale)
        let repoShort = repo.components(separatedBy: "/").last ?? repo
        if issues.isEmpty { return "\(repoShort) has no open issues." }
        var text = "\(repoShort) has \(issues.count) open issue\(issues.count == 1 ? "" : "s")"
        if !stale.isEmpty { text += ", \(stale.count) stale" }
        if let top = issues.first { text += ". Top: \(top.title)." }
        return text
    }

    func spokenStaleIssues(repo: String) async throws -> String {
        let stale = try await staleIssues(repo: repo)
        let repoShort = repo.components(separatedBy: "/").last ?? repo
        if stale.isEmpty { return "No stale issues in \(repoShort)." }
        let titles = stale.prefix(3).map { "#\($0.number): \($0.title)" }.joined(separator: "; ")
        return "\(stale.count) stale issue\(stale.count == 1 ? "" : "s") in \(repoShort): \(titles)."
    }

    // MARK: - Write

    func createIssue(repo: String, title: String, body: String?, labels: [String]?,
                     onConfirm: @escaping (Bool) -> Void) {
        let action = GHWriteAction.createIssue(repo: repo, title: title,
                                               body: body ?? "", labels: labels ?? [])
        switch safety.check(action) {
        case .blocked(let reason):
            onConfirm(false)
            return
        case .requiresConfirmation:
            safety.requestConfirmation(for: action) { confirmed in
                if confirmed {
                    Task {
                        do {
                            try await self.client.createIssue(repo: repo, title: title,
                                                              body: body, labels: labels)
                            self.cache.invalidate(key: GitHubCacheStore.key(repo: repo, resource: "issues.open"))
                            onConfirm(true)
                        } catch { onConfirm(false) }
                    }
                } else { onConfirm(false) }
            }
        case .allowed:
            Task {
                do {
                    try await client.createIssue(repo: repo, title: title, body: body, labels: labels)
                    safety.logAutoExecution(action)
                    cache.invalidate(key: GitHubCacheStore.key(repo: repo, resource: "issues.open"))
                    onConfirm(true)
                } catch { onConfirm(false) }
            }
        }
    }

    func commentOnIssue(repo: String, number: Int, body: String,
                        onConfirm: @escaping (Bool) -> Void) {
        let action = GHWriteAction.commentOnIssue(repo: repo, number: number, body: body)
        requestConfirmationIfNeeded(action) { confirmed in
            guard confirmed else { onConfirm(false); return }
            Task {
                do {
                    try await self.client.commentOnIssue(repo: repo, number: number, body: body)
                    onConfirm(true)
                } catch { onConfirm(false) }
            }
        }
    }

    func closeIssue(repo: String, number: Int, onConfirm: @escaping (Bool) -> Void) {
        let action = GHWriteAction.closeIssue(repo: repo, number: number)
        requestConfirmationIfNeeded(action) { confirmed in
            guard confirmed else { onConfirm(false); return }
            Task {
                do {
                    try await self.client.closeIssue(repo: repo, number: number)
                    self.cache.invalidate(key: GitHubCacheStore.key(repo: repo, resource: "issues.open"))
                    onConfirm(true)
                } catch { onConfirm(false) }
            }
        }
    }

    // MARK: - Helper

    private func requestConfirmationIfNeeded(_ action: GHWriteAction, completion: @escaping (Bool) -> Void) {
        switch safety.check(action) {
        case .blocked(let reason):
            _ = reason
            completion(false)
        case .allowed:
            safety.logAutoExecution(action)
            completion(true)
        case .requiresConfirmation:
            safety.requestConfirmation(for: action, completion: completion)
        }
    }
}
