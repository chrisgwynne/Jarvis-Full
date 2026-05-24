import Foundation

// MARK: - Result

/// Outcome of an issue-creation attempt.  Exposed in plain English so
/// the Settings UI / diagnostics surface can show what happened without
/// inspecting raw HTTP.
enum GitHubIssueResult: Equatable {
    /// Successfully created — carries the API-returned URL + number.
    case created(url: String, number: Int)
    /// A previous issue already exists for this normalised command — we
    /// did NOT create a duplicate.  Carries the existing URL.
    case skippedDuplicate(existingURL: String)
    /// Cooldown window not yet elapsed since the last creation attempt.
    case skippedCooldown(retryAfterSeconds: Int)
    /// Logging is disabled in Settings.
    case skippedDisabled
    /// Required configuration is missing (token / owner / repo).
    case skippedNotConfigured(reason: String)
    /// HTTP / network failure — `message` is short and key-redacted.
    case failed(message: String)
}

// MARK: - GitHubIssueService

/// Files GitHub issues for unmatched Jarvis commands so we can wire them
/// into the command pipeline later.  Conforms to the brief's rules:
///
///   * Token lives in macOS Keychain only — never preferences, never logs.
///   * Authorization header is constructed at request time, never logged.
///   * Dedupe key = (normalisedTranscript) — once filed, never re-file.
///   * Cooldown window blocks rapid-fire creation regardless of dedupe.
///   * Labels configurable in Settings.
///
/// All public methods are `@MainActor` to share the same isolation as
/// `JarvisController` and the existing `UnmatchedCommandStore` — keeps
/// the diagnostic state consistent without locking.
@MainActor
final class GitHubIssueService {

    /// Snapshot the service reads at call time.  Loaded from the
    /// `PreferencesStore` + Keychain right before each create.  Keeping
    /// it as a value type means the service has no long-lived state apart
    /// from `lastCreatedAt`.
    struct Config {
        let enabled: Bool
        let owner: String
        let repo: String
        let labels: [String]
        let username: String
        let cooldownSeconds: Int
        let autoCreate: Bool
        let token: String?

        var isFullyConfigured: Bool {
            enabled
                && !owner.trimmingCharacters(in: .whitespaces).isEmpty
                && !repo.trimmingCharacters(in: .whitespaces).isEmpty
                && (token?.isEmpty == false)
        }
    }

    // MARK: - State

    private let prefs: PreferencesStore
    /// Last successful or attempted creation time.  Used by the cooldown
    /// gate — applied regardless of dedupe so a buggy auto-create can't
    /// flood the repo.
    private var lastCreatedAt: Date = .distantPast

    /// Shared session — same shape as the other LLM clients.  60s
    /// resource ceiling so a hung GitHub endpoint can't dangle a Task.
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.httpMaximumConnectionsPerHost = 2
        cfg.timeoutIntervalForRequest = 12
        cfg.timeoutIntervalForResource = 30
        return URLSession(configuration: cfg)
    }()

    init(prefs: PreferencesStore) {
        self.prefs = prefs
    }

    // MARK: - Config snapshot

    /// Read the current settings + Keychain token.  Pure — no side effects.
    private func currentConfig() -> Config {
        let p = prefs.current
        let labels = p.githubIssueLabelsCSV
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Config(
            enabled:          p.githubIssueLoggingEnabled,
            owner:            p.githubIssueRepoOwner.trimmingCharacters(in: .whitespaces),
            repo:             p.githubIssueRepoName.trimmingCharacters(in: .whitespaces),
            labels:           labels,
            username:         p.githubIssueUsername,
            cooldownSeconds:  p.githubIssueCooldownSeconds,
            autoCreate:       p.githubIssueAutoCreate,
            token:            Keychain.get(KeychainAccount.githubIssuesToken))
    }

    // MARK: - Public API

    /// Read-only snapshot for Settings UI — the "Last error" / "Last URL"
    /// rows pull from `prefs.current.githubIssueLastError` etc, so this
    /// method only exists to power the live config indicator.
    func configSnapshot() -> Config { currentConfig() }

    /// Verify connectivity + token validity by issuing a HEAD on the user's
    /// repo URL.  Returns a human-readable message.  Never logs the token.
    func testConnection() async -> String {
        let cfg = currentConfig()
        guard cfg.isFullyConfigured else {
            return "Not configured — set token, owner, and repo."
        }
        guard let url = URL(string:
            "https://api.github.com/repos/\(cfg.owner)/\(cfg.repo)") else {
            return "Invalid owner/repo."
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(cfg.token ?? "")", forHTTPHeaderField: "Authorization")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        do {
            let (_, resp) = try await Self.session.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                return "No HTTP response."
            }
            switch http.statusCode {
            case 200:        return "✓ Connected to \(cfg.owner)/\(cfg.repo)."
            case 401:        return "401 — bad or revoked token."
            case 403:        return "403 — token lacks `repo` scope or rate-limited."
            case 404:        return "404 — \(cfg.owner)/\(cfg.repo) not found or token can't see it."
            default:         return "HTTP \(http.statusCode) — see GitHub status."
            }
        } catch {
            return "Network error: \(error.localizedDescription)"
        }
    }

    /// Attempt to create a GitHub issue for the given unmatched-command
    /// entry.  Honours the dedupe + cooldown + enabled gates from
    /// Settings.  Updates `unmatchedStore` linkage on success.
    ///
    /// Returns a `GitHubIssueResult` describing what happened.
    func createIssueIfNeeded(for entry: UnmatchedCommandEntry,
                             store: UnmatchedCommandStore) async -> GitHubIssueResult {
        let cfg = currentConfig()

        // 1. Master enable
        guard cfg.enabled else {
            return .skippedDisabled
        }
        // 2. Required fields
        guard cfg.isFullyConfigured else {
            let missing: [String] = [
                cfg.owner.isEmpty   ? "owner"   : nil,
                cfg.repo.isEmpty    ? "repo"    : nil,
                (cfg.token?.isEmpty ?? true) ? "token" : nil,
            ].compactMap { $0 }
            return .skippedNotConfigured(reason: "missing: \(missing.joined(separator: ", "))")
        }

        // 3. Dedupe — never file two issues for the same normalised command.
        if store.hasGitHubIssue(normalizedText: entry.normalizedText) {
            let existing = store.entry(normalizedText: entry.normalizedText)?
                .githubIssueURL ?? ""
            store.recordGitHubIssue(normalizedText: entry.normalizedText,
                                     url: nil, number: nil)  // bump dedupeHits
            return .skippedDuplicate(existingURL: existing)
        }

        // 4. Cooldown — rate-limit creation even for distinct commands.
        let elapsed = Date().timeIntervalSince(lastCreatedAt)
        if elapsed < Double(cfg.cooldownSeconds) {
            let retry = cfg.cooldownSeconds - Int(elapsed)
            return .skippedCooldown(retryAfterSeconds: max(retry, 1))
        }
        // Tentatively mark "attempted now" so concurrent fires also rate-limit.
        lastCreatedAt = Date()

        // 5. POST to GitHub
        let title = "[Jarvis Unknown Command] \"\(entry.rawText.prefix(80))\""
        let body  = renderIssueBody(entry: entry, cfg: cfg)
        let payload: [String: Any] = [
            "title":  title,
            "body":   body,
            "labels": cfg.labels,
        ]
        guard let postURL = URL(string:
            "https://api.github.com/repos/\(cfg.owner)/\(cfg.repo)/issues"),
              let data    = try? JSONSerialization.data(withJSONObject: payload) else {
            let msg = "Could not build POST request"
            prefs.update { $0.githubIssueLastError = msg }
            return .failed(message: msg)
        }
        var req = URLRequest(url: postURL)
        req.httpMethod = "POST"
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(cfg.token ?? "")", forHTTPHeaderField: "Authorization")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data

        let response: (Data, URLResponse)
        do {
            response = try await Self.session.data(for: req)
        } catch {
            let msg = "Network error: \(error.localizedDescription)"
            prefs.update { $0.githubIssueLastError = msg }
            return .failed(message: msg)
        }
        guard let http = response.1 as? HTTPURLResponse else {
            prefs.update { $0.githubIssueLastError = "Non-HTTP response" }
            return .failed(message: "Non-HTTP response")
        }
        guard http.statusCode == 201 else {
            // Read body for the human-friendly message — but truncate so
            // we never persist a long error blob containing repo data.
            let bodyStr = String(data: response.0, encoding: .utf8) ?? ""
            let msg = "HTTP \(http.statusCode) — \(bodyStr.prefix(180))"
            prefs.update { $0.githubIssueLastError = msg }
            return .failed(message: msg)
        }
        // 201 — parse the response for the URL + number.
        guard let json = try? JSONSerialization.jsonObject(with: response.0) as? [String: Any],
              let url    = json["html_url"] as? String,
              let number = json["number"]   as? Int else {
            let msg = "Issue created but response unreadable"
            prefs.update { $0.githubIssueLastError = msg }
            return .failed(message: msg)
        }
        // Persist linkage + clear last-error.
        store.recordGitHubIssue(normalizedText: entry.normalizedText,
                                 url: url, number: number)
        prefs.update {
            $0.githubIssueLastCreatedURL = url
            $0.githubIssueLastError = nil
        }
        return .created(url: url, number: number)
    }

    // MARK: - Issue body renderer

    /// Build the Markdown body of the GitHub issue from the enriched
    /// `UnmatchedCommandEntry` context.  Never includes the token.  Never
    /// includes the raw chat history — only the short diagnostic fields
    /// already captured at the unknown-fallback point.
    private func renderIssueBody(entry: UnmatchedCommandEntry,
                                  cfg: Config) -> String {
        var lines: [String] = []
        lines.append("**Raw transcript:** \(entry.rawText)")
        lines.append("**Normalised:** `\(entry.normalizedText)`")
        if let app = entry.currentApp,        !app.isEmpty  { lines.append("**Active app:** \(app)") }
        if let overlay = entry.activeOverlay, !overlay.isEmpty { lines.append("**Active overlay:** \(overlay)") }
        if let mode = entry.listeningMode,    !mode.isEmpty { lines.append("**Listening mode:** \(mode)") }
        if let last = entry.lastIntent,       !last.isEmpty { lines.append("**Last successful intent:** \(last)") }
        if let llm  = entry.llmDecision,      !llm.isEmpty  { lines.append("**LLM decision:** \(llm)") }
        if let conn = entry.androidConnected {
            lines.append("**Android connected:** \(conn ? "yes" : "no")")
        }
        if let expected = entry.userExpectedAction, !expected.isEmpty {
            lines.append("**Inferred user intent:** \(expected)")
        }
        if let ver = entry.appVersion, !ver.isEmpty { lines.append("**App version:** \(ver)") }
        lines.append("**Frequency:** \(entry.frequency) seen")
        lines.append("**First seen:** \(entry.timestamp.formatted(.iso8601))")

        if let candidate = entry.matchedCommandCandidate, !candidate.isEmpty {
            lines.append("")
            lines.append("**Closest matched command id:** `\(candidate)`")
        }
        if let ctx = entry.activeContext, !ctx.isEmpty {
            lines.append("")
            lines.append("**Active context block:**")
            lines.append("```")
            // Truncate aggressively — never let a user PII line drift into
            // a public issue.  600 chars is plenty for routing diagnosis.
            lines.append(String(ctx.prefix(600)))
            lines.append("```")
        }

        lines.append("")
        lines.append("---")
        lines.append("Filed automatically by Jarvis on macOS.  Labels: \(cfg.labels.joined(separator: ", ")).")
        lines.append("To wire this command into Jarvis: add an entry to `CommandPhraseDefaults`, map it via `IntentMapping`, and handle the new Intent case in `JarvisController.execute(_:)`.")
        return lines.joined(separator: "\n")
    }
}
