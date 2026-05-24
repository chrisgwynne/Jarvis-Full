import Foundation

// MARK: - GitHubSafetyManager
// Controls write permissions, confirmation requirements, audit logging,
// and rate-limit tracking. All write actions must pass through here.

@MainActor
final class GitHubSafetyManager {
    static let shared = GitHubSafetyManager()

    // MARK: - Configuration

    /// When true, write actions execute immediately (no confirmation required).
    var trustedMode: Bool = false

    /// Repos where writes are blocked entirely (exact full_name match).
    var blockedRepos: Set<String> = []

    /// If set, only repos in this set may receive writes.
    var allowedRepos: Set<String>? = nil    // nil = all allowed

    /// Pending write action waiting for voice confirmation
    @Published private(set) var pendingAction: GHWriteAction? = nil
    private var pendingCompletion: ((Bool) -> Void)? = nil

    // MARK: - Rate-Limit Tracking

    private(set) var remainingCoreRequests: Int = 5000
    private(set) var remainingSearchRequests: Int = 30
    private(set) var rateLimitResetDate: Date = Date()

    func updateRateLimits(core: Int, search: Int, resetDate: Date) {
        remainingCoreRequests = core
        remainingSearchRequests = search
        rateLimitResetDate = resetDate
    }

    var isRateLimited: Bool {
        remainingCoreRequests < 10 && rateLimitResetDate > Date()
    }

    // MARK: - Audit Log

    private(set) var auditLog: [AuditEntry] = []

    struct AuditEntry: Identifiable {
        let id = UUID()
        let action: String
        let repo: String?
        let outcome: String    // "confirmed" | "rejected" | "auto-executed"
        let at: Date
    }

    // MARK: - Safety Checks

    enum Permission {
        case allowed
        case requiresConfirmation(reason: String)
        case blocked(reason: String)
    }

    func check(_ action: GHWriteAction) -> Permission {
        if isRateLimited {
            return .blocked(reason: "GitHub API rate limit reached — try again at \(rateLimitResetAt)")
        }

        // Extract repo name from action
        let repoName = actionRepo(action)

        if let repo = repoName {
            if blockedRepos.contains(repo) {
                return .blocked(reason: "'\(repo)' is on the blocked-repo list")
            }
            if let allowed = allowedRepos, !allowed.contains(repo) {
                return .blocked(reason: "'\(repo)' is not in the allowed-repo list")
            }
        }

        if action.isDestructive {
            return .requiresConfirmation(reason: "This action is destructive and requires confirmation")
        }

        if trustedMode {
            return .allowed
        }

        return .requiresConfirmation(reason: "Confirm write action on \(repoName ?? "GitHub")?")
    }

    /// Asks for voice confirmation before executing a write action.
    /// Calls `completion(true)` if confirmed, `completion(false)` if rejected.
    func requestConfirmation(for action: GHWriteAction, completion: @escaping (Bool) -> Void) {
        pendingAction = action
        pendingCompletion = completion
    }

    func confirmPending() {
        guard let action = pendingAction else { return }
        log(action: action.humanDescription, repo: actionRepo(action), outcome: "confirmed")
        pendingAction = nil
        let completion = pendingCompletion
        pendingCompletion = nil
        completion?(true)
    }

    func rejectPending() {
        guard let action = pendingAction else { return }
        log(action: action.humanDescription, repo: actionRepo(action), outcome: "rejected")
        pendingAction = nil
        let completion = pendingCompletion
        pendingCompletion = nil
        completion?(false)
    }

    // MARK: - Audit

    private func log(action: String, repo: String?, outcome: String) {
        let entry = AuditEntry(action: action, repo: repo, outcome: outcome, at: Date())
        auditLog.append(entry)
        if auditLog.count > 200 { auditLog.removeFirst() }
    }

    func logAutoExecution(_ action: GHWriteAction) {
        log(action: action.humanDescription, repo: actionRepo(action), outcome: "auto-executed")
    }

    // MARK: - Helpers

    private func actionRepo(_ action: GHWriteAction) -> String? {
        switch action {
        case .createIssue(let r, _, _, _):     return r
        case .commentOnIssue(let r, _, _):     return r
        case .closeIssue(let r, _):            return r
        case .createBranch(let r, _, _):       return r
        case .openPR(let r, _, _, _, _):       return r
        case .commentOnPR(let r, _, _):        return r
        case .requestReview(let r, _, _):      return r
        case .createRepo:                      return nil
        case .labelIssue(let r, _, _):         return r
        case .createReleaseDraft(let r, _, _, _): return r
        }
    }

    var rateLimitResetAt: String {
        let f = DateFormatter()
        f.timeStyle = .short
        return f.string(from: rateLimitResetDate)
    }

    // MARK: - Forbidden operations (hard-coded, never bypassed)

    func assertNeverMerge() { /* Called to document intent — no auto-merge ever */ }
    func assertNeverForce() { /* No force-push ever */ }
    func assertNeverDeleteRepo() { /* No repo deletion ever */ }
}
