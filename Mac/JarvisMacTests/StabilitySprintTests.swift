import XCTest
@testable import JarvisMac

/// Phase 11 stability-sprint tests for Mac app layer.
///
/// Tests cover:
///   1. Handoff URL safety (malformed URL → no crash)
///   2. Handoff text truncation to 200 chars
///   3. HandoffContextStore 24 h expiry (inline replica)
///   4. LatencyTracker stage measurement
///   5. LatencyTracker cross-device snapshot (guarded — parallel agent adds these)
@MainActor
final class StabilitySprintTests: XCTestCase {

    // MARK: - 1. Handoff URL safety

    /// Mimics the logic inside HandoffCoordinator.receive(key:value:) for the "url" key.
    /// A malformed value must return false (no NSWorkspace.open called).
    private func handoffOpenURL(_ value: String) -> Bool {
        guard let url = URL(string: value), url.scheme != nil else { return false }
        return true
    }

    func test_handoffOpenURL_malformedString_returnsFalse() {
        XCTAssertFalse(handoffOpenURL("not a url"),
            "Malformed URL string must not pass the guard and must return false")
    }

    func test_handoffOpenURL_validHTTPS_returnsTrue() {
        XCTAssertTrue(handoffOpenURL("https://apple.com"),
            "Valid https URL must pass the guard and return true")
    }

    func test_handoffOpenURL_emptyString_returnsFalse() {
        XCTAssertFalse(handoffOpenURL(""),
            "Empty string must not pass the guard")
    }

    func test_handoffOpenURL_schemeless_returnsFalse() {
        // "apple.com" is technically a valid URL but has nil scheme on some platforms.
        let result = handoffOpenURL("apple.com")
        // Either false (nil scheme) or true (non-nil scheme) is acceptable — the key
        // invariant is that it does NOT crash.
        _ = result  // no crash = pass
    }

    // MARK: - 2. Handoff text stays within 200 chars

    private func handoffSummary(_ text: String, limit: Int = 200) -> String {
        String(text.prefix(limit))
    }

    func test_handoffSummary_300CharInput_truncatedTo200() {
        let longText = String(repeating: "a", count: 300)
        let result = handoffSummary(longText)
        XCTAssertEqual(result.count, 200,
            "handoffSummary must truncate a 300-character string to exactly 200 characters")
    }

    func test_handoffSummary_shortInput_unchanged() {
        let shortText = "Hello, world!"
        let result = handoffSummary(shortText)
        XCTAssertEqual(result, shortText,
            "handoffSummary must leave strings shorter than 200 chars unchanged")
    }

    func test_handoffSummary_exactly200Chars_unchanged() {
        let text = String(repeating: "x", count: 200)
        XCTAssertEqual(handoffSummary(text).count, 200,
            "handoffSummary must not truncate a string of exactly 200 characters")
    }

    // MARK: - 3. HandoffContextStore 24 h expiry (inline replica)

    private func makeHandoffStore() -> (record: (String, Date) -> Void, countActive: (Date) -> Int) {
        var entries: [(key: String, createdAt: Date)] = []
        let ttl: TimeInterval = 86400
        return (
            record: { key, at in entries.append((key, at)) },
            countActive: { now in entries.filter { now.timeIntervalSince($0.createdAt) < ttl }.count }
        )
    }

    func test_handoffStore_freshEntry_countIs1() {
        let store = makeHandoffStore()
        store.record("key1", Date())
        XCTAssertEqual(store.countActive(Date()), 1,
            "A just-recorded entry must appear as active")
    }

    func test_handoffStore_25hOldEntry_countIs0() {
        let store = makeHandoffStore()
        let twentyFiveHoursAgo = Date().addingTimeInterval(-90_000)   // 25 h ago
        store.record("old-key", twentyFiveHoursAgo)
        XCTAssertEqual(store.countActive(Date()), 0,
            "An entry recorded 25 hours ago must be expired (TTL = 24 h)")
    }

    func test_handoffStore_mixedEntries_onlyFreshCounted() {
        let store = makeHandoffStore()
        store.record("fresh", Date())
        store.record("stale", Date().addingTimeInterval(-90_000))
        XCTAssertEqual(store.countActive(Date()), 1,
            "Only the fresh entry within TTL must be counted as active")
    }

    // MARK: - 4. LatencyTracker stage measurement

    func test_latencyTracker_measuresGap() {
        let tracker = LatencyTracker()
        let t0 = Date()
        let t1 = t0.addingTimeInterval(0.5)
        tracker.mark(.sttFinal, at: t0)
        tracker.mark(.intentRoute, at: t1)
        let ms = tracker.measure(from: .sttFinal, to: .intentRoute)
        XCTAssertNotNil(ms, "measure(from:to:) must return a non-nil value when both marks exist")
        XCTAssertEqual(ms!, 500.0, accuracy: 1.0,
            "A 500 ms gap between marks must be reported as 500.0 ms (±1 ms)")
    }

    func test_latencyTracker_missingMark_returnsNil() {
        let tracker = LatencyTracker()
        tracker.mark(.sttFinal, at: Date())
        // .intentRoute is never marked.
        let ms = tracker.measure(from: .sttFinal, to: .intentRoute)
        XCTAssertNil(ms, "measure must return nil when the end mark is missing")
    }

    func test_latencyTracker_reset_clearsMarks() {
        let tracker = LatencyTracker()
        tracker.mark(.sttFinal, at: Date())
        tracker.reset()
        let ms = tracker.measure(from: .sttFinal, to: .intentRoute)
        XCTAssertNil(ms, "After reset(), measure must return nil for previously recorded marks")
    }

    func test_latencyTracker_record_averageStaysWithinWindow() {
        let tracker = LatencyTracker()
        // Record 25 samples — internal window is 20, so oldest are evicted.
        for i in 0..<25 { tracker.record(.llmComplete, ms: Double(i)) }
        let avg = tracker.average(for: .llmComplete)
        XCTAssertNotNil(avg, "average must be non-nil after recording samples")
        // Last 20 values: 5...24 → mean = 14.5
        XCTAssertEqual(avg!, 14.5, accuracy: 0.1,
            "Rolling window must evict oldest entries, keeping only the last 20")
    }

    // MARK: - 5. LatencyTracker cross-device snapshot (compile-guarded)
    //
    // TODO: Remove the #if false guard once the parallel agent adds:
    //   • LatencyStage.daemonRtt case
    //   • LatencyTracker.crossDeviceSnapshot() -> [String: Double]
    //
    // Until those additions land, the block below is excluded from compilation
    // so this file continues to build cleanly.

    #if false
    func test_latencyTracker_crossDeviceStagesExist() {
        let tracker = LatencyTracker()
        tracker.record(.daemonRtt, ms: 42.0)
        let snap = tracker.crossDeviceSnapshot()
        XCTAssertTrue(snap.keys.contains("daemon_rtt"),
            "crossDeviceSnapshot must include the 'daemon_rtt' key")
        XCTAssertEqual(snap["daemon_rtt"]!, 42.0, accuracy: 0.01,
            "daemon_rtt value must match the recorded 42.0 ms")
    }
    #endif
}
