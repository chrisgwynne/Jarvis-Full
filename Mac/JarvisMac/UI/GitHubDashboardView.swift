import SwiftUI
import AppKit

// MARK: - GitHubDashboardView
// Rich GitHub intelligence dashboard overlay.
// Replaces the old GitHubOverlayView (which showed only notifications).

struct GitHubDashboardView: View {
    let module: GitHubModule

    @State private var selectedTab: DashTab = .overview
    @State private var repos: [GHRepo] = []
    @State private var notifications: [GHNotification] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    enum DashTab: String, CaseIterable {
        case overview  = "Overview"
        case prs       = "PRs"
        case issues    = "Issues"
        case ci        = "CI"
        case alerts    = "Alerts"
    }

    var body: some View {
        VStack(spacing: 0) {
            dashHeader
            tabBar
            Divider().opacity(0.3)
            tabContent
        }
        .task { await loadAll() }
    }

    // MARK: - Header

    private var dashHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .foregroundStyle(.purple)
                .font(.system(size: 14, weight: .semibold))
            Text("GitHub Intelligence")
                .font(.headline)
            Spacer()
            if isLoading {
                ProgressView().scaleEffect(0.7)
            } else {
                Button { Task { await loadAll(force: true) } } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(DashTab.allCases, id: \.rawValue) { tab in
                    Button { selectedTab = tab } label: {
                        Text(tab.rawValue)
                            .font(.system(size: 11, weight: selectedTab == tab ? .semibold : .regular))
                            .foregroundStyle(selectedTab == tab ? .purple : .secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(selectedTab == tab
                                ? Color.purple.opacity(0.12)
                                : Color.clear)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        if let error = errorMessage {
            ContentUnavailableView("Couldn't Load",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(error))
                .padding()
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    switch selectedTab {
                    case .overview: overviewTab
                    case .prs:      prsTab
                    case .issues:   issuesTab
                    case .ci:       ciTab
                    case .alerts:   alertsTab
                    }
                }
                .padding(.bottom, 12)
            }
        }
    }

    // MARK: - Overview Tab

    private var overviewTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Active repos strip
            if !repos.isEmpty {
                sectionHeader("ACTIVE REPOS", icon: "square.stack.3d.up", color: .purple)
                ForEach(repos.prefix(5)) { repo in
                    RepoRow(repo: repo)
                }
            }

            // Attention queue
            let attentionRepos = repos.filter { ($0.open_issues_count > 5) || (($0.daysSinceLastPush ?? 0) > 14 && !$0.archived) }
            if !attentionRepos.isEmpty {
                sectionHeader("NEEDS ATTENTION", icon: "exclamationmark.triangle", color: .orange)
                ForEach(attentionRepos.prefix(3)) { repo in
                    AttentionRow(repo: repo)
                }
            }

            // Notification summary
            if !notifications.isEmpty {
                sectionHeader("NOTIFICATIONS", icon: "bell.fill", color: .cyan)
                ForEach(notifications.prefix(3)) { n in
                    NotifRow(notif: n)
                }
            }
        }
    }

    // MARK: - PRs Tab

    private var prsTab: some View {
        PRsTabContent(module: module)
    }

    // MARK: - Issues Tab

    private var issuesTab: some View {
        IssuesTabContent(module: module, repos: repos)
    }

    // MARK: - CI Tab

    private var ciTab: some View {
        CITabContent(module: module, repos: repos)
    }

    // MARK: - Alerts Tab

    private var alertsTab: some View {
        AlertsTabContent(notifications: notifications)
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String, icon: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption2).foregroundStyle(color)
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 3)
    }

    // MARK: - Load

    private func loadAll(force: Bool = false) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        async let repoLoad  = module.repoMgr.myRepos(forceRefresh: force)
        async let notifLoad = module.client.getNotifications()
        do {
            repos         = try await repoLoad
            notifications = (try? await notifLoad) ?? []
        } catch {
            if repos.isEmpty { errorMessage = error.localizedDescription }
        }
        isLoading = false
    }
}

// MARK: - Row Sub-views

private struct RepoRow: View {
    let repo: GHRepo

    var body: some View {
        Button { NSWorkspace.shared.open(URL(string: repo.html_url)!) } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(repo.name).font(.system(size: 12, weight: .medium))
                        if repo.isPrivate {
                            Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    if let lang = repo.language {
                        Text(lang).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 6) {
                        Label("\(repo.open_issues_count)", systemImage: "exclamationmark.circle")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if let days = repo.daysSinceLastPush {
                        Text("\(days)d ago").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        Divider().opacity(0.1).padding(.horizontal, 12)
    }
}

private struct AttentionRow: View {
    let repo: GHRepo

    var reason: String {
        if let days = repo.daysSinceLastPush, days > 14 { return "Inactive \(days)d" }
        if repo.open_issues_count > 5 { return "\(repo.open_issues_count) open issues" }
        return "Needs attention"
    }

    var body: some View {
        HStack {
            Text(repo.name).font(.system(size: 12, weight: .medium))
            Spacer()
            Text(reason).font(.caption2).foregroundStyle(.orange)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        Divider().opacity(0.1).padding(.horizontal, 12)
    }
}

private struct NotifRow: View {
    let notif: GHNotification

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(reasonColor).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(notif.subject.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Text(notif.repository.full_name.components(separatedBy: "/").last ?? "")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        Divider().opacity(0.1).padding(.horizontal, 12)
    }

    var reasonColor: Color {
        switch notif.reason {
        case "review_requested": return .orange
        case "mention":          return .cyan
        case "assign":           return .blue
        default:                 return .secondary
        }
    }
}

// MARK: - PRs Tab Content

private struct PRsTabContent: View {
    let module: GitHubModule
    @State private var prsByRepo: [(String, [GHPullRequest])] = []
    @State private var isLoading = false

    var body: some View {
        Group {
            if isLoading {
                ProgressView().padding()
            } else if prsByRepo.isEmpty {
                ContentUnavailableView("No Open PRs", systemImage: "checkmark.seal.fill",
                                       description: Text("All clear.")).padding()
            } else {
                ForEach(prsByRepo, id: \.0) { (repo, prs) in
                    sectionHeader(repo.components(separatedBy: "/").last ?? repo, count: prs.count)
                    ForEach(prs) { pr in PRRow(pr: pr) }
                }
            }
        }
        .task { await load() }
    }

    private func sectionHeader(_ name: String, count: Int) -> some View {
        HStack {
            Text(name).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            Text("\(count) PR\(count == 1 ? "" : "s")")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 3)
    }

    private func load() async {
        isLoading = true
        let repos = (try? await module.repoMgr.myRepos()) ?? []
        var result: [(String, [GHPullRequest])] = []
        for repo in repos.prefix(5) {
            if let prs = try? await module.prMgr.openPRs(repo: repo.full_name), !prs.isEmpty {
                result.append((repo.full_name, prs))
            }
        }
        prsByRepo = result
        isLoading = false
    }
}

private struct PRRow: View {
    let pr: GHPullRequest

    var body: some View {
        Button { NSWorkspace.shared.open(URL(string: pr.html_url)!) } label: {
            HStack(spacing: 10) {
                Image(systemName: pr.isDraft ? "doc.badge.clock" : "arrow.triangle.pull")
                    .font(.caption).foregroundStyle(pr.isDraft ? AnyShapeStyle(.secondary) : AnyShapeStyle(.purple))
                VStack(alignment: .leading, spacing: 2) {
                    Text(pr.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    HStack(spacing: 6) {
                        Text("#\(pr.number)").font(.caption2).foregroundStyle(.secondary)
                        if pr.isDraft { Text("draft").font(.caption2).foregroundStyle(.secondary) }
                        if pr.isStale { Text("stale").font(.caption2).foregroundStyle(.orange) }
                    }
                }
                Spacer()
                Text(pr.sizeLabel).font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        Divider().opacity(0.1).padding(.horizontal, 12)
    }
}

// MARK: - Issues Tab Content

private struct IssuesTabContent: View {
    let module: GitHubModule
    let repos: [GHRepo]
    @State private var issuesByRepo: [(String, [GHIssue])] = []
    @State private var isLoading = false

    var body: some View {
        Group {
            if isLoading {
                ProgressView().padding()
            } else if issuesByRepo.isEmpty {
                ContentUnavailableView("No Open Issues", systemImage: "checkmark.seal.fill").padding()
            } else {
                ForEach(issuesByRepo, id: \.0) { (repo, issues) in
                    HStack {
                        Text(repo.components(separatedBy: "/").last ?? repo)
                            .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(issues.count)").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)

                    ForEach(issues.prefix(5)) { issue in IssueRow(issue: issue) }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        var result: [(String, [GHIssue])] = []
        for repo in repos.prefix(4) {
            if let issues = try? await module.issueMgr.openIssues(repo: repo.full_name), !issues.isEmpty {
                result.append((repo.full_name, Array(issues.prefix(5))))
            }
        }
        issuesByRepo = result
        isLoading = false
    }
}

private struct IssueRow: View {
    let issue: GHIssue

    var body: some View {
        Button { NSWorkspace.shared.open(URL(string: issue.html_url)!) } label: {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle").font(.caption).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(issue.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    HStack(spacing: 6) {
                        Text("#\(issue.number)").font(.caption2).foregroundStyle(.secondary)
                        if issue.isStale { Text("stale").font(.caption2).foregroundStyle(.orange) }
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        Divider().opacity(0.1).padding(.horizontal, 12)
    }
}

// MARK: - CI Tab Content

private struct CITabContent: View {
    let module: GitHubModule
    let repos: [GHRepo]
    @State private var ciByRepo: [(String, GitHubActionsManager.CIStatus)] = []
    @State private var isLoading = false

    var body: some View {
        Group {
            if isLoading {
                ProgressView().padding()
            } else {
                ForEach(ciByRepo, id: \.0) { (repo, status) in
                    HStack {
                        Circle().fill(statusColor(status)).frame(width: 8, height: 8)
                        Text(repo.components(separatedBy: "/").last ?? repo)
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text(statusLabel(status)).font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    Divider().opacity(0.1).padding(.horizontal, 12)
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        var result: [(String, GitHubActionsManager.CIStatus)] = []
        for repo in repos.prefix(6) {
            let status = (try? await module.actionsMgr.overallCIStatus(repo: repo.full_name)) ?? .unknown
            result.append((repo.full_name, status))
        }
        ciByRepo = result
        isLoading = false
    }

    private func statusColor(_ s: GitHubActionsManager.CIStatus) -> Color {
        switch s {
        case .passing:   return .green
        case .failing:   return .red
        case .running:   return .yellow
        case .unknown:   return .secondary
        }
    }

    private func statusLabel(_ s: GitHubActionsManager.CIStatus) -> String {
        switch s {
        case .passing:         return "passing"
        case .failing(let n):  return "\(n) failing"
        case .running:         return "running"
        case .unknown:         return "no data"
        }
    }
}

// MARK: - Alerts Tab Content

private struct AlertsTabContent: View {
    let notifications: [GHNotification]

    var body: some View {
        if notifications.isEmpty {
            ContentUnavailableView("No Notifications", systemImage: "checkmark.seal.fill",
                                   description: Text("You're all clear on GitHub.")).padding()
        } else {
            let reviewRequests = notifications.filter { $0.reason == "review_requested" }
            let assigned       = notifications.filter { $0.reason == "assign" }
            let mentions       = notifications.filter { $0.reason == "mention" }
            let other          = notifications.filter { !["review_requested","assign","mention"].contains($0.reason) }

            Group {
                if !reviewRequests.isEmpty {
                    alertSection("Review Requests", icon: "eye.circle.fill", color: .orange, items: reviewRequests)
                }
                if !assigned.isEmpty {
                    alertSection("Assigned", icon: "person.fill.checkmark", color: .blue, items: assigned)
                }
                if !mentions.isEmpty {
                    alertSection("Mentions", icon: "at", color: .cyan, items: mentions)
                }
                if !other.isEmpty {
                    alertSection("Other", icon: "bell.fill", color: .secondary, items: other)
                }
            }
        }
    }

    private func alertSection(_ title: String, icon: String, color: Color,
                               items: [GHNotification]) -> some View {
        Group {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption2).foregroundStyle(color)
                Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(items.count)").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)

            ForEach(items) { n in
                Button {
                    if let url = webURL(for: n) { NSWorkspace.shared.open(url) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(n.subject.title).font(.system(size: 11, weight: .medium)).lineLimit(2)
                            Text(n.repository.full_name.components(separatedBy: "/").last ?? "")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right.square").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                Divider().opacity(0.1).padding(.horizontal, 12)
            }
        }
    }

    private func webURL(for n: GHNotification) -> URL? {
        guard let api = n.subject.url else { return nil }
        let web = api
            .replacingOccurrences(of: "https://api.github.com/repos/", with: "https://github.com/")
            .replacingOccurrences(of: "/pulls/", with: "/pull/")
        return URL(string: web)
    }
}
