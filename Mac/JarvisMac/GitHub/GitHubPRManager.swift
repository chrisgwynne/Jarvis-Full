import Foundation

// MARK: - GitHubPRManager

@MainActor
final class GitHubPRManager {
    private let client: GitHubAPIClient
    private let safety = GitHubSafetyManager.shared
    private let cache  = GitHubCacheStore.shared

    init(client: GitHubAPIClient) { self.client = client }

    // MARK: - Read

    func openPRs(repo: String, forceRefresh: Bool = false) async throws -> [GHPullRequest] {
        let key = GitHubCacheStore.key(repo: repo, resource: "prs.open")
        if !forceRefresh, let cached = cache.get([GHPullRequest].self, key: key) { return cached }
        let prs = try await client.listPRs(repo: repo, state: "open")
        cache.set(prs, key: key, ttl: GitHubCacheStore.TTL.prs)
        return prs
    }

    func getPR(repo: String, number: Int) async throws -> GHPullRequest {
        try await client.getPR(repo: repo, number: number)
    }

    func getPRFiles(repo: String, number: Int) async throws -> [GHFileDiff] {
        let key = GitHubCacheStore.key(repo: repo, resource: "pr.\(number).files")
        if let cached = cache.get([GHFileDiff].self, key: key) { return cached }
        let files = try await client.getPRFiles(repo: repo, number: number)
        cache.set(files, key: key, ttl: GitHubCacheStore.TTL.prs)
        return files
    }

    func getPRReviews(repo: String, number: Int) async throws -> [GHReview] {
        try await client.getPRReviews(repo: repo, number: number)
    }

    func stalePRs(repo: String) async throws -> [GHPullRequest] {
        let prs = try await openPRs(repo: repo)
        return prs.filter { $0.isStale && !$0.isDraft }
    }

    func largePRs(repo: String) async throws -> [GHPullRequest] {
        let prs = try await openPRs(repo: repo)
        return prs.filter { $0.sizeLabel == "large" }
    }

    func latestPR(repo: String) async throws -> GHPullRequest? {
        (try await openPRs(repo: repo)).first
    }

    // MARK: - Spoken Summaries

    func spokenPRSummary(repo: String) async throws -> String {
        let prs   = try await openPRs(repo: repo)
        let stale = prs.filter(\.isStale)
        let draft = prs.filter(\.isDraft)
        let repoShort = repo.components(separatedBy: "/").last ?? repo
        if prs.isEmpty { return "\(repoShort) has no open pull requests." }
        var text = "\(prs.count) open PR\(prs.count == 1 ? "" : "s") in \(repoShort)"
        if !draft.isEmpty  { text += ", \(draft.count) draft" }
        if !stale.isEmpty  { text += ", \(stale.count) stale" }
        if let top = prs.first { text += ". Latest: \(top.title) by \(top.user?.login ?? "unknown")." }
        return text
    }

    func spokenPRDetail(repo: String, number: Int) async throws -> String {
        let pr    = try await getPR(repo: repo, number: number)
        let files = try? await getPRFiles(repo: repo, number: number)
        var text  = "PR #\(pr.number): \(pr.title). "
        text += "\(pr.additions ?? 0) additions, \(pr.deletions ?? 0) deletions across \(pr.changed_files ?? 0) file\((pr.changed_files ?? 0) == 1 ? "" : "s"). "
        if let risky = files?.filter(\.isRisky), !risky.isEmpty {
            text += "Risky files: \(risky.map(\.filename).prefix(3).joined(separator: ", ")). "
        }
        if !pr.requested_reviewers.isEmpty {
            text += "Awaiting review from \(pr.requested_reviewers.map(\.login).joined(separator: ", "))."
        }
        return text
    }

    // MARK: - Write

    func openPR(repo: String, title: String, body: String?, head: String, base: String,
                onConfirm: @escaping (Result<GHPullRequest, Error>) -> Void) {
        let action = GHWriteAction.openPR(repo: repo, title: title, body: body ?? "", head: head, base: base)
        requestConfirmationIfNeeded(action) { confirmed in
            guard confirmed else { onConfirm(.failure(GHError.safetyBlocked("Rejected"))); return }
            Task {
                do {
                    let pr = try await self.client.openPR(repo: repo, title: title, body: body,
                                                          head: head, base: base)
                    self.cache.invalidate(key: GitHubCacheStore.key(repo: repo, resource: "prs.open"))
                    onConfirm(.success(pr))
                } catch { onConfirm(.failure(error)) }
            }
        }
    }

    func commentOnPR(repo: String, number: Int, body: String,
                     onConfirm: @escaping (Bool) -> Void) {
        let action = GHWriteAction.commentOnPR(repo: repo, number: number, body: body)
        requestConfirmationIfNeeded(action) { confirmed in
            guard confirmed else { onConfirm(false); return }
            Task {
                do {
                    try await self.client.commentOnPR(repo: repo, number: number, body: body)
                    onConfirm(true)
                } catch { onConfirm(false) }
            }
        }
    }

    func requestReview(repo: String, prNumber: Int, reviewers: [String],
                       onConfirm: @escaping (Bool) -> Void) {
        let action = GHWriteAction.requestReview(repo: repo, prNumber: prNumber, reviewers: reviewers)
        requestConfirmationIfNeeded(action) { confirmed in
            guard confirmed else { onConfirm(false); return }
            Task {
                do {
                    try await self.client.requestReview(repo: repo, prNumber: prNumber, reviewers: reviewers)
                    onConfirm(true)
                } catch { onConfirm(false) }
            }
        }
    }

    // MARK: - Helper

    private func requestConfirmationIfNeeded(_ action: GHWriteAction, completion: @escaping (Bool) -> Void) {
        switch safety.check(action) {
        case .blocked: completion(false)
        case .allowed:
            safety.logAutoExecution(action)
            completion(true)
        case .requiresConfirmation:
            safety.requestConfirmation(for: action, completion: completion)
        }
    }
}
