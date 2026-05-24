import Foundation

// MARK: - GitHubProjectCreationManager
// Conversational project/repo creation wizard.

@MainActor
final class GitHubProjectCreationManager {
    private let repoMgr: GitHubRepoManager
    private let safety  = GitHubSafetyManager.shared

    // Active wizard session
    @Published private(set) var activeSession: CreationSession? = nil

    init(repoMgr: GitHubRepoManager) {
        self.repoMgr = repoMgr
    }

    // MARK: - Session Model

    final class CreationSession: ObservableObject {
        @Published var request = GHProjectCreationRequest()
        @Published var step: WizardStep = .askName
        @Published var isCreating: Bool = false
        @Published var createdRepo: GHRepo? = nil
        @Published var error: String? = nil

        enum WizardStep {
            case askName, askVisibility, askTemplate, askReadme,
                 askCloneLocally, askLocalPath, confirm, creating, done, failed
        }

        var isComplete: Bool { step == .done }
        var needsMoreInfo: Bool {
            request.name.isEmpty
        }
    }

    // MARK: - Start Wizard

    func startSession() -> CreationSession {
        let session = CreationSession()
        activeSession = session
        return session
    }

    func startSessionWithName(_ name: String) -> CreationSession {
        let session = CreationSession()
        session.request.name = name
        session.step = .askVisibility
        activeSession = session
        return session
    }

    // MARK: - Voice-driven wizard steps

    /// Returns the next question to ask the user, or nil if all info gathered.
    func nextQuestion(for session: CreationSession) -> String? {
        if session.request.name.isEmpty {
            return "What should I name the repository?"
        }
        // If template not set explicitly, we can skip (defaults to .empty)
        switch session.step {
        case .askName:          return "What should I name the repository?"
        case .askVisibility:    return "Should it be public or private?"
        case .askTemplate:      return "What type of project? Swift, Android, React, Node, Python, or just an empty repo?"
        case .askReadme:        return "Include a README file?"
        case .askCloneLocally:  return "Clone it locally after creating?"
        case .askLocalPath:     return "Where should I clone it? Give me the path."
        case .confirm:
            let name = session.request.name
            let vis  = session.request.isPrivate ? "private" : "public"
            let tmpl = session.request.template.displayName
            return "Ready to create '\(name)' — \(vis) \(tmpl) repo. Say confirm to proceed."
        default: return nil
        }
    }

    func applyVoiceAnswer(_ answer: String, to session: CreationSession) {
        let lower = answer.lowercased()
        switch session.step {
        case .askName:
            session.request.name = answer.trimmingCharacters(in: .whitespaces)
            session.step = .askVisibility

        case .askVisibility:
            session.request.isPrivate = !lower.contains("public")
            session.step = .askTemplate

        case .askTemplate:
            session.request.template = detectTemplate(lower)
            session.step = .askReadme

        case .askReadme:
            session.request.includeReadme = lower.contains("yes") || lower.contains("yeah") || lower.contains("sure")
            session.step = .askCloneLocally

        case .askCloneLocally:
            session.request.cloneLocally = lower.contains("yes") || lower.contains("yeah") || lower.contains("sure")
            session.step = session.request.cloneLocally ? .askLocalPath : .confirm

        case .askLocalPath:
            session.request.localPath = answer.trimmingCharacters(in: .whitespaces)
            session.step = .confirm

        default: break
        }
    }

    func confirmAndCreate(session: CreationSession) async -> Result<GHRepo, Error> {
        session.isCreating = true
        session.step = .creating
        let action = GHWriteAction.createRepo(
            name: session.request.name,
            description: session.request.description,
            isPrivate: session.request.isPrivate,
            autoInit: session.request.includeReadme,
            gitignoreTemplate: session.request.template.gitignore,
            licenseTemplate: session.request.licenseTemplate
        )

        return await withCheckedContinuation { continuation in
            switch safety.check(action) {
            case .blocked(let reason):
                session.error = reason
                session.step = .failed
                session.isCreating = false
                continuation.resume(returning: .failure(GHError.safetyBlocked(reason)))

            case .allowed, .requiresConfirmation:
                // Create immediately — confirmation was already handled by voice "confirm"
                Task {
                    do {
                        let repo = try await self.repoMgr.createRepo(session.request)
                        session.createdRepo = repo
                        session.step = .done

                        // Optional local clone
                        if session.request.cloneLocally, let localPath = session.request.localPath {
                            await self.cloneRepo(repo: repo, to: localPath)
                        }
                        continuation.resume(returning: .success(repo))
                    } catch {
                        session.error = error.localizedDescription
                        session.step = .failed
                        continuation.resume(returning: .failure(error))
                    }
                    session.isCreating = false
                    self.activeSession = nil
                }
            }
        }
    }

    func cancelSession() {
        activeSession = nil
    }

    // MARK: - Quick Create (no wizard, direct)

    func quickCreate(name: String, isPrivate: Bool, template: GHProjectTemplate) async throws -> GHRepo {
        var req = GHProjectCreationRequest()
        req.name = name
        req.isPrivate = isPrivate
        req.template = template
        req.includeReadme = true
        return try await repoMgr.createRepo(req)
    }

    // MARK: - Spoken Helpers

    func spokenCreationResult(_ result: Result<GHRepo, Error>, name: String) -> String {
        switch result {
        case .success(let repo):
            return "Created repository '\(repo.name)' on GitHub. It's at \(repo.html_url)."
        case .failure(let error):
            return "Failed to create '\(name)': \(error.localizedDescription)"
        }
    }

    // MARK: - Private Helpers

    private func detectTemplate(_ lower: String) -> GHProjectTemplate {
        if lower.contains("swift") || lower.contains("macos") || lower.contains("ios") { return .swiftMacOS }
        if lower.contains("android") || lower.contains("kotlin")                        { return .android }
        if lower.contains("react")                                                      { return .react }
        if lower.contains("node")                                                       { return .node }
        if lower.contains("python")                                                     { return .python }
        if lower.contains("web") || lower.contains("html")                             { return .website }
        return .empty
    }

    private func cloneRepo(repo: GHRepo, to localPath: String) async {
        let fullPath = (localPath as NSString).appendingPathComponent(repo.name)
        let process = Process()
        process.launchPath = "/usr/bin/git"
        process.arguments  = ["clone", repo.clone_url, fullPath]
        try? process.run()
        process.waitUntilExit()

        // Index the freshly cloned repo
        _ = try? await GitHubLocalRepoIndex.shared.index(path: fullPath, fullName: repo.full_name)
    }
}
