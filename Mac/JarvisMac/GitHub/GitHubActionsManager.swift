import Foundation

// MARK: - GitHubActionsManager
// CI / GitHub Actions status reader.

@MainActor
final class GitHubActionsManager {
    private let client: GitHubAPIClient
    private let cache  = GitHubCacheStore.shared

    init(client: GitHubAPIClient) { self.client = client }

    // MARK: - Read

    func latestRuns(repo: String, limit: Int = 10, forceRefresh: Bool = false) async throws -> [GHWorkflowRun] {
        let key = GitHubCacheStore.key(repo: repo, resource: "actions.runs")
        if !forceRefresh, let cached = cache.get([GHWorkflowRun].self, key: key) {
            return Array(cached.prefix(limit))
        }
        let runs = try await client.listWorkflowRuns(repo: repo)
        cache.set(runs, key: key, ttl: GitHubCacheStore.TTL.actions)
        return Array(runs.prefix(limit))
    }

    func failingBuilds(repo: String) async throws -> [GHWorkflowRun] {
        let runs = try await latestRuns(repo: repo)
        return runs.filter(\.isFailing)
    }

    func checkRunsForPR(repo: String, headSHA: String) async throws -> [GHCheckRun] {
        let key = GitHubCacheStore.key(repo: repo, resource: "checks.\(headSHA.prefix(7))")
        if let cached = cache.get([GHCheckRun].self, key: key) { return cached }
        let checks = try await client.listCheckRuns(repo: repo, sha: headSHA)
        cache.set(checks, key: key, ttl: GitHubCacheStore.TTL.actions)
        return checks
    }

    func overallCIStatus(repo: String) async throws -> CIStatus {
        let runs = try await latestRuns(repo: repo, limit: 5)
        if runs.isEmpty { return .unknown }
        let failing = runs.filter { $0.isFailing }
        let running = runs.filter { $0.isRunning }
        if !failing.isEmpty { return .failing(count: failing.count) }
        if !running.isEmpty { return .running }
        return .passing
    }

    // MARK: - Spoken

    func spokenCIStatus(repo: String) async throws -> String {
        let repoShort = repo.components(separatedBy: "/").last ?? repo
        let status = try await overallCIStatus(repo: repo)
        switch status {
        case .passing:            return "CI is passing for \(repoShort)."
        case .failing(let n):     return "\(n) build\(n == 1 ? "" : "s") failing in \(repoShort)."
        case .running:            return "Builds are currently running for \(repoShort)."
        case .unknown:            return "No recent CI runs found for \(repoShort)."
        }
    }

    func spokenFailingBuilds(repo: String) async throws -> String {
        let repoShort = repo.components(separatedBy: "/").last ?? repo
        let failing = try await failingBuilds(repo: repo)
        if failing.isEmpty { return "No failing builds in \(repoShort)." }
        let names = failing.prefix(3).map { $0.name ?? "build" }.joined(separator: ", ")
        return "\(failing.count) failing build\(failing.count == 1 ? "" : "s") in \(repoShort): \(names)."
    }

    // MARK: - Models

    enum CIStatus {
        case passing
        case failing(count: Int)
        case running
        case unknown
    }
}
