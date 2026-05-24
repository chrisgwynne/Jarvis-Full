import Foundation

// MARK: - Core GitHub Models
// All models are Codable for cache persistence and API decoding.

struct GHUser: Codable, Identifiable {
    let id: Int
    let login: String
    let avatar_url: String?
    let html_url: String?
    let type: String?          // "User" | "Bot" | "Organization"
    var displayName: String { login }
}

struct GHLabel: Codable, Identifiable {
    let id: Int
    let name: String
    let color: String
    let description: String?
}

struct GHMilestone: Codable, Identifiable {
    let id: Int
    let number: Int
    let title: String
    let state: String          // "open" | "closed"
    let open_issues: Int
    let closed_issues: Int
    let due_on: String?
    let description: String?

    var completionPercent: Double {
        let total = open_issues + closed_issues
        guard total > 0 else { return 0 }
        return Double(closed_issues) / Double(total) * 100
    }
}

struct GHRepo: Codable, Identifiable {
    let id: Int
    let name: String
    let full_name: String
    let description: String?
    let `private`: Bool
    let html_url: String
    let clone_url: String
    let ssh_url: String
    let default_branch: String
    let language: String?
    let stargazers_count: Int
    let forks_count: Int
    let open_issues_count: Int
    let updated_at: String?
    let pushed_at: String?
    let archived: Bool
    let disabled: Bool
    let owner: GHUser

    var isPrivate: Bool { `private` }

    var lastPushedDate: Date? {
        guard let s = pushed_at else { return nil }
        return ISO8601DateFormatter().date(from: s)
    }

    var daysSinceLastPush: Int? {
        guard let d = lastPushedDate else { return nil }
        return Calendar.current.dateComponents([.day], from: d, to: Date()).day
    }
}

struct GHBranch: Codable, Identifiable {
    let name: String
    let protected: Bool
    let commit: CommitRef

    var id: String { name }

    struct CommitRef: Codable {
        let sha: String
        let url: String
    }
}

struct GHCommit: Codable, Identifiable {
    let sha: String
    let html_url: String?
    let commit: CommitDetail
    let author: GHUser?
    let committer: GHUser?

    var id: String { sha }
    var shortSHA: String { String(sha.prefix(7)) }

    struct CommitDetail: Codable {
        let message: String
        let author: GitAuthor
        let committer: GitAuthor?
    }

    struct GitAuthor: Codable {
        let name: String
        let email: String?
        let date: String?
    }

    var date: Date? {
        guard let s = commit.author.date else { return nil }
        return ISO8601DateFormatter().date(from: s)
    }

    var title: String { commit.message.components(separatedBy: "\n").first ?? "" }
}

struct GHIssue: Codable, Identifiable {
    let id: Int
    let number: Int
    let title: String
    let state: String          // "open" | "closed"
    let body: String?
    let html_url: String
    let user: GHUser?
    let assignees: [GHUser]
    let labels: [GHLabel]
    let milestone: GHMilestone?
    let comments: Int
    let created_at: String
    let updated_at: String
    let closed_at: String?
    let pull_request: PullRef?  // non-nil iff this is actually a PR

    var isPR: Bool { pull_request != nil }
    var isOpen: Bool { state == "open" }

    struct PullRef: Codable {
        let url: String?
        let html_url: String?
    }

    var createdDate: Date? { ISO8601DateFormatter().date(from: created_at) }
    var updatedDate: Date? { ISO8601DateFormatter().date(from: updated_at) }

    var daysSinceUpdate: Int {
        guard let d = updatedDate else { return 0 }
        return Calendar.current.dateComponents([.day], from: d, to: Date()).day ?? 0
    }

    var isStale: Bool { daysSinceUpdate > 30 && isOpen }
}

struct GHPullRequest: Codable, Identifiable {
    let id: Int
    let number: Int
    let title: String
    let state: String           // "open" | "closed" | "merged"
    let body: String?
    let html_url: String
    let user: GHUser?
    let head: BranchRef
    let base: BranchRef
    let labels: [GHLabel]
    let assignees: [GHUser]
    let requested_reviewers: [GHUser]
    let milestone: GHMilestone?
    let draft: Bool
    let merged: Bool
    let mergeable: Bool?
    let additions: Int?
    let deletions: Int?
    let changed_files: Int?
    let comments: Int
    let review_comments: Int
    let commits: Int
    let created_at: String
    let updated_at: String
    let merged_at: String?
    let closed_at: String?

    var isOpen: Bool { state == "open" }
    var isDraft: Bool { draft }
    var isMerged: Bool { merged }

    struct BranchRef: Codable {
        let label: String
        let ref: String        // branch name
        let sha: String
        let repo: GHRepoRef?
    }

    struct GHRepoRef: Codable {
        let full_name: String
    }

    var createdDate: Date? { ISO8601DateFormatter().date(from: created_at) }
    var updatedDate: Date? { ISO8601DateFormatter().date(from: updated_at) }
    var daysSinceUpdate: Int {
        guard let d = updatedDate else { return 0 }
        return Calendar.current.dateComponents([.day], from: d, to: Date()).day ?? 0
    }
    var isStale: Bool { daysSinceUpdate > 14 && isOpen }

    var sizeLabel: String {
        let changed = changed_files ?? 0
        let lines = (additions ?? 0) + (deletions ?? 0)
        if changed > 20 || lines > 500 { return "large" }
        if changed > 5  || lines > 100 { return "medium" }
        return "small"
    }
}

struct GHReview: Codable, Identifiable {
    let id: Int
    let user: GHUser?
    let state: String         // "APPROVED" | "CHANGES_REQUESTED" | "COMMENTED" | "PENDING"
    let body: String?
    let submitted_at: String?
    let html_url: String
}

struct GHCheckRun: Codable, Identifiable {
    let id: Int
    let name: String
    let status: String        // "queued" | "in_progress" | "completed"
    let conclusion: String?   // "success" | "failure" | "neutral" | "cancelled" | "skipped" | "timed_out"
    let html_url: String
    let started_at: String?
    let completed_at: String?
    let check_suite: CheckSuite?

    var isPassing: Bool { conclusion == "success" || conclusion == "neutral" || conclusion == "skipped" }
    var isFailing: Bool { conclusion == "failure" || conclusion == "timed_out" }
    var isRunning: Bool { status == "in_progress" || status == "queued" }

    struct CheckSuite: Codable {
        let id: Int
    }
}

struct GHWorkflowRun: Codable, Identifiable {
    let id: Int
    let name: String?
    let status: String       // "queued" | "in_progress" | "completed"
    let conclusion: String?  // "success" | "failure" | "cancelled" | "neutral"
    let html_url: String
    let event: String        // "push" | "pull_request" | "workflow_dispatch" ...
    let created_at: String
    let updated_at: String
    let head_branch: String?
    let head_sha: String?

    var isPassing: Bool { conclusion == "success" }
    var isFailing: Bool { conclusion == "failure" }
    var isRunning: Bool { status == "in_progress" || status == "queued" }
}

struct GHRelease: Codable, Identifiable {
    let id: Int
    let tag_name: String
    let name: String?
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let html_url: String
    let published_at: String?
    let author: GHUser?
}

struct GHFileDiff: Codable, Identifiable {
    let filename: String
    let status: String       // "added" | "removed" | "modified" | "renamed"
    let additions: Int
    let deletions: Int
    let changes: Int
    let patch: String?

    var id: String { filename }
    var isRisky: Bool { changes > 200 || filename.hasSuffix("Package.swift") || filename.hasSuffix(".xcodeproj/project.pbxproj") }
}

struct GHSearchResult: Codable {
    let total_count: Int
    let incomplete_results: Bool
    let items: [GHRepo]
}

// MARK: - Local Repo Snapshot (not from API)

struct GHLocalRepoSnapshot: Codable, Identifiable {
    var id: String { path }
    let path: String              // absolute local path
    let fullName: String          // owner/repo
    var language: String?
    let indexedAt: Date
    var fileCount: Int = 0
    var todoCount: Int = 0
    var fixmeCount: Int = 0
    var largeFiles: [String] = []
    var topLanguages: [String: Int] = [:]  // ext → line count
    var staleLocalBranches: [String] = []
    var lastLocalCommit: String = ""
    var lastLocalCommitDate: Date?
}

// MARK: - Write Operations (pending confirmation)

enum GHWriteAction: Identifiable {
    case createIssue(repo: String, title: String, body: String, labels: [String])
    case commentOnIssue(repo: String, number: Int, body: String)
    case closeIssue(repo: String, number: Int)
    case createBranch(repo: String, name: String, fromSHA: String)
    case openPR(repo: String, title: String, body: String, head: String, base: String)
    case commentOnPR(repo: String, number: Int, body: String)
    case requestReview(repo: String, prNumber: Int, reviewers: [String])
    case createRepo(name: String, description: String, isPrivate: Bool, autoInit: Bool, gitignoreTemplate: String?, licenseTemplate: String?)
    case labelIssue(repo: String, number: Int, labels: [String])
    case createReleaseDraft(repo: String, tag: String, name: String, body: String)

    var id: String {
        switch self {
        case .createIssue(let r, let t, _, _):       return "createIssue.\(r).\(t)"
        case .commentOnIssue(let r, let n, _):       return "commentIssue.\(r).\(n)"
        case .closeIssue(let r, let n):              return "closeIssue.\(r).\(n)"
        case .createBranch(let r, let n, _):         return "createBranch.\(r).\(n)"
        case .openPR(let r, let t, _, _, _):         return "openPR.\(r).\(t)"
        case .commentOnPR(let r, let n, _):          return "commentPR.\(r).\(n)"
        case .requestReview(let r, let n, _):        return "requestReview.\(r).\(n)"
        case .createRepo(let n, _, _, _, _, _):      return "createRepo.\(n)"
        case .labelIssue(let r, let n, _):           return "labelIssue.\(r).\(n)"
        case .createReleaseDraft(let r, let t, _, _): return "createRelease.\(r).\(t)"
        }
    }

    var humanDescription: String {
        switch self {
        case .createIssue(let r, let t, _, _):       return "Create issue '\(t)' in \(r)"
        case .commentOnIssue(let r, let n, _):       return "Comment on issue #\(n) in \(r)"
        case .closeIssue(let r, let n):              return "Close issue #\(n) in \(r)"
        case .createBranch(let r, let n, _):         return "Create branch '\(n)' in \(r)"
        case .openPR(let r, let t, _, _, _):         return "Open PR '\(t)' in \(r)"
        case .commentOnPR(let r, let n, _):          return "Comment on PR #\(n) in \(r)"
        case .requestReview(let r, let n, let rev):  return "Request review from \(rev.joined(separator: ", ")) on PR #\(n) in \(r)"
        case .createRepo(let n, _, _, _, _, _):      return "Create repository '\(n)'"
        case .labelIssue(let r, let n, let l):       return "Label issue #\(n) in \(r) with [\(l.joined(separator: ", "))]"
        case .createReleaseDraft(let r, let t, _, _): return "Create release draft \(t) in \(r)"
        }
    }

    var isDestructive: Bool {
        switch self {
        case .closeIssue: return true
        default:          return false
        }
    }
}

// MARK: - Code Review Result

struct GHCodeReviewResult: Identifiable {
    let id = UUID()
    let prNumber: Int
    let repoFullName: String
    let summary: String
    let riskyFiles: [String]
    let regressionRisk: String    // "low" | "medium" | "high"
    let architecturalImpact: String
    let testCoverageNote: String
    let todosAdded: [String]
    let keyFindings: [String]
    let generatedAt: Date
}

// MARK: - Roadmap Analysis

struct GHRoadmapAnalysis: Identifiable {
    let id = UUID()
    let repoFullName: String
    let completionPercent: Double
    let openIssues: Int
    let closedIssues: Int
    let openPRs: Int
    let stalePRs: Int
    let staleIssues: Int
    let activeMilestone: GHMilestone?
    let velocityEstimate: String   // "high" | "medium" | "low" | "stalled"
    let topBlockers: [String]
    let summary: String
    let generatedAt: Date
}

// MARK: - Project Creation Request

struct GHProjectCreationRequest {
    var name: String = ""
    var description: String = ""
    var isPrivate: Bool = true
    var template: GHProjectTemplate = .empty
    var includeReadme: Bool = true
    var gitignoreTemplate: String? = nil
    var licenseTemplate: String? = nil
    var cloneLocally: Bool = false
    var localPath: String? = nil
    var addStarterActions: Bool = false
    var addIssueRoadmap: Bool = false
}

enum GHProjectTemplate: String, CaseIterable {
    case empty       = "empty"
    case swiftMacOS  = "swift_macos"
    case android     = "android_kotlin"
    case react       = "react"
    case node        = "node"
    case python      = "python"
    case website     = "website"

    var displayName: String {
        switch self {
        case .empty:       return "Empty"
        case .swiftMacOS:  return "Swift / macOS"
        case .android:     return "Android / Kotlin"
        case .react:       return "React"
        case .node:        return "Node.js"
        case .python:      return "Python"
        case .website:     return "Website"
        }
    }

    var gitignore: String? {
        switch self {
        case .swiftMacOS: return "Swift"
        case .android:    return "Android"
        case .node:       return "Node"
        case .python:     return "Python"
        case .react:      return "Node"
        case .website:    return nil
        case .empty:      return nil
        }
    }

    var readmeContent: (String) -> String {
        return { name in
            "# \(name)\n\nCreated by Jarvis.\n"
        }
    }
}
