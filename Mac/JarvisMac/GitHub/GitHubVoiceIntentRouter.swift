import Foundation

// MARK: - GitHubVoiceIntentRouter
// Maps natural-language voice commands to GitHub operations.
// Returns a GitHubVoiceIntent that JarvisController can execute.

final class GitHubVoiceIntentRouter {

    // MARK: - Resolve

    static func resolve(_ transcript: String) -> GitHubVoiceIntent? {
        let t = transcript.lowercased().trimmingCharacters(in: .whitespaces)

        // ── Notifications / alerts ──────────────────────────────
        if matches(t, any: ["check github", "github notifications", "github alerts",
                             "what's on github", "github status"]) {
            return .checkNotifications
        }

        // ── PRs ─────────────────────────────────────────────────
        if matches(t, any: ["open prs", "open pull requests", "check prs", "pull requests",
                             "list prs", "show prs", "any prs"]) {
            return .listPRs(repo: extractRepo(t))
        }
        if matches(t, any: ["review pr", "review latest pr", "review pull request",
                             "review the pr", "look at the pr", "check the pr"]) {
            let num = extractNumber(t)
            return .reviewPR(repo: extractRepo(t), number: num)
        }
        if matches(t, any: ["open a pr", "create a pr", "make a pr", "open pull request",
                             "create pull request"]) {
            return .openPR(repo: extractRepo(t))
        }
        if matches(t, any: ["comment on pr", "add comment to pr", "reply to pr"]) {
            return .commentOnPR(repo: extractRepo(t), number: extractNumber(t), body: extractQuotedText(t))
        }
        if matches(t, any: ["stale prs", "stale pull requests", "old prs", "unreviewed prs"]) {
            return .stalePRs(repo: extractRepo(t))
        }
        if matches(t, any: ["large prs", "big pull requests", "huge pr"]) {
            return .largePRs(repo: extractRepo(t))
        }

        // ── Issues ───────────────────────────────────────────────
        if matches(t, any: ["check issues", "open issues", "list issues", "show issues",
                             "any issues", "what issues"]) {
            return .listIssues(repo: extractRepo(t))
        }
        if matches(t, any: ["stale issues", "old issues", "neglected issues"]) {
            return .staleIssues(repo: extractRepo(t))
        }
        if matches(t, any: ["open an issue", "create an issue", "file an issue",
                             "open issue", "create issue", "new issue"]) {
            return .createIssue(repo: extractRepo(t), title: extractQuotedText(t))
        }
        if matches(t, any: ["comment on issue", "reply to issue", "add comment"]) {
            return .commentOnIssue(repo: extractRepo(t), number: extractNumber(t), body: extractQuotedText(t))
        }
        if matches(t, any: ["close issue"]) {
            return .closeIssue(repo: extractRepo(t), number: extractNumber(t))
        }

        // ── Commits ──────────────────────────────────────────────
        if matches(t, any: ["latest commit", "last commit", "recent commits", "what changed",
                             "what's new", "recent changes", "commits today"]) {
            return .recentCommits(repo: extractRepo(t))
        }
        if matches(t, any: ["what changed today", "changes today", "today's commits"]) {
            return .changestoday(repo: extractRepo(t))
        }
        if matches(t, any: ["what changed since yesterday", "yesterday's changes",
                             "changes since yesterday"]) {
            return .changesSince(repo: extractRepo(t), days: 1)
        }
        if matches(t, any: ["what changed this week", "this week's changes"]) {
            return .changesSince(repo: extractRepo(t), days: 7)
        }

        // ── CI / Actions ─────────────────────────────────────────
        if matches(t, any: ["failing builds", "failed builds", "broken build", "build status",
                             "ci status", "any failures", "failing ci"]) {
            return .checkCI(repo: extractRepo(t))
        }
        if matches(t, any: ["build passing", "is ci passing", "is build passing"]) {
            return .checkCI(repo: extractRepo(t))
        }

        // ── Repos ────────────────────────────────────────────────
        if matches(t, any: ["my repos", "list repos", "show repos", "all repos", "my repositories"]) {
            return .listMyRepos
        }
        if matches(t, any: ["active repos", "most active", "which repo is most active"]) {
            return .activeRepos
        }
        if matches(t, any: ["neglected repos", "stale repos", "abandoned repos",
                             "what repos need attention", "which repos need attention"]) {
            return .neglectedRepos
        }
        if matches(t, any: ["create a repo", "make a repo", "new repo", "new repository",
                             "create repository", "start a project", "start project",
                             "let's start a new project", "new project"]) {
            return .createRepo(name: extractRepoName(t))
        }
        if matches(t, any: ["explain repo", "describe repo", "repo structure",
                             "explain this repo", "what's in"]) {
            return .describeRepo(repo: extractRepo(t))
        }

        // ── Roadmap ──────────────────────────────────────────────
        if matches(t, any: ["project progress", "how far are we", "roadmap", "milestone",
                             "project status", "what's left", "what's blocking",
                             "blocking the"]) {
            return .projectStatus(repo: extractRepo(t))
        }
        if matches(t, any: ["summarize project", "summarise project", "project summary",
                             "how's the project going"]) {
            return .projectStatus(repo: extractRepo(t))
        }

        // ── Code Review ──────────────────────────────────────────
        if matches(t, any: ["review code", "any risky code", "risky code", "risky files",
                             "code quality", "thoughts on the code", "code review"]) {
            return .codeReview(repo: extractRepo(t))
        }
        if matches(t, any: ["summarize diff", "summarise diff", "what's in this diff",
                             "explain diff", "diff summary"]) {
            return .summariseDiff(repo: extractRepo(t), base: nil, head: nil)
        }

        // ── Dashboard ────────────────────────────────────────────
        if matches(t, any: ["show github dashboard", "github dashboard", "open github",
                             "show github", "github panel"]) {
            return .showDashboard
        }

        // ── Local Index ──────────────────────────────────────────
        if matches(t, any: ["index repo", "scan repo", "analyse local", "analyze local"]) {
            return .indexLocalRepo(path: extractPath(t))
        }
        if matches(t, any: ["todo count", "how many todos", "fixme count", "local stats"]) {
            return .localRepoStats(repo: extractRepo(t))
        }

        return nil
    }

    // MARK: - Extraction Helpers

    static func extractRepo(_ t: String) -> String? {
        // Patterns: "in jarvis repo", "for android", "the shopify repo"
        let patterns = ["in the (\\S+) repo", "for (\\S+) repo", "the (\\S+) repo",
                        "in (\\S+)", "for (\\S+) project"]
        for pattern in patterns {
            if let m = t.range(of: pattern, options: .regularExpression),
               let capture = firstGroup(of: pattern, in: t) {
                let _ = m  // suppress warning
                let clean = capture.replacingOccurrences(of: "repo", with: "").trimmingCharacters(in: .whitespaces)
                if !clean.isEmpty && !stopWords.contains(clean) { return clean }
            }
        }
        return nil
    }

    static func extractNumber(_ t: String) -> Int? {
        if let match = t.range(of: "#(\\d+)", options: .regularExpression) {
            return Int(t[match].dropFirst())
        }
        if let match = t.range(of: "number (\\d+)", options: .regularExpression),
           let num = firstGroup(of: "number (\\d+)", in: t) {
            return Int(num)
        }
        return nil
    }

    static func extractQuotedText(_ t: String) -> String? {
        // Extract content between quotes or after "saying"
        if let m = t.range(of: "\"([^\"]+)\"", options: .regularExpression),
           let content = firstGroup(of: "\"([^\"]+)\"", in: t) {
            _ = m
            return content
        }
        if let sayingRange = t.range(of: "saying ") {
            return String(t[sayingRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    static func extractRepoName(_ t: String) -> String? {
        let patterns = ["called (\\S+)", "named (\\S+)", "name (\\S+)"]
        for pattern in patterns {
            if let name = firstGroup(of: pattern, in: t) { return name }
        }
        return nil
    }

    static func extractPath(_ t: String) -> String? {
        if let m = t.range(of: "/[^ ]+", options: .regularExpression) {
            return String(t[m])
        }
        return nil
    }

    // MARK: - Private

    private static let stopWords: Set<String> = ["my", "the", "a", "an", "this", "that"]

    private static func matches(_ t: String, any phrases: [String]) -> Bool {
        phrases.contains(where: { t.contains($0) })
    }

    private static func firstGroup(of pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }
}

// MARK: - GitHubVoiceIntent

enum GitHubVoiceIntent: Equatable {
    // Read
    case checkNotifications
    case listMyRepos
    case activeRepos
    case neglectedRepos
    case listPRs(repo: String?)
    case listIssues(repo: String?)
    case stalePRs(repo: String?)
    case largePRs(repo: String?)
    case staleIssues(repo: String?)
    case recentCommits(repo: String?)
    case changestoday(repo: String?)
    case changesSince(repo: String?, days: Int)
    case checkCI(repo: String?)
    case describeRepo(repo: String?)
    case projectStatus(repo: String?)
    case reviewPR(repo: String?, number: Int?)
    case codeReview(repo: String?)
    case summariseDiff(repo: String?, base: String?, head: String?)
    case localRepoStats(repo: String?)

    // Write
    case createRepo(name: String?)
    case createIssue(repo: String?, title: String?)
    case commentOnIssue(repo: String?, number: Int?, body: String?)
    case closeIssue(repo: String?, number: Int?)
    case openPR(repo: String?)
    case commentOnPR(repo: String?, number: Int?, body: String?)

    // UI
    case showDashboard
    case indexLocalRepo(path: String?)

    static func == (lhs: GitHubVoiceIntent, rhs: GitHubVoiceIntent) -> Bool {
        // Simple string equality on label — sufficient for de-dup
        "\(lhs)" == "\(rhs)"
    }
}
