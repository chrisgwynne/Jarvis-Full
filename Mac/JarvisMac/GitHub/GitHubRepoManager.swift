import Foundation

// MARK: - GitHubRepoManager
// Coordinator for all repository-level read and write operations.

@MainActor
final class GitHubRepoManager {
    private let client: GitHubAPIClient
    private let cache = GitHubCacheStore.shared

    init(client: GitHubAPIClient) {
        self.client = client
    }

    // MARK: - Read

    /// My repos, sorted by recently pushed. Cached 5 min.
    func myRepos(forceRefresh: Bool = false) async throws -> [GHRepo] {
        let key = GitHubCacheStore.key(resource: "myRepos")
        if !forceRefresh, let cached = cache.get([GHRepo].self, key: key) {
            return cached
        }
        let repos = try await client.listMyRepos()
        cache.set(repos, key: key, ttl: GitHubCacheStore.TTL.repos)
        return repos
    }

    /// Get a specific repo by full_name (e.g. "owner/repo").
    func getRepo(_ fullName: String, forceRefresh: Bool = false) async throws -> GHRepo {
        let key = GitHubCacheStore.key(repo: fullName, resource: "info")
        if !forceRefresh, let cached = cache.get(GHRepo.self, key: key) {
            return cached
        }
        let repo = try await client.getRepo(fullName: fullName)
        cache.set(repo, key: key, ttl: GitHubCacheStore.TTL.repos)
        return repo
    }

    /// Find a repo by partial name (case-insensitive prefix or substring).
    func findRepo(named name: String) async throws -> GHRepo? {
        let repos = try await myRepos()
        let lower = name.lowercased()
        return repos.first(where: { $0.name.lowercased().hasPrefix(lower) })
            ?? repos.first(where: { $0.name.lowercased().contains(lower) })
    }

    /// Repos that haven't been pushed to in >30 days.
    func neglectedRepos() async throws -> [GHRepo] {
        let repos = try await myRepos()
        return repos.filter { ($0.daysSinceLastPush ?? 0) > 30 && !$0.archived }
                    .sorted { ($0.daysSinceLastPush ?? 0) > ($1.daysSinceLastPush ?? 0) }
    }

    /// Most active repos by push recency.
    func activeRepos(limit: Int = 5) async throws -> [GHRepo] {
        let repos = try await myRepos()
        return Array(repos.filter { !$0.archived }.prefix(limit))
    }

    /// Branches for a repo.
    func branches(repo: String) async throws -> [GHBranch] {
        let key = GitHubCacheStore.key(repo: repo, resource: "branches")
        if let cached = cache.get([GHBranch].self, key: key) { return cached }
        let branches = try await client.listBranches(repo: repo)
        cache.set(branches, key: key, ttl: GitHubCacheStore.TTL.repos)
        return branches
    }

    /// Recent commits.
    func recentCommits(repo: String, limit: Int = 10) async throws -> [GHCommit] {
        let key = GitHubCacheStore.key(repo: repo, resource: "commits.\(limit)")
        if let cached = cache.get([GHCommit].self, key: key) { return cached }
        let commits = try await client.listCommits(repo: repo, limit: limit)
        cache.set(commits, key: key, ttl: GitHubCacheStore.TTL.commits)
        return commits
    }

    /// What changed since a given date.
    func commitsSince(repo: String, since: Date) async throws -> [GHCommit] {
        try await client.listCommits(repo: repo, since: since, limit: 50)
    }

    // MARK: - Spoken Summaries

    func spokenRepoSummary(repo: String) async throws -> String {
        let r = try await getRepo(repo)
        let commits = try await recentCommits(repo: repo, limit: 1)
        let days = r.daysSinceLastPush.map { "\($0) day\($0 == 1 ? "" : "s") ago" } ?? "unknown"
        let lastMsg = commits.first?.title ?? "no recent commits"
        return "\(r.name): \(r.open_issues_count) open issue\(r.open_issues_count == 1 ? "" : "s"), last pushed \(days). Latest: \(lastMsg)."
    }

    func spokenRecentChanges(repo: String, since: Date? = nil) async throws -> String {
        let since = since ?? Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let commits = try await commitsSince(repo: repo, since: since)
        if commits.isEmpty { return "No new commits to \(repo.components(separatedBy: "/").last ?? repo) since then." }
        let names = commits.prefix(3).map(\.title).joined(separator: "; ")
        let more = commits.count > 3 ? " (and \(commits.count - 3) more)" : ""
        return "\(commits.count) commit\(commits.count == 1 ? "" : "s") since then: \(names)\(more)."
    }

    func spokenNeglectedRepos() async throws -> String {
        let repos = try await neglectedRepos()
        if repos.isEmpty { return "All your repos have recent activity." }
        let names = repos.prefix(3).map(\.name).joined(separator: ", ")
        return "\(repos.count) repo\(repos.count == 1 ? "" : "s") haven't been updated recently: \(names)."
    }

    // MARK: - Write

    func createRepo(_ request: GHProjectCreationRequest) async throws -> GHRepo {
        // Safety check handled by caller (GitHubProjectCreationManager)
        let repo = try await client.createRepo(
            name: sanitizeName(request.name),
            description: request.description.isEmpty ? nil : request.description,
            isPrivate: request.isPrivate,
            autoInit: request.includeReadme,
            gitignoreTemplate: request.gitignoreTemplate ?? request.template.gitignore,
            licenseTemplate: request.licenseTemplate
        )
        cache.invalidate(key: GitHubCacheStore.key(resource: "myRepos"))
        return repo
    }

    func createBranch(repo: String, name: String, fromSHA: String) async throws {
        try await client.createBranch(repo: repo, name: name, fromSHA: fromSHA)
        cache.invalidate(key: GitHubCacheStore.key(repo: repo, resource: "branches"))
    }

    // MARK: - Helpers

    private func sanitizeName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces)
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
    }
}
