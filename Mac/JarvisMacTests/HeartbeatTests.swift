import XCTest
@testable import JarvisMac

// MARK: - HeartbeatTests

@MainActor
final class HeartbeatTests: XCTestCase {

    // MARK: - Helpers

    /// A store backed by a unique temp file so tests never touch the shared
    /// `~/Library/Application Support` heartbeat or each other.
    private func makeIsolatedStore() -> HeartbeatStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heartbeat_test_\(UUID().uuidString).json")
        return HeartbeatStore(fileURL: url)
    }

    // MARK: - HeartbeatItem

    func testItemConfidenceClamped() {
        let high = HeartbeatItem(text: "x", confidence: 5)
        let low  = HeartbeatItem(text: "y", confidence: -3)
        XCTAssertEqual(high.confidence, 1.0)
        XCTAssertEqual(low.confidence, 0.0)
    }

    // MARK: - HeartbeatState context block

    func testEmptyStateProducesEmptyContextBlock() {
        XCTAssertEqual(HeartbeatState().contextBlock(), "")
    }

    func testContextBlockIncludesSetFields() {
        var s = HeartbeatState()
        s.currentFocus = "writing code"
        s.activeProject = "Jarvis"
        s.focusConfidence = 0.82
        s.attentionNeeded = [HeartbeatItem(text: "PR review requested")]
        let block = s.contextBlock()
        XCTAssertTrue(block.contains("[HEARTBEAT"))
        XCTAssertTrue(block.contains("focus: writing code"))
        XCTAssertTrue(block.contains("active_project: Jarvis (82% confidence)"))
        XCTAssertTrue(block.contains("attention_needed: PR review requested"))
    }

    func testSituationSummaryFallbackWhenEmpty() {
        XCTAssertEqual(HeartbeatState().situationSummary(), "Nothing pressing on the radar.")
    }

    func testSituationSummaryWithData() {
        var s = HeartbeatState()
        s.activeProject = "Pucked"
        s.recentWins = [HeartbeatItem(text: "pairing flow simplified")]
        let summary = s.situationSummary()
        XCTAssertTrue(summary.contains("Pucked"))
        XCTAssertTrue(summary.contains("pairing flow simplified"))
    }

    // MARK: - Codable

    func testStateCodableRoundTrip() throws {
        var s = HeartbeatState()
        s.currentFocus = "debugging"
        s.openIssues = [HeartbeatItem(text: "flaky test", source: "ci")]
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let data = try enc.encode(s)
        let back = try dec.decode(HeartbeatState.self, from: data)
        XCTAssertEqual(back, s)
    }

    func testForwardCompatPartialDecode() throws {
        // Hand-edited / older JSON missing most fields must still load.
        let json = Data(#"{"currentFocus":"coding"}"#.utf8)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let s = try dec.decode(HeartbeatState.self, from: json)
        XCTAssertEqual(s.currentFocus, "coding")
        XCTAssertEqual(s.focusConfidence, 0)
        XCTAssertTrue(s.openIssues.isEmpty)
        XCTAssertEqual(s.sessionCount, 0)
    }

    // MARK: - Store mutations

    func testAddOpenIssueDedupRefreshesNotDuplicates() {
        let store = makeIsolatedStore()
        store.addOpenIssue("CI failing on jarvis")
        store.addOpenIssue("ci failing on jarvis")   // same text, different case
        XCTAssertEqual(store.state.openIssues.count, 1)
    }

    func testIssueCapEnforced() {
        let store = makeIsolatedStore()
        for i in 0..<20 { store.addOpenIssue("issue \(i)") }
        XCTAssertLessThanOrEqual(store.state.openIssues.count, 12)
    }

    func testResolveMatchingRemovesAcrossLists() {
        let store = makeIsolatedStore()
        store.addOpenIssue("CI failing on jarvis")
        store.addBlocker("CI failing on jarvis")
        store.addAttention("unrelated alert")
        let removed = store.resolve(matching: "CI failing")
        XCTAssertEqual(removed, 2)
        XCTAssertEqual(store.state.attentionNeeded.count, 1)
    }

    func testSetActiveProjectClampsConfidence() {
        let store = makeIsolatedStore()
        store.setActiveProject("Jarvis", confidence: 2.5)
        XCTAssertEqual(store.state.activeProject, "Jarvis")
        XCTAssertEqual(store.state.focusConfidence, 1.0)
    }

    func testRecordInteractionSetsFocusAndCount() {
        let store = makeIsolatedStore()
        store.recordInteraction(focus: "home turn off")
        XCTAssertEqual(store.state.currentFocus, "home turn off")
        XCTAssertEqual(store.state.interactionCount, 1)
        XCTAssertNotNil(store.state.lastInteractionAt)
    }

    func testResetClearsState() {
        let store = makeIsolatedStore()
        store.addWin("shipped feature")
        store.setActiveProject("Jarvis", confidence: 0.9)
        store.reset()
        XCTAssertNil(store.state.activeProject)
        XCTAssertTrue(store.state.recentWins.isEmpty)
    }

    // MARK: - Intent humanization

    func testHumanizeIntentCamelCase() {
        XCTAssertEqual(HeartbeatCoordinator.humanizeIntent("homeTurnOff"), "home turn off")
    }

    func testHumanizeIntentSnakeCase() {
        XCTAssertEqual(HeartbeatCoordinator.humanizeIntent("show_brain_overlay"), "show brain overlay")
    }

    func testHumanizeIntentStripsAssociatedValue() {
        XCTAssertEqual(HeartbeatCoordinator.humanizeIntent("openApp(name:)"), "open app")
    }
}
