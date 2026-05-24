import Foundation

// MARK: - GitHubAPIClient
// Comprehensive GitHub REST API v3 client.
// Read operations are safe to call freely.
// Write operations are wired through GitHubSafetyManager in the managers above.

final class GitHubAPIClient {
    let token: String
    private let session: URLSession
    static let baseURL = "https://api.github.com"

    /// Last successfully fetched notifications — updated by `GitHubProactivityProvider`
    /// after every poll. Synchronously readable by `GitHubContextProvider`.
    var lastFetchedNotifications: [GHNotification] = []

    init(token: String, session: URLSession = .shared) {
        self.token = token
        self.session = session
    }

    // MARK: - Request Helpers

    private func request(_ path: String, method: String = "GET",
                         query: [String: String] = [:],
                         body: Encodable? = nil) throws -> URLRequest {
        var components = URLComponents(string: "\(Self.baseURL)\(path)")!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var req = URLRequest(url: components.url!)
        req.httpMethod = method
        req.setValue("Bearer \(token)",              forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json",  forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28",                   forHTTPHeaderField: "X-GitHub-Api-Version")
        if let body = body {
            req.setValue("application/json",          forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        return req
    }

    private func fetch<T: Decodable>(_ type: T.Type, path: String,
                                     method: String = "GET",
                                     query: [String: String] = [:],
                                     body: Encodable? = nil) async throws -> T {
        let req = try request(path, method: method, query: query, body: body)
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse {
            await updateRateLimits(from: http)
            if http.statusCode == 404 { throw GHError.notFound }
            if http.statusCode == 403 { throw GHError.forbidden }
            if http.statusCode == 401 { throw GHError.unauthorized }
            if http.statusCode >= 400 {
                let msg = (try? JSONDecoder().decode(GHErrorBody.self, from: data))?.message ?? "HTTP \(http.statusCode)"
                throw GHError.apiError(msg)
            }
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw GHError.decodingError(error.localizedDescription)
        }
    }

    @discardableResult
    private func send(path: String, method: String, body: Encodable? = nil) async throws -> Data {
        let req = try request(path, method: method, body: body)
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse {
            await updateRateLimits(from: http)
            if http.statusCode >= 400 {
                let msg = (try? JSONDecoder().decode(GHErrorBody.self, from: data))?.message ?? "HTTP \(http.statusCode)"
                throw GHError.apiError(msg)
            }
        }
        return data
    }

    @MainActor
    private func updateRateLimits(from response: HTTPURLResponse) {
        if let core = response.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init),
           let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init) {
            GitHubSafetyManager.shared.updateRateLimits(
                core: core,
                search: GitHubSafetyManager.shared.remainingSearchRequests,
                resetDate: Date(timeIntervalSince1970: reset)
            )
        }
    }

    // MARK: - Paginated Fetch

    func fetchAll<T: Decodable>(_ type: T.Type, path: String,
                                query: [String: String] = [:],
                                maxPages: Int = 5) async throws -> [T] {
        var results: [T] = []
        var page = 1
        while page <= maxPages {
            var q = query
            q["per_page"] = "100"
            q["page"] = "\(page)"
            let page_results = try await fetch([T].self, path: path, query: q)
            results.append(contentsOf: page_results)
            if page_results.count < 100 { break }
            page += 1
        }
        return results
    }

    // MARK: ─────────────────── READ: USER ───────────────────

    func getAuthenticatedUser() async throws -> GHUser {
        try await fetch(GHUser.self, path: "/user")
    }

    // MARK: ─────────────────── READ: REPOS ──────────────────

    /// List repositories for the authenticated user.
    func listMyRepos(visibility: String = "all", sort: String = "pushed") async throws -> [GHRepo] {
        try await fetchAll(GHRepo.self, path: "/user/repos",
                           query: ["visibility": visibility, "sort": sort])
    }

    /// Get a specific repo.
    func getRepo(fullName: String) async throws -> GHRepo {
        try await fetch(GHRepo.self, path: "/repos/\(fullName)")
    }

    /// Search repos.
    func searchRepos(query: String, sort: String = "updated") async throws -> [GHRepo] {
        let result = try await fetch(GHSearchResult.self, path: "/search/repositories",
                                     query: ["q": query, "sort": sort, "per_page": "20"])
        return result.items
    }

    /// List branches.
    func listBranches(repo: String) async throws -> [GHBranch] {
        try await fetch([GHBranch].self, path: "/repos/\(repo)/branches", query: ["per_page": "100"])
    }

    /// Get default branch latest commit.
    func getDefaultBranchCommit(repo: String, branch: String) async throws -> GHCommit {
        try await fetch(GHCommit.self, path: "/repos/\(repo)/commits/\(branch)")
    }

    // MARK: ─────────────────── READ: COMMITS ─────────────────

    func listCommits(repo: String, branch: String? = nil, since: Date? = nil, limit: Int = 30) async throws -> [GHCommit] {
        var q: [String: String] = ["per_page": "\(limit)"]
        if let b = branch { q["sha"] = b }
        if let s = since {
            let fmt = ISO8601DateFormatter()
            q["since"] = fmt.string(from: s)
        }
        return try await fetch([GHCommit].self, path: "/repos/\(repo)/commits", query: q)
    }

    func getCommit(repo: String, sha: String) async throws -> GHCommit {
        try await fetch(GHCommit.self, path: "/repos/\(repo)/commits/\(sha)")
    }

    // MARK: ─────────────────── READ: ISSUES ──────────────────

    func listIssues(repo: String, state: String = "open", labels: String? = nil, milestone: String? = nil) async throws -> [GHIssue] {
        var q: [String: String] = ["state": state, "per_page": "100"]
        if let l = labels     { q["labels"]    = l }
        if let m = milestone  { q["milestone"] = m }
        let all = try await fetch([GHIssue].self, path: "/repos/\(repo)/issues", query: q)
        // GitHub issues endpoint returns PRs too — filter them out
        return all.filter { !$0.isPR }
    }

    func getIssue(repo: String, number: Int) async throws -> GHIssue {
        try await fetch(GHIssue.self, path: "/repos/\(repo)/issues/\(number)")
    }

    func listMilestones(repo: String, state: String = "open") async throws -> [GHMilestone] {
        try await fetch([GHMilestone].self, path: "/repos/\(repo)/milestones",
                        query: ["state": state, "per_page": "50"])
    }

    // MARK: ─────────────────── READ: PULL REQUESTS ───────────

    func listPRs(repo: String, state: String = "open", base: String? = nil) async throws -> [GHPullRequest] {
        var q: [String: String] = ["state": state, "per_page": "100"]
        if let b = base { q["base"] = b }
        return try await fetch([GHPullRequest].self, path: "/repos/\(repo)/pulls", query: q)
    }

    func getPR(repo: String, number: Int) async throws -> GHPullRequest {
        try await fetch(GHPullRequest.self, path: "/repos/\(repo)/pulls/\(number)")
    }

    func getPRFiles(repo: String, number: Int) async throws -> [GHFileDiff] {
        try await fetch([GHFileDiff].self, path: "/repos/\(repo)/pulls/\(number)/files",
                        query: ["per_page": "100"])
    }

    func getPRReviews(repo: String, number: Int) async throws -> [GHReview] {
        try await fetch([GHReview].self, path: "/repos/\(repo)/pulls/\(number)/reviews")
    }

    func compareBranches(repo: String, base: String, head: String) async throws -> GHComparison {
        try await fetch(GHComparison.self, path: "/repos/\(repo)/compare/\(base)...\(head)")
    }

    // MARK: ─────────────────── READ: ACTIONS ─────────────────

    func listWorkflowRuns(repo: String, branch: String? = nil, status: String? = nil) async throws -> [GHWorkflowRun] {
        var q: [String: String] = ["per_page": "20"]
        if let b = branch { q["branch"] = b }
        if let s = status { q["status"] = s }
        let wrapper = try await fetch(WorkflowRunsWrapper.self, path: "/repos/\(repo)/actions/runs", query: q)
        return wrapper.workflow_runs
    }

    func listCheckRuns(repo: String, sha: String) async throws -> [GHCheckRun] {
        let wrapper = try await fetch(CheckRunsWrapper.self, path: "/repos/\(repo)/commits/\(sha)/check-runs",
                                      query: ["per_page": "50"])
        return wrapper.check_runs
    }

    func listCheckRunsForRef(repo: String, ref: String) async throws -> [GHCheckRun] {
        let wrapper = try await fetch(CheckRunsWrapper.self, path: "/repos/\(repo)/commits/\(ref)/check-runs",
                                      query: ["per_page": "50"])
        return wrapper.check_runs
    }

    // MARK: ─────────────────── READ: RELEASES ────────────────

    func listReleases(repo: String) async throws -> [GHRelease] {
        try await fetch([GHRelease].self, path: "/repos/\(repo)/releases", query: ["per_page": "20"])
    }

    func getLatestRelease(repo: String) async throws -> GHRelease {
        try await fetch(GHRelease.self, path: "/repos/\(repo)/releases/latest")
    }

    // MARK: ─────────────────── READ: NOTIFICATIONS ───────────

    /// Fetch unread (or all) notifications.
    func getNotifications(all: Bool = false, participating: Bool = true) async throws -> [GHNotification] {
        let q: [String: String] = [
            "all":          all          ? "true" : "false",
            "participating": participating ? "true" : "false",
        ]
        return try await fetch([GHNotification].self, path: "/notifications", query: q)
    }

    func markAllRead() async throws {
        _ = try await send(path: "/notifications", method: "PUT", body: ["read": true])
    }

    // MARK: ─────────────────── WRITE: ISSUES ─────────────────

    @discardableResult
    func createIssue(repo: String, title: String, body: String?, labels: [String]?) async throws -> GHIssue {
        struct Payload: Encodable {
            let title: String
            let body: String?
            let labels: [String]?
        }
        let data = try await send(path: "/repos/\(repo)/issues", method: "POST",
                                   body: Payload(title: title, body: body, labels: labels))
        return try JSONDecoder().decode(GHIssue.self, from: data)
    }

    @discardableResult
    func commentOnIssue(repo: String, number: Int, body: String) async throws -> Data {
        try await send(path: "/repos/\(repo)/issues/\(number)/comments", method: "POST",
                       body: ["body": body])
    }

    func closeIssue(repo: String, number: Int) async throws {
        _ = try await send(path: "/repos/\(repo)/issues/\(number)", method: "PATCH",
                            body: ["state": "closed"])
    }

    func labelIssue(repo: String, number: Int, labels: [String]) async throws {
        _ = try await send(path: "/repos/\(repo)/issues/\(number)/labels", method: "POST",
                            body: ["labels": labels])
    }

    // MARK: ─────────────────── WRITE: PULL REQUESTS ──────────

    @discardableResult
    func openPR(repo: String, title: String, body: String?, head: String, base: String) async throws -> GHPullRequest {
        struct Payload: Encodable {
            let title: String
            let body: String?
            let head: String
            let base: String
        }
        let data = try await send(path: "/repos/\(repo)/pulls", method: "POST",
                                   body: Payload(title: title, body: body, head: head, base: base))
        return try JSONDecoder().decode(GHPullRequest.self, from: data)
    }

    @discardableResult
    func commentOnPR(repo: String, number: Int, body: String) async throws -> Data {
        try await send(path: "/repos/\(repo)/issues/\(number)/comments", method: "POST",
                       body: ["body": body])
    }

    func requestReview(repo: String, prNumber: Int, reviewers: [String]) async throws {
        _ = try await send(path: "/repos/\(repo)/pulls/\(prNumber)/requested_reviewers", method: "POST",
                            body: ["reviewers": reviewers])
    }

    // MARK: ─────────────────── WRITE: BRANCHES ───────────────

    func createBranch(repo: String, name: String, fromSHA: String) async throws {
        struct Payload: Encodable { let ref: String; let sha: String }
        _ = try await send(path: "/repos/\(repo)/git/refs", method: "POST",
                            body: Payload(ref: "refs/heads/\(name)", sha: fromSHA))
    }

    // MARK: ─────────────────── WRITE: REPOS ──────────────────

    @discardableResult
    func createRepo(name: String, description: String?, isPrivate: Bool,
                    autoInit: Bool, gitignoreTemplate: String?,
                    licenseTemplate: String?) async throws -> GHRepo {
        struct Payload: Encodable {
            let name: String
            let description: String?
            let `private`: Bool
            let auto_init: Bool
            let gitignore_template: String?
            let license_template: String?
        }
        let data = try await send(path: "/user/repos", method: "POST",
                                   body: Payload(name: name, description: description,
                                                 private: isPrivate, auto_init: autoInit,
                                                 gitignore_template: gitignoreTemplate,
                                                 license_template: licenseTemplate))
        return try JSONDecoder().decode(GHRepo.self, from: data)
    }

    // MARK: ─────────────────── WRITE: RELEASES ───────────────

    @discardableResult
    func createReleaseDraft(repo: String, tag: String, name: String, body: String) async throws -> GHRelease {
        struct Payload: Encodable {
            let tag_name: String
            let name: String
            let body: String
            let draft: Bool
        }
        let data = try await send(path: "/repos/\(repo)/releases", method: "POST",
                                   body: Payload(tag_name: tag, name: name, body: body, draft: true))
        return try JSONDecoder().decode(GHRelease.self, from: data)
    }

    // MARK: ─────────────────── Helpers ───────────────────────

    struct WorkflowRunsWrapper: Decodable {
        let workflow_runs: [GHWorkflowRun]
    }
    struct CheckRunsWrapper: Decodable {
        let check_runs: [GHCheckRun]
    }
    struct GHErrorBody: Decodable {
        let message: String
    }
}

// MARK: - GHComparison

struct GHComparison: Decodable {
    let ahead_by: Int
    let behind_by: Int
    let status: String   // "ahead" | "behind" | "diverged" | "identical"
    let commits: [GHCommit]
    let files: [GHFileDiff]?
}

// MARK: - GHNotification (kept compatible with existing ProactivityProvider)

struct GHNotification: Decodable, Identifiable {
    let id: String
    let reason: String
    let unread: Bool
    let updated_at: String
    let subject: Subject
    let repository: Repository

    struct Subject: Decodable {
        let title: String
        let type: String
        let url: String?
    }

    struct Repository: Decodable {
        let full_name: String
    }
}

// MARK: - Error Types

enum GHError: LocalizedError {
    case notFound
    case forbidden
    case unauthorized
    case apiError(String)
    case decodingError(String)
    case rateLimited
    case safetyBlocked(String)

    var errorDescription: String? {
        switch self {
        case .notFound:             return "Not found on GitHub"
        case .forbidden:            return "Access forbidden — check token scopes"
        case .unauthorized:         return "Unauthorized — invalid token"
        case .apiError(let msg):    return "GitHub API: \(msg)"
        case .decodingError(let e): return "Parse error: \(e)"
        case .rateLimited:          return "GitHub rate limit reached"
        case .safetyBlocked(let r): return "Safety blocked: \(r)"
        }
    }
}
