import Foundation

// MARK: - GitHubRoadmapAnalyzer
// Derives project health and progress from issues, PRs, milestones, and CI.

@MainActor
final class GitHubRoadmapAnalyzer {
    private let issueMgr:   GitHubIssueManager
    private let prMgr:      GitHubPRManager
    private let actionsMgr: GitHubActionsManager
    private let repoMgr:    GitHubRepoManager

    init(issueMgr: GitHubIssueManager, prMgr: GitHubPRManager,
         actionsMgr: GitHubActionsManager, repoMgr: GitHubRepoManager) {
        self.issueMgr   = issueMgr
        self.prMgr       = prMgr
        self.actionsMgr  = actionsMgr
        self.repoMgr     = repoMgr
    }

    // MARK: - Full Analysis

    func analyze(repo: String) async throws -> GHRoadmapAnalysis {
        async let openIssues   = issueMgr.openIssues(repo: repo)
        async let milestones   = issueMgr.milestones(repo: repo)
        async let openPRs      = prMgr.openPRs(repo: repo)
        async let repoInfo     = repoMgr.getRepo(repo)

        let issues = try await openIssues
        let ms     = try await milestones
        let prs    = try await openPRs
        let info   = try await repoInfo

        // Closed issues from milestones (already have ratio)
        let activeMilestone = ms.first

        let totalIssues  = info.open_issues_count
        let closedEst    = activeMilestone.map(\.closed_issues) ?? 0
        let openEst      = activeMilestone.map(\.open_issues) ?? totalIssues
        let completion   = activeMilestone?.completionPercent ?? 0

        let stalePRs    = prs.filter(\.isStale)
        let staleIssues = issues.filter(\.isStale)
        let velocity    = velocityEstimate(issues: issues, prs: prs, repoInfo: info)
        let blockers    = detectBlockers(issues: issues, prs: prs)

        let summary = buildSummary(repo: repo, issues: issues, prs: prs,
                                   milestone: activeMilestone, velocity: velocity,
                                   completion: completion)

        return GHRoadmapAnalysis(
            repoFullName: repo,
            completionPercent: completion,
            openIssues: openEst,
            closedIssues: closedEst,
            openPRs: prs.count,
            stalePRs: stalePRs.count,
            staleIssues: staleIssues.count,
            activeMilestone: activeMilestone,
            velocityEstimate: velocity,
            topBlockers: blockers,
            summary: summary,
            generatedAt: Date()
        )
    }

    // MARK: - Multi-Repo Health Check

    func healthCheckAll(repos: [String]) async throws -> [(repo: String, status: String)] {
        var results: [(String, String)] = []
        for repo in repos {
            let status: String
            do {
                let analysis = try await analyze(repo: repo)
                if analysis.velocityEstimate == "stalled" {
                    status = "⚠️ stalled"
                } else if analysis.stalePRs > 2 {
                    status = "⚠️ stale PRs"
                } else if analysis.openIssues > 20 {
                    status = "📋 high issue count"
                } else {
                    status = "✅ healthy"
                }
            } catch {
                status = "❌ error"
            }
            results.append((repo, status))
        }
        return results
    }

    // MARK: - Spoken

    func spokenAnalysis(_ analysis: GHRoadmapAnalysis) -> String {
        var text = analysis.summary
        if let m = analysis.activeMilestone {
            text += " Active milestone: \(m.title) at \(Int(m.completionPercent))%."
        }
        if !analysis.topBlockers.isEmpty {
            text += " Blockers: \(analysis.topBlockers.prefix(2).joined(separator: "; "))."
        }
        return text
    }

    func spokenProgress(repo: String) async throws -> String {
        let analysis = try await analyze(repo: repo)
        return spokenAnalysis(analysis)
    }

    // MARK: - Heuristics

    private func velocityEstimate(issues: [GHIssue], prs: [GHPullRequest], repoInfo: GHRepo) -> String {
        let days = repoInfo.daysSinceLastPush ?? 999
        if days > 60              { return "stalled" }
        if days > 14              { return "low" }
        if prs.count > 5 || days < 2 { return "high" }
        return "medium"
    }

    private func detectBlockers(issues: [GHIssue], prs: [GHPullRequest]) -> [String] {
        var blockers: [String] = []

        let blockerIssues = issues.filter { issue in
            let titleLower = issue.title.lowercased()
            return titleLower.contains("block") || titleLower.contains("block") ||
                   issue.labels.contains(where: { $0.name.lowercased().contains("block") || $0.name == "P0" })
        }
        blockers.append(contentsOf: blockerIssues.prefix(2).map { "#\($0.number): \($0.title)" })

        let changesRequested = prs.filter { pr in
            pr.review_comments > 0 && pr.isOpen && !pr.isDraft
        }
        if changesRequested.count > 2 {
            blockers.append("\(changesRequested.count) PRs awaiting review")
        }
        return blockers
    }

    private func buildSummary(repo: String, issues: [GHIssue], prs: [GHPullRequest],
                               milestone: GHMilestone?, velocity: String,
                               completion: Double) -> String {
        let repoShort = repo.components(separatedBy: "/").last ?? repo
        var text = "\(repoShort) has \(issues.count) open issue\(issues.count == 1 ? "" : "s") and \(prs.count) open PR\(prs.count == 1 ? "" : "s")."
        text += " Development velocity: \(velocity)."
        if let m = milestone, m.completionPercent > 0 {
            text += " Milestone '\(m.title)' is \(Int(m.completionPercent))% complete."
        }
        return text
    }
}
