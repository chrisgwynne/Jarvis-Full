import SwiftUI

// MARK: - GitHubIntelligenceSettingsView
// Settings UI for the full GitHub Intelligence module.

struct GitHubIntelligenceSettingsView: View {
    let controller: JarvisController

    @State private var tokenDraft:  String = ""
    @State private var testResult:  String? = nil
    @State private var isTesting:   Bool = false
    @State private var allowedReposText: String = ""
    @State private var blockedReposText: String = ""
    @State private var showAuditLog: Bool = false

    private var prefs: PreferencesStore { controller.prefs }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                connectionSection
                safetySection
                localReposSection
                diagnosticsSection
            }
            .padding(24)
        }
        .onAppear {
            tokenDraft = prefs.githubPersonalAccessToken ?? ""
        }
    }

    // MARK: - Connection

    private var connectionSection: some View {
        card {
            Text("CONNECTION")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .tracking(1.5)

            HStack(spacing: 12) {
                Circle()
                    .fill(tokenDraft.isEmpty ? Color.red.opacity(0.8) : Color.green.opacity(0.8))
                    .frame(width: 8, height: 8)
                Text(tokenDraft.isEmpty ? "Not connected" : "Personal Access Token configured")
                    .font(.system(size: 12))
                    .foregroundStyle(tokenDraft.isEmpty ? .secondary : .primary)
            }

            SecureField("GitHub Personal Access Token", text: $tokenDraft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .onSubmit { saveToken() }

            Text("Required scopes: **repo**, **read:org**, **notifications**")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Save Token") { saveToken() }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .font(.system(size: 12))

                Button("Test Connection") {
                    Task { await testConnection() }
                }
                .buttonStyle(.bordered)
                .font(.system(size: 12))

                if isTesting { ProgressView().scaleEffect(0.7) }

                Spacer()

                Button("Clear") {
                    tokenDraft = ""
                    saveToken()
                }
                .foregroundStyle(.red)
                .buttonStyle(.plain)
                .font(.system(size: 11))
            }

            if let result = testResult {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(result.hasPrefix("✅") ? .green : .red)
                    .padding(.top, 2)
            }
        }
    }

    // MARK: - Safety

    private var safetySection: some View {
        card {
            Text("SAFETY & PERMISSIONS")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .tracking(1.5)

            Toggle("Trusted Mode (skip confirmation on write actions)",
                   isOn: Binding(
                    get: { GitHubSafetyManager.shared.trustedMode },
                    set: { GitHubSafetyManager.shared.trustedMode = $0 }
                   ))
            .font(.system(size: 12))

            Text("When off, all write operations require voice confirmation before executing. Destructive actions always require confirmation regardless of this setting.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider().opacity(0.3)

            VStack(alignment: .leading, spacing: 6) {
                Text("Allowed Repos (blank = all)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("owner/repo, owner/repo2", text: $allowedReposText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .onChange(of: allowedReposText) { _, v in
                        let repos = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                        GitHubSafetyManager.shared.allowedRepos = repos.isEmpty ? nil : Set(repos)
                    }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Blocked Repos")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("owner/dangerous-repo", text: $blockedReposText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .onChange(of: blockedReposText) { _, v in
                        let repos = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                        GitHubSafetyManager.shared.blockedRepos = Set(repos)
                    }
            }

            HStack {
                Button("View Audit Log (\(GitHubSafetyManager.shared.auditLog.count))") {
                    showAuditLog.toggle()
                }
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .foregroundStyle(.purple)
            }

            if showAuditLog {
                auditLogView
            }

            Text("NEVER: auto-merge, force-push, delete repos, expose secrets.")
                .font(.caption)
                .foregroundStyle(.orange.opacity(0.8))
                .padding(.top, 4)
        }
    }

    private var auditLogView: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(GitHubSafetyManager.shared.auditLog.suffix(10).reversed()) { entry in
                HStack {
                    Text(entry.outcome == "confirmed" ? "✅" : entry.outcome == "rejected" ? "❌" : "⚡️")
                    Text(entry.action)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Text(entry.at, style: .time)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(8)
        .background(Color.black.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Local Repos

    private var localReposSection: some View {
        card {
            Text("LOCAL REPO INDEX")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .tracking(1.5)

            let snaps = GitHubLocalRepoIndex.shared.snapshots
            if snaps.isEmpty {
                Text("No local repos indexed. Say 'index repo' with a local path to start.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snaps) { snap in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snap.fullName)
                                .font(.system(size: 11, weight: .medium))
                            Text(snap.path)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(snap.fileCount) files")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if snap.todoCount > 0 {
                                Text("\(snap.todoCount) TODOs")
                                    .font(.caption2)
                                    .foregroundStyle(.orange.opacity(0.8))
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    Divider().opacity(0.15)
                }
            }
        }
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        card {
            Text("DIAGNOSTICS")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .tracking(1.5)

            let safety = GitHubSafetyManager.shared
            let cache  = GitHubCacheStore.shared

            diagRow("API calls remaining", "\(safety.remainingCoreRequests)")
            diagRow("Rate limit resets",   safety.rateLimitResetAt)
            diagRow("Cache entries",       "\(cache.validEntryCount) valid / \(cache.entryCount) total")
            diagRow("Local repos indexed", "\(GitHubLocalRepoIndex.shared.snapshots.count)")

            HStack(spacing: 12) {
                Button("Clear Cache") {
                    GitHubCacheStore.shared.invalidateEverything()
                }
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .buttonStyle(.plain)
            }
        }
    }

    private func diagRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.75))
        }
    }

    // MARK: - Card Helper

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.white.opacity(0.04))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.white.opacity(0.08)))
            )
    }

    // MARK: - Actions

    private func saveToken() {
        prefs.setSecureToken(tokenDraft, account: KeychainAccount.githubPersonalAccessToken)
    }

    private func testConnection() async {
        guard !tokenDraft.isEmpty else {
            testResult = "❌ No token entered."
            return
        }
        isTesting = true
        testResult = nil
        let client = GitHubAPIClient(token: tokenDraft)
        do {
            let user = try await client.getAuthenticatedUser()
            testResult = "✅ Connected as @\(user.login)"
        } catch {
            testResult = "❌ \(error.localizedDescription)"
        }
        isTesting = false
    }
}
