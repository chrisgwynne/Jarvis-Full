import Foundation

// MARK: - GitHubCodeReviewEngine
// AI-powered pull request analysis. Uses LLM when available;
// falls back to heuristic analysis when not.

@MainActor
final class GitHubCodeReviewEngine {
    private let client:  GitHubAPIClient
    private let prMgr:   GitHubPRManager
    private let repoMgr: GitHubRepoManager
    private weak var llmRouter: GHLLMCapable?

    init(client: GitHubAPIClient, prMgr: GitHubPRManager, repoMgr: GitHubRepoManager, llmRouter: GHLLMCapable?) {
        self.client   = client
        self.prMgr    = prMgr
        self.repoMgr  = repoMgr
        self.llmRouter = llmRouter
    }

    // MARK: - Full PR Review

    func reviewPR(repo: String, number: Int) async throws -> GHCodeReviewResult {
        let pr     = try await prMgr.getPR(repo: repo, number: number)
        let files  = try await prMgr.getPRFiles(repo: repo, number: number)
        let reviews = (try? await prMgr.getPRReviews(repo: repo, number: number)) ?? []

        let riskyFiles   = files.filter(\.isRisky).map(\.filename)
        let addedLines   = files.reduce(0) { $0 + $1.additions }
        let deletedLines = files.reduce(0) { $0 + $1.deletions }
        let todoMatches  = extractTODOs(from: files)
        let regRisk      = regressionRisk(files: files, pr: pr)
        let archImpact   = architecturalImpact(files: files)
        let testNote     = testCoverageNote(files: files)

        // Try LLM summary first
        let summary: String
        if let llm = llmRouter {
            let prompt = buildReviewPrompt(pr: pr, files: files, reviews: reviews,
                                           addedLines: addedLines, deletedLines: deletedLines)
            summary = (try? await llm.complete(prompt: prompt, maxTokens: 300)) ?? heuristicSummary(pr: pr, files: files)
        } else {
            summary = heuristicSummary(pr: pr, files: files)
        }

        let findings = buildKeyFindings(pr: pr, files: files, reviews: reviews, riskyFiles: riskyFiles)

        return GHCodeReviewResult(
            prNumber: pr.number,
            repoFullName: repo,
            summary: summary,
            riskyFiles: riskyFiles,
            regressionRisk: regRisk,
            architecturalImpact: archImpact,
            testCoverageNote: testNote,
            todosAdded: todoMatches,
            keyFindings: findings,
            generatedAt: Date()
        )
    }

    // MARK: - Quick Diff Summary

    func summariseDiff(repo: String, base: String, head: String) async throws -> String {
        let comparison = try await client.compareBranches(repo: repo, base: base, head: head)
        let files = comparison.files ?? []
        let commits = comparison.commits

        var text = "\(comparison.ahead_by) commit\(comparison.ahead_by == 1 ? "" : "s") ahead"
        if comparison.behind_by > 0 { text += ", \(comparison.behind_by) behind" }
        text += ". \(files.count) file\(files.count == 1 ? "" : "s") changed"

        let added   = files.reduce(0) { $0 + $1.additions }
        let deleted = files.reduce(0) { $0 + $1.deletions }
        text += " (+\(added)/-\(deleted) lines)."

        if !commits.isEmpty {
            let msgs = commits.prefix(3).map(\.title).joined(separator: "; ")
            text += " Commits: \(msgs)."
        }

        let risky = files.filter(\.isRisky)
        if !risky.isEmpty {
            text += " Watch: \(risky.prefix(2).map(\.filename).joined(separator: ", "))."
        }
        return text
    }

    // MARK: - Spoken

    func spokenReviewSummary(result: GHCodeReviewResult) -> String {
        var text = result.summary
        if !result.riskyFiles.isEmpty {
            text += " Watch \(result.riskyFiles.prefix(2).joined(separator: " and "))."
        }
        text += " Regression risk: \(result.regressionRisk)."
        if !result.todosAdded.isEmpty {
            text += " \(result.todosAdded.count) new TODO\(result.todosAdded.count == 1 ? "" : "s") added."
        }
        return text
    }

    // MARK: - Architecture Understanding

    func describeRepoStructure(repo: String) async throws -> String {
        let branches = try await repoMgr.branches(repo: repo)
        let prs      = try await prMgr.openPRs(repo: repo)
        let commits  = try await repoMgr.recentCommits(repo: repo, limit: 5)
        let info     = try await repoMgr.getRepo(repo)

        var text = "\(info.name)"
        if let lang = info.language { text += " is a \(lang) project." } else { text += "." }
        text += " \(branches.count) branch\(branches.count == 1 ? "" : "es"), "
        text += "\(prs.count) open PR\(prs.count == 1 ? "" : "s"), "
        text += "\(info.open_issues_count) open issue\(info.open_issues_count == 1 ? "" : "s")."
        if let latest = commits.first {
            text += " Latest: \(latest.title) by \(latest.author?.login ?? latest.commit.author.name)."
        }
        return text
    }

    // MARK: - Heuristics

    private func regressionRisk(files: [GHFileDiff], pr: GHPullRequest) -> String {
        let changedFiles = pr.changed_files ?? 0
        let totalLines = (pr.additions ?? 0) + (pr.deletions ?? 0)
        let hasTestChanges = files.contains { $0.filename.lowercased().contains("test") }
        let hasRiskyFiles = files.contains(where: \.isRisky)

        if changedFiles > 20 || totalLines > 1000 { return "high" }
        if hasRiskyFiles && !hasTestChanges       { return "medium" }
        if changedFiles > 5                        { return "medium" }
        return "low"
    }

    private func architecturalImpact(files: [GHFileDiff]) -> String {
        let hasPackage   = files.contains { $0.filename.contains("Package.swift") || $0.filename.contains("Podfile") }
        let hasSchema    = files.contains { $0.filename.lowercased().contains("schema") || $0.filename.lowercased().contains("migration") }
        let hasConfig    = files.contains { $0.filename.lowercased().contains("config") || $0.filename.lowercased().contains(".yml") }
        let manyFiles    = files.count > 15

        if hasPackage || hasSchema { return "significant — dependency or schema changes" }
        if manyFiles || hasConfig  { return "moderate — multi-file changes" }
        return "minimal"
    }

    private func testCoverageNote(files: [GHFileDiff]) -> String {
        let testFiles   = files.filter { $0.filename.lowercased().contains("test") }
        let sourceFiles = files.filter { !$0.filename.lowercased().contains("test") }
        if testFiles.isEmpty && !sourceFiles.isEmpty { return "No test files changed — consider adding tests" }
        if testFiles.count >= sourceFiles.count      { return "Good test coverage in this PR" }
        return "Some test coverage included"
    }

    private func extractTODOs(from files: [GHFileDiff]) -> [String] {
        files.compactMap { file -> String? in
            guard let patch = file.patch else { return nil }
            let lines = patch.components(separatedBy: "\n")
            let todos = lines.filter { $0.hasPrefix("+") && (
                $0.uppercased().contains("TODO") || $0.uppercased().contains("FIXME") || $0.uppercased().contains("HACK")
            )}
            if todos.isEmpty { return nil }
            return "\(file.filename): \(todos.count) TODO/FIXME"
        }
    }

    private func buildKeyFindings(pr: GHPullRequest, files: [GHFileDiff],
                                   reviews: [GHReview], riskyFiles: [String]) -> [String] {
        var findings: [String] = []
        if pr.isDraft          { findings.append("Draft PR — not ready for merge") }
        if pr.sizeLabel == "large" { findings.append("Large PR (\(pr.changed_files ?? 0) files, \((pr.additions ?? 0) + (pr.deletions ?? 0)) lines)") }
        if !riskyFiles.isEmpty { findings.append("Risky files changed: \(riskyFiles.prefix(3).joined(separator: ", "))") }
        if reviews.filter({ $0.state == "CHANGES_REQUESTED" }).count > 0 {
            findings.append("Changes requested by reviewer(s)")
        }
        if reviews.filter({ $0.state == "APPROVED" }).count > 0 {
            findings.append("Approved by \(reviews.filter({ $0.state == "APPROVED" }).count) reviewer(s)")
        }
        return findings
    }

    private func heuristicSummary(pr: GHPullRequest, files: [GHFileDiff]) -> String {
        let added   = pr.additions ?? 0
        let deleted = pr.deletions ?? 0
        let changed = pr.changed_files ?? 0
        return "PR #\(pr.number) '\(pr.title)' changes \(changed) file\(changed == 1 ? "" : "s"), +\(added)/-\(deleted) lines."
    }

    private func buildReviewPrompt(pr: GHPullRequest, files: [GHFileDiff],
                                    reviews: [GHReview], addedLines: Int, deletedLines: Int) -> String {
        let fileList = files.prefix(10).map { "\($0.filename) (+\($0.additions)/-\($0.deletions))" }.joined(separator: "\n")
        let patchSamples = files.prefix(3).compactMap { f -> String? in
            guard let p = f.patch else { return nil }
            return "FILE: \(f.filename)\n\(String(p.prefix(500)))"
        }.joined(separator: "\n---\n")

        return """
        You are a senior software engineer reviewing a GitHub pull request.

        PR #\(pr.number): \(pr.title)
        Author: \(pr.user?.login ?? "unknown")
        Base: \(pr.base.ref) ← Head: \(pr.head.ref)
        Changes: +\(addedLines)/-\(deletedLines) lines across \(files.count) files

        Files changed:
        \(fileList)

        Diff samples:
        \(patchSamples)

        Provide a concise 2-3 sentence review summary: what this PR does, main risks, and recommendation. Be specific and developer-focused.
        """
    }
}

// MARK: - GHLLMCapable
// Thin protocol so GitHubCodeReviewEngine can call the LLM without
// importing the concrete LLMRouter class (avoids name collision).
protocol GHLLMCapable: AnyObject {
    func complete(prompt: String, maxTokens: Int) async throws -> String
}
