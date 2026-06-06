import SwiftUI

// MARK: - GitHubIssueOverlayView

/// Reviewable GitHub issue overlay.
///
/// Opens when an error occurs (automatic) or when the user says
/// "open a GitHub issue" (manual). All fields are editable before submission.
/// Nothing is ever submitted silently.
struct GitHubIssueOverlayView: View {

    let controller: JarvisController

    /// The draft comes from GitHubIssueDraftStore.shared.currentDraft.
    /// Passed in so changes are Observable-tracked.
    @Bindable var draft: GitHubIssueDraft

    @State private var showCopyConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headerBar
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 10)

                Divider().opacity(0.25)

                if !configError.isEmpty {
                    configErrorBanner
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                }

                if draft.duplicateCount > 1 {
                    duplicateBanner
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                }

                formFields
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                Divider().opacity(0.25).padding(.top, 12)

                actionBar
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.bubble")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.purple)
            Text("GitHub Issue")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
            Spacer()
            sourceChip
        }
    }

    private var sourceChip: some View {
        let label: String
        let color: Color
        switch draft.source {
        case .automaticError:
            label = "auto-captured"; color = .orange
        case .manualVoice:
            label = "manual"; color = .secondary
        case .manualWithContext:
            label = "from context"; color = .blue
        }
        return Text(label)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    // MARK: - Config error banner

    private var configError: String {
        let cfg = controller.githubIssueService.configSnapshot()
        if !cfg.isFullyConfigured {
            var missing: [String] = []
            if cfg.owner.isEmpty { missing.append("repo owner") }
            if cfg.repo.isEmpty  { missing.append("repo name") }
            if cfg.token == nil || cfg.token!.isEmpty { missing.append("GitHub token") }
            return "GitHub not configured — missing: \(missing.joined(separator: ", ")). Check Settings → Developer → Brain API."
        }
        return ""
    }

    private var configErrorBanner: some View {
        Label(configError, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.10))
            .cornerRadius(8)
    }

    // MARK: - Duplicate banner

    private var duplicateBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
            Text("This error occurred \(draft.duplicateCount) times.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08))
        .cornerRadius(6)
    }

    // MARK: - Form fields

    private var formFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Repository
            fieldGroup("Repository") {
                TextField("owner/repo", text: $draft.repo)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            // Title
            fieldGroup("Issue title") {
                TextField("Short clear summary", text: $draft.title)
                    .textFieldStyle(.roundedBorder)
            }

            // Metadata row
            HStack(spacing: 12) {
                fieldGroup("Type") {
                    Picker("", selection: $draft.issueType) {
                        ForEach(GitHubIssueType.allCases, id: \.self) { t in
                            Text("\(t.emoji) \(t.label)").tag(t)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                fieldGroup("Severity") {
                    Picker("", selection: $draft.severity) {
                        ForEach(GitHubIssueSeverity.allCases, id: \.self) { s in
                            Text(s.label.capitalized).tag(s)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .foregroundStyle(severityColor)
                }
                fieldGroup("Area") {
                    Picker("", selection: $draft.area) {
                        ForEach(GitHubIssueArea.allCases, id: \.self) { a in
                            Text(a.label).tag(a)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }

            // Description
            fieldGroup("Description") {
                TextEditor(text: $draft.description)
                    .frame(minHeight: 56, maxHeight: 100)
                    .font(.body)
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.3)))
            }

            // Steps to reproduce
            fieldGroup("Steps to reproduce") {
                TextEditor(text: $draft.stepsToReproduce)
                    .frame(minHeight: 56, maxHeight: 100)
                    .font(.body)
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.3)))
            }

            HStack(alignment: .top, spacing: 12) {
                fieldGroup("Expected behaviour") {
                    TextEditor(text: $draft.expectedBehaviour)
                        .frame(minHeight: 56, maxHeight: 80)
                        .font(.body)
                        .padding(4)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.3)))
                }
                fieldGroup("Actual behaviour") {
                    TextEditor(text: $draft.actualBehaviour)
                        .frame(minHeight: 56, maxHeight: 80)
                        .font(.body)
                        .padding(4)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.3)))
                }
            }

            // Logs / trace
            fieldGroup("Logs / stack trace") {
                TextEditor(text: $draft.logsTrace)
                    .frame(minHeight: 70, maxHeight: 160)
                    .font(.system(.caption, design: .monospaced))
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.3)))
            }

            // Labels + assignees
            HStack(spacing: 12) {
                fieldGroup("Labels (comma-separated)") {
                    TextField("e.g. bug, mac-app", text: $draft.labelsCSV)
                        .textFieldStyle(.roundedBorder)
                }
                fieldGroup("Assignees (optional)") {
                    TextField("GitHub usernames", text: $draft.assignees)
                        .textFieldStyle(.roundedBorder)
                }
            }

            // Submission result
            if case .success(let url, let number) = draft.submitState {
                successBanner(url: url, number: number)
            } else if case .failed(let message) = draft.submitState {
                failureBanner(message: message)
            }
        }
    }

    @ViewBuilder
    private func fieldGroup<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.tertiary)
                .tracking(0.8)
            content()
        }
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack(spacing: 10) {
            // Copy body
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(draft.renderedBody, forType: .string)
                showCopyConfirmation = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { showCopyConfirmation = false }
            } label: {
                Label(showCopyConfirmation ? "Copied!" : "Copy body",
                      systemImage: showCopyConfirmation ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12))
            }
            .buttonStyle(.bordered)

            Spacer()

            // Cancel
            if draft.submitState != .submitting {
                if case .success = draft.submitState {
                    // Already succeeded — close only
                } else {
                    Button("Cancel") {
                        GitHubIssueDraftStore.shared.clearDraft()
                        controller.overlayManager.close(.githubIssue)
                    }
                    .buttonStyle(.bordered)
                    .foregroundStyle(.secondary)
                }
            }

            // Submit / Close
            submitButton
        }
    }

    @ViewBuilder
    private var submitButton: some View {
        switch draft.submitState {
        case .idle:
            Button("Submit Issue") { submitDraft() }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty
                          || draft.repo.trimmingCharacters(in: .whitespaces).isEmpty
                          || !configError.isEmpty)
        case .submitting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Submitting…").font(.system(size: 12))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        case .success:
            Button("Close") {
                GitHubIssueDraftStore.shared.clearDraft()
                controller.overlayManager.close(.githubIssue)
            }
            .buttonStyle(.borderedProminent).tint(.green)
        case .failed:
            Button("Retry") { submitDraft() }
                .buttonStyle(.borderedProminent).tint(.red)
        }
    }

    // MARK: - Banners

    private func successBanner(url: String, number: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Issue #\(number) created").font(.callout).fontWeight(.semibold)
                if let nsURL = URL(string: url) {
                    Button(url) { NSWorkspace.shared.open(nsURL) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.10))
        .cornerRadius(8)
    }

    private func failureBanner(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("Submission failed").font(.callout).fontWeight(.semibold)
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.10))
        .cornerRadius(8)
    }

    // MARK: - Submit

    private func submitDraft() {
        let title = draft.title.trimmingCharacters(in: .whitespaces)
        let repo  = draft.repo.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, !repo.isEmpty else { return }

        draft.submitState = .submitting
        let body     = draft.renderedBody
        let labels   = draft.resolvedLabels
        let assignees = draft.assignees
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        Log.github.info("[GitHubIssueOverlay] submit started repo=\(repo) title=\(title.prefix(80))")

        Task { @MainActor in
            let cfg = controller.githubIssueService.configSnapshot()
            Log.github.info("[GitHubIssueService] repoConfigured=\(!cfg.owner.isEmpty && !cfg.repo.isEmpty) owner=\(cfg.owner) name=\(cfg.repo)")

            guard let token = cfg.token, !token.isEmpty else {
                draft.submitState = .failed(message: "No GitHub token — add one in Settings → Developer → Brain API.")
                Log.github.warning("[GitHubIssueOverlay] submit failed error=no_token")
                return
            }
            Log.github.info("[GitHubIssueService] tokenPresent=true source=keychain")

            // Build a client directly from the issue-service token so the overlay
            // works even when controller.githubClient is nil (e.g. the notifications
            // PAT was never set — a common mismatch between the two token slots).
            let client = GitHubAPIClient(token: token)
            Log.github.info("[GitHubIssueService] clientReady=true")
            Log.github.info("[GitHubIssueService] createIssue started")

            do {
                let issue = try await client.createIssue(
                    repo: repo,
                    title: title,
                    body: body,
                    labels: labels,
                    assignees: assignees.isEmpty ? nil : assignees
                )
                draft.submitState = .success(url: issue.html_url, number: issue.number)
                Log.github.info("[GitHubIssueService] createIssue success issueNumber=\(issue.number)")
                GitHubCacheStore.shared.invalidate(
                    key: GitHubCacheStore.key(repo: repo, resource: "issues.open"))
            } catch {
                draft.submitState = .failed(message: error.localizedDescription)
                Log.github.warning("[GitHubIssueService] createIssue failed reason=\(error.localizedDescription)")
            }
        }
    }

    // MARK: - Helpers

    private var severityColor: Color {
        switch draft.severity {
        case .low:      return .secondary
        case .medium:   return .yellow
        case .high:     return .orange
        case .critical: return .red
        }
    }
}
