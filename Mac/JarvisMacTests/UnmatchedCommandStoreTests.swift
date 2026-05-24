import XCTest
@testable import JarvisMac

/// Tests the enriched `UnmatchedCommandStore` API used by the final
/// unknown-fallback path and the GitHub issue service.  We don't hit
/// the real on-disk store path — `record()` writes to a fixed file but
/// we accept that side-effect; the assertions focus on in-memory shape.
@MainActor
final class UnmatchedCommandStoreTests: XCTestCase {

    /// Convenience entry factory.
    private func makeEntry(_ raw: String, _ norm: String) -> UnmatchedCommandEntry {
        UnmatchedCommandEntry(
            rawText: raw,
            normalizedText: norm,
            action: nil, target: nil, targetLabel: nil,
            activeOverlay: nil, phase: nil)
    }

    // MARK: - dedupe + frequency

    func test_record_dedupesByNormalisedText() {
        let store = UnmatchedCommandStore()
        // Use a unique normalised value so this test isn't polluted by
        // any pre-existing entries on disk.
        let norm = "ucs_dedupe_\(UUID().uuidString.prefix(6))"
        store.record(makeEntry("first phrasing", norm))
        store.record(makeEntry("second phrasing same idea", norm))
        let entry = store.entry(normalizedText: norm)
        XCTAssertNotNil(entry)
        XCTAssertGreaterThanOrEqual(entry?.frequency ?? 0, 2)
    }

    // MARK: - enrich

    func test_enrich_attachesContextToExistingEntry() {
        let store = UnmatchedCommandStore()
        let norm = "ucs_enrich_\(UUID().uuidString.prefix(6))"
        store.record(makeEntry("turn the thingy on", norm))
        store.enrich(
            normalizedText: norm,
            currentApp: "Safari",
            matchedCandidate: nil,
            activeContext: "phase: idle\nactive app: Safari",
            listeningMode: "idle",
            lastIntent: "showCamera",
            llmDecision: "fallback_attempted_but_unmapped",
            androidConnected: true,
            userExpectedAction: "unsupportedCommand",
            appVersion: "1.0+123")
        let entry = store.entry(normalizedText: norm)
        XCTAssertEqual(entry?.currentApp, "Safari")
        XCTAssertEqual(entry?.androidConnected, true)
        XCTAssertEqual(entry?.userExpectedAction, "unsupportedCommand")
        XCTAssertEqual(entry?.appVersion, "1.0+123")
    }

    // MARK: - github linkage + dedupe-hit counter

    func test_recordGitHubIssue_setsURLAndNumber() {
        let store = UnmatchedCommandStore()
        let norm = "ucs_gh_url_\(UUID().uuidString.prefix(6))"
        store.record(makeEntry("set my desk lamp to half", norm))
        store.recordGitHubIssue(
            normalizedText: norm,
            url: "https://github.com/x/y/issues/42",
            number: 42)
        let entry = store.entry(normalizedText: norm)
        XCTAssertEqual(entry?.githubIssueURL, "https://github.com/x/y/issues/42")
        XCTAssertEqual(entry?.githubIssueNumber, 42)
        XCTAssertEqual(entry?.dedupeHits, 0)
    }

    func test_recordGitHubIssue_nilURL_incrementsDedupeHits() {
        let store = UnmatchedCommandStore()
        let norm = "ucs_gh_dedupe_\(UUID().uuidString.prefix(6))"
        store.record(makeEntry("do the thing", norm))
        store.recordGitHubIssue(normalizedText: norm, url: nil, number: nil)
        store.recordGitHubIssue(normalizedText: norm, url: nil, number: nil)
        let entry = store.entry(normalizedText: norm)
        XCTAssertEqual(entry?.dedupeHits, 2)
        XCTAssertNil(entry?.githubIssueURL)
    }

    func test_hasGitHubIssue_returnsTrueOnlyWhenURLSet() {
        let store = UnmatchedCommandStore()
        let norm = "ucs_gh_has_\(UUID().uuidString.prefix(6))"
        store.record(makeEntry("phrase", norm))
        XCTAssertFalse(store.hasGitHubIssue(normalizedText: norm))
        store.recordGitHubIssue(
            normalizedText: norm,
            url: "https://example.com/i/1",
            number: 1)
        XCTAssertTrue(store.hasGitHubIssue(normalizedText: norm))
    }
}
