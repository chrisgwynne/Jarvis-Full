import XCTest
@testable import JarvisMac

/// Tests for `GitHubIssueService` focused on the gates that protect the
/// user from accidental noisy issue creation:
///
///   * disabled → skipped
///   * not fully configured → skipped with reason
///   * duplicate (entry already linked) → skipped, dedupeHits bumped
///
/// We don't hit the live GitHub API.  Those paths are exercised in the
/// manual checklist via the Test connection button.
@MainActor
final class GitHubIssueServiceTests: XCTestCase {

    /// Build a sandbox `PreferencesStore` pointing at the developer's
    /// real app-support dir (the store has no inject point for an
    /// alternate URL).  We mutate prefs in-memory and never persist
    /// anything sensitive — token is left empty for the disabled-path
    /// tests; the not-configured path uses an explicit empty owner.
    private func makePrefs() -> PreferencesStore {
        let p = PreferencesStore()
        // Reset all GitHub-issue fields to known defaults so prior runs
        // don't leak in.  Token-clearing is done explicitly per test.
        p.update {
            $0.githubIssueLoggingEnabled  = false
            $0.githubIssueRepoOwner       = ""
            $0.githubIssueRepoName        = ""
            $0.githubIssueLabelsCSV       = "jarvis,unknown-command"
            $0.githubIssueAutoCreate      = false
            $0.githubIssueCooldownSeconds = 30
            $0.githubIssueLastError       = nil
            $0.githubIssueLastCreatedURL  = nil
        }
        Keychain.remove(KeychainAccount.githubIssuesToken)
        return p
    }

    private func makeEntry(_ raw: String, _ norm: String) -> UnmatchedCommandEntry {
        UnmatchedCommandEntry(
            rawText: raw, normalizedText: norm,
            action: nil, target: nil, targetLabel: nil,
            activeOverlay: nil, phase: nil)
    }

    // MARK: - disabled / not-configured / cooldown gates

    func test_disabled_returnsSkippedDisabled() async {
        let prefs = makePrefs()
        let svc = GitHubIssueService(prefs: prefs)
        let store = UnmatchedCommandStore()
        let entry = makeEntry("anything", "ghs_disabled_\(UUID().uuidString.prefix(4))")
        let r = await svc.createIssueIfNeeded(for: entry, store: store)
        XCTAssertEqual(r, .skippedDisabled)
    }

    func test_enabledButMissingFields_returnsSkippedNotConfigured() async {
        let prefs = makePrefs()
        prefs.update { $0.githubIssueLoggingEnabled = true }  // enabled, but no owner/repo/token
        let svc = GitHubIssueService(prefs: prefs)
        let store = UnmatchedCommandStore()
        let entry = makeEntry("anything", "ghs_missing_\(UUID().uuidString.prefix(4))")
        let r = await svc.createIssueIfNeeded(for: entry, store: store)
        if case .skippedNotConfigured(let reason) = r {
            XCTAssertTrue(reason.contains("owner"), reason)
            XCTAssertTrue(reason.contains("repo"),  reason)
            XCTAssertTrue(reason.contains("token"), reason)
        } else {
            XCTFail("expected .skippedNotConfigured, got \(r)")
        }
    }

    // MARK: - dedupe gate

    func test_duplicateEntry_returnsSkippedDuplicate() async {
        let prefs = makePrefs()
        prefs.update {
            $0.githubIssueLoggingEnabled = true
            $0.githubIssueRepoOwner = "x"
            $0.githubIssueRepoName  = "y"
        }
        Keychain.set("FAKE_TOKEN_DEDUPE", for: KeychainAccount.githubIssuesToken)
        defer { Keychain.remove(KeychainAccount.githubIssuesToken) }

        let svc = GitHubIssueService(prefs: prefs)
        let store = UnmatchedCommandStore()
        let norm = "ghs_dedupe_\(UUID().uuidString.prefix(4))"
        let entry = makeEntry("the duplicate one", norm)
        store.record(entry)
        // Pre-link to a fake URL — simulates "we already filed this before".
        store.recordGitHubIssue(normalizedText: norm,
                                 url: "https://example.com/i/1",
                                 number: 1)
        let r = await svc.createIssueIfNeeded(for: entry, store: store)
        if case .skippedDuplicate(let existing) = r {
            XCTAssertEqual(existing, "https://example.com/i/1")
            // dedupeHits should have incremented from 0 to 1.
            XCTAssertEqual(store.entry(normalizedText: norm)?.dedupeHits, 1)
        } else {
            XCTFail("expected .skippedDuplicate, got \(r)")
        }
    }

    // MARK: - configSnapshot reflects current prefs

    func test_configSnapshot_readsFromPrefsAndKeychain() {
        let prefs = makePrefs()
        prefs.update {
            $0.githubIssueLoggingEnabled  = true
            $0.githubIssueRepoOwner       = "chrisgwynne"
            $0.githubIssueRepoName        = "jarvis"
            $0.githubIssueLabelsCSV       = "jarvis, auto-created , needs-routing"
            $0.githubIssueCooldownSeconds = 45
            $0.githubIssueAutoCreate      = true
        }
        Keychain.set("TOKEN_FOR_SNAPSHOT", for: KeychainAccount.githubIssuesToken)
        defer { Keychain.remove(KeychainAccount.githubIssuesToken) }

        let svc = GitHubIssueService(prefs: prefs)
        let cfg = svc.configSnapshot()
        XCTAssertTrue(cfg.enabled)
        XCTAssertEqual(cfg.owner, "chrisgwynne")
        XCTAssertEqual(cfg.repo,  "jarvis")
        XCTAssertEqual(cfg.cooldownSeconds, 45)
        XCTAssertTrue(cfg.autoCreate)
        // Labels are split on comma + whitespace-trimmed.
        XCTAssertEqual(cfg.labels, ["jarvis", "auto-created", "needs-routing"])
        XCTAssertTrue(cfg.isFullyConfigured)
    }
}
