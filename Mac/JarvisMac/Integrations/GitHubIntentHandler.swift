import Foundation

/// Handles GitHub-domain intents previously inline in JarvisController.execute().
/// Extracted following the per-domain handler pattern — Sprint Q decomposition.
@MainActor final class GitHubIntentHandler {

    private let renderer: ResponseRenderer
    private let prefs: PreferencesStore

    var speak: (String) -> Void = { _ in }
    var openOverlay: (OverlayKind) -> Void = { _ in }
    /// Closure returning the current GitHubModule (may be nil if not configured).
    var getModule: () -> GitHubModule? = { nil }

    init(renderer: ResponseRenderer, prefs: PreferencesStore) {
        self.renderer = renderer
        self.prefs = prefs
    }

    /// Returns true if the intent was handled, false if it is not a GitHub intent.
    func handle(_ intent: Intent) -> Bool {
        switch intent {

        case .showGitHubOverlay:
            openOverlay(.github)
            speak(renderer.render(ResponseKey.githubOverlayOpened))
            return true

        case .checkGitHub:
            Task {
                guard let token = prefs.githubPersonalAccessToken, !token.isEmpty else {
                    self.speak(self.renderer.render(ResponseKey.githubNotConfigured))
                    return
                }
                let client = GitHubAPIClient(token: token)
                do {
                    let notifications = try await client.getNotifications()
                    if notifications.isEmpty {
                        self.speak(self.renderer.render(ResponseKey.githubNone))
                    } else {
                        let count = notifications.count
                        let top = notifications.prefix(2).map { $0.subject.title }.joined(separator: ", ")
                        self.speak(self.renderer.render(ResponseKey.githubSummary, [
                            "count": "\(count)",
                            "plural": count == 1 ? "" : "s",
                            "top": top
                        ]))
                    }
                } catch {
                    self.speak("I couldn't check GitHub right now.")
                }
            }
            return true

        case .githubDashboard:
            openOverlay(.github)
            speak(renderer.render(ResponseKey.githubDashboardOpened))
            return true

        case .githubListPRs(let repo):
            executeTask { module in
                let fullName = try await module.resolveRepo(repo)
                let summary  = try await module.prMgr.spokenPRSummary(repo: fullName)
                self.speak(self.renderer.render(ResponseKey.githubPRsSummary, ["summary": summary]))
                self.openOverlay(.github)
            }
            return true

        case .githubReviewPR(let repo, let number):
            executeTask { module in
                let fullName = try await module.resolveRepo(repo)
                let prs = try await module.prMgr.openPRs(repo: fullName)
                let prNum = number ?? prs.first?.number
                guard let n = prNum else {
                    self.speak("No open PRs found in \(fullName.components(separatedBy: "/").last ?? fullName).")
                    return
                }
                let result = try await module.reviewEngine.reviewPR(repo: fullName, number: n)
                let summary = module.reviewEngine.spokenReviewSummary(result: result)
                self.speak(self.renderer.render(ResponseKey.githubCodeReviewDone, ["summary": summary]))
            }
            return true

        case .githubOpenPR:
            guard getModule() != nil else {
                speak(renderer.render(ResponseKey.githubNotConfigured)); return true
            }
            speak("To open a PR, tell me the title, and I'll need the head branch name.")
            return true

        case .githubStalePRs(let repo):
            executeTask { module in
                let fullName = try await module.resolveRepo(repo)
                let stale = try await module.prMgr.stalePRs(repo: fullName)
                let repoShort = fullName.components(separatedBy: "/").last ?? fullName
                if stale.isEmpty {
                    self.speak("No stale PRs in \(repoShort).")
                } else {
                    let titles = stale.prefix(3).map { "\($0.title) (#\($0.number))" }.joined(separator: "; ")
                    self.speak("\(stale.count) stale PR\(stale.count == 1 ? "" : "s") in \(repoShort): \(titles).")
                }
            }
            return true

        case .githubListIssues(let repo):
            executeTask { module in
                let fullName = try await module.resolveRepo(repo)
                let summary  = try await module.issueMgr.spokenIssueSummary(repo: fullName)
                self.speak(self.renderer.render(ResponseKey.githubIssuesSummary, ["summary": summary]))
            }
            return true

        case .githubStaleIssues(let repo):
            executeTask { module in
                let fullName = try await module.resolveRepo(repo)
                let summary  = try await module.issueMgr.spokenStaleIssues(repo: fullName)
                self.speak(summary)
            }
            return true

        case .githubCreateIssue(let repo, let title):
            guard let module = getModule() else {
                speak(renderer.render(ResponseKey.githubNotConfigured)); return true
            }
            if let t = title {
                Task {
                    let fullName = (try? await module.resolveRepo(repo)) ?? ""
                    module.issueMgr.createIssue(repo: fullName, title: t, body: nil, labels: nil) { success in
                        if success {
                            self.speak(self.renderer.render(ResponseKey.githubIssueCreated,
                                ["summary": "'\(t)' filed in \(fullName.components(separatedBy: "/").last ?? fullName)."]))
                        } else {
                            self.speak("Couldn't create the issue. Check your token permissions.")
                        }
                    }
                }
            } else {
                speak("What should I title the issue?")
            }
            return true

        case .githubRecentCommits(let repo):
            executeTask { module in
                let fullName = try await module.resolveRepo(repo)
                let commits  = try await module.repoMgr.recentCommits(repo: fullName, limit: 5)
                let repoShort = fullName.components(separatedBy: "/").last ?? fullName
                if commits.isEmpty {
                    self.speak("No recent commits found in \(repoShort).")
                } else {
                    let msgs = commits.prefix(3).map(\.title).joined(separator: "; ")
                    self.speak("\(commits.count) recent commit\(commits.count == 1 ? "" : "s") in \(repoShort): \(msgs).")
                }
            }
            return true

        case .githubChangesToday(let repo):
            executeTask { module in
                let fullName = try await module.resolveRepo(repo)
                let since = Calendar.current.startOfDay(for: Date())
                let summary  = try await module.repoMgr.spokenRecentChanges(repo: fullName, since: since)
                self.speak(summary)
            }
            return true

        case .githubChangesSince(let repo, let days):
            executeTask { module in
                let fullName = try await module.resolveRepo(repo)
                let since = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
                let summary  = try await module.repoMgr.spokenRecentChanges(repo: fullName, since: since)
                self.speak(summary)
            }
            return true

        case .githubCheckCI(let repo):
            executeTask { module in
                let fullName = try await module.resolveRepo(repo)
                let summary  = try await module.actionsMgr.spokenCIStatus(repo: fullName)
                self.speak(self.renderer.render(ResponseKey.githubCISummary, ["summary": summary]))
            }
            return true

        case .githubListMyRepos:
            executeTask { module in
                let repos = try await module.repoMgr.myRepos()
                if repos.isEmpty {
                    self.speak("No repositories found.")
                } else {
                    let names = repos.prefix(5).map(\.name).joined(separator: ", ")
                    self.speak("Your top repos: \(names)\(repos.count > 5 ? " and \(repos.count - 5) more." : ".")")
                }
            }
            return true

        case .githubActiveRepos:
            executeTask { module in
                let repos = try await module.repoMgr.activeRepos(limit: 5)
                let names = repos.map(\.name).joined(separator: ", ")
                self.speak("Most active repos: \(names).")
            }
            return true

        case .githubNeglectedRepos:
            executeTask { module in
                let summary = try await module.repoMgr.spokenNeglectedRepos()
                self.speak(self.renderer.render(ResponseKey.githubNeglected, ["summary": summary]))
            }
            return true

        case .githubCreateRepo(let name):
            guard let module = getModule() else {
                speak(renderer.render(ResponseKey.githubNotConfigured)); return true
            }
            if let n = name {
                speak(renderer.render(ResponseKey.githubRepoCreating, ["name": n]))
                Task {
                    let result = await module.projectMgr.confirmAndCreate(
                        session: module.projectMgr.startSessionWithName(n)
                    )
                    let summary = module.projectMgr.spokenCreationResult(result, name: n)
                    self.speak(self.renderer.render(ResponseKey.githubRepoCreated, ["summary": summary]))
                }
            } else {
                let session = module.projectMgr.startSession()
                if let q = module.projectMgr.nextQuestion(for: session) {
                    speak(renderer.render(ResponseKey.githubWizardNextQ, ["question": q]))
                }
            }
            return true

        case .githubDescribeRepo(let repo):
            executeTask { module in
                let fullName = try await module.resolveRepo(repo)
                let desc     = try await module.reviewEngine.describeRepoStructure(repo: fullName)
                self.speak(self.renderer.render(ResponseKey.githubRepoSummary, ["summary": desc]))
            }
            return true

        case .githubProjectStatus(let repo):
            executeTask { module in
                let fullName = try await module.resolveRepo(repo)
                let analysis = try await module.roadmapMgr.analyze(repo: fullName)
                let summary  = module.roadmapMgr.spokenAnalysis(analysis)
                self.speak(self.renderer.render(ResponseKey.githubProjectStatus, ["summary": summary]))
            }
            return true

        case .githubCodeReview(let repo):
            executeTask { module in
                let fullName = try await module.resolveRepo(repo)
                let prs = try await module.prMgr.openPRs(repo: fullName)
                guard let pr = prs.first else {
                    self.speak("No open PRs to review in \(fullName.components(separatedBy: "/").last ?? fullName).")
                    return
                }
                let result = try await module.reviewEngine.reviewPR(repo: fullName, number: pr.number)
                let summary = module.reviewEngine.spokenReviewSummary(result: result)
                self.speak(self.renderer.render(ResponseKey.githubCodeReviewDone, ["summary": summary]))
            }
            return true

        case .githubSummariseDiff(let repo):
            executeTask { module in
                let fullName  = try await module.resolveRepo(repo)
                let repoInfo  = try await module.repoMgr.getRepo(fullName)
                let base      = repoInfo.default_branch
                let branches  = try await module.repoMgr.branches(repo: fullName)
                let head = branches.first(where: { $0.name != base })?.name ?? base
                let summary = try await module.reviewEngine.summariseDiff(repo: fullName, base: base, head: head)
                self.speak(summary)
            }
            return true

        case .githubLocalStats(let repo):
            guard getModule() != nil else {
                speak(renderer.render(ResponseKey.githubNotConfigured)); return true
            }
            let name = repo ?? ""
            let summary = GitHubLocalRepoIndex.shared.spokenSnapshot(fullName: name)
            speak(summary)
            return true

        default:
            return false
        }
    }

    private func executeTask(_ work: @escaping (GitHubModule) async throws -> Void) {
        guard let module = getModule() else {
            speak(renderer.render(ResponseKey.githubNotConfigured))
            return
        }
        Task {
            do {
                try await work(module)
            } catch let e as GHError {
                self.speak(self.renderer.render(ResponseKey.githubError, ["error": e.localizedDescription]))
            } catch {
                self.speak(self.renderer.render(ResponseKey.githubError, ["error": error.localizedDescription]))
            }
        }
    }
}
