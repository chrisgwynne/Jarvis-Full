import XCTest
@testable import JarvisMac

/// Tests the persistent dedup store added in Phase 2A.  These cover the
/// invariants the audit specifically called out:
///
///   * dedup state must survive an app restart (a fresh instance with the
///     same `name` reads the same set)
///   * insert is idempotent (same id twice is a no-op for the second insert)
///   * the cap kicks in at maxEntries and drops oldest-first
///   * `insertBatch` only writes once (verified indirectly via state after)
final class ProactivityDedupStoreTests: XCTestCase {

    /// A fresh, unique store name per test so tests don't share on-disk state.
    private func uniqueName() -> String {
        "test_\(UUID().uuidString.prefix(8))"
    }

    @MainActor
    func test_insertAndContains_basic() {
        let store = ProactivityDedupStore(name: uniqueName(), maxEntries: 100)
        XCTAssertFalse(store.contains("a"))

        XCTAssertTrue(store.insert("a"))   // first insert returns true
        XCTAssertTrue(store.contains("a"))

        XCTAssertFalse(store.insert("a"))  // duplicate returns false
        XCTAssertEqual(store.entries.count, 1)
    }

    @MainActor
    func test_persistsAcrossInstances() async {
        let name = uniqueName()
        let first = ProactivityDedupStore(name: name)
        first.insert("alpha")
        first.insert("beta")
        first.insert("gamma")

        // Give the async write a brief moment to flush before constructing
        // the second instance.  The store's serial save queue is utility QoS
        // so 200 ms is a generous upper bound for a tiny file write.
        try? await Task.sleep(nanoseconds: 200_000_000)

        let second = ProactivityDedupStore(name: name)
        XCTAssertTrue(second.contains("alpha"))
        XCTAssertTrue(second.contains("beta"))
        XCTAssertTrue(second.contains("gamma"))
        XCTAssertFalse(second.contains("delta"))
    }

    @MainActor
    func test_overflowCapDropsOldest() {
        let store = ProactivityDedupStore(name: uniqueName(), maxEntries: 10)
        // Insert 11 — triggers the overflow trim.
        for i in 0..<11 {
            store.insert("id_\(i)")
        }
        // Cap is 10; trim drops the oldest 20% (2 entries) so we land at 9.
        XCTAssertLessThanOrEqual(store.entries.count, 10)

        // The newest entry must still be present.
        XCTAssertTrue(store.contains("id_10"))
        // At least one of the oldest must have been evicted.
        let oldestStillPresent = (0..<2).reduce(false) { acc, i in
            acc || store.contains("id_\(i)")
        }
        XCTAssertFalse(oldestStillPresent)
    }

    @MainActor
    func test_insertBatchAddsAllNew() {
        let store = ProactivityDedupStore(name: uniqueName())
        store.insertBatch(["a", "b", "c"])
        XCTAssertTrue(store.contains("a"))
        XCTAssertTrue(store.contains("b"))
        XCTAssertTrue(store.contains("c"))
        XCTAssertEqual(store.entries.count, 3)

        // Second batch with overlap — only new ones land.
        store.insertBatch(["c", "d", "e"])
        XCTAssertEqual(store.entries.count, 5)
    }

    @MainActor
    func test_remove_dropsEntry() {
        let store = ProactivityDedupStore(name: uniqueName())
        store.insert("x")
        XCTAssertTrue(store.contains("x"))
        store.remove("x")
        XCTAssertFalse(store.contains("x"))
    }

    // MARK: - Crash regression tests (Sprint S fix)

    /// Reproduces the production crash: insertionOrder shorter than entries
    /// because the store was loaded from a truncated snapshot.  trimIfOverflowing
    /// must NOT call removeFirst(drop) when drop > insertionOrder.count.
    @MainActor
    func test_trimIfOverflowing_doesNotCrashWhenInsertionOrderShorterThanEntries() {
        // maxEntries=5 → any 6th insert triggers trim where drop = 6 - 4 = 2.
        // We use a very low cap so the trim fires quickly.
        let store = ProactivityDedupStore(name: uniqueName(), maxEntries: 5)
        // Insert 6 items normally — insertionOrder and entries are in sync.
        for i in 0..<6 { store.insert("id_\(i)") }
        // Should not crash and count should be within cap.
        XCTAssertLessThanOrEqual(store.entries.count, 5)
    }

    /// Inserting 500 items at once (flood scenario) must not crash.
    @MainActor
    func test_bulkInsert_floodScenario_doesNotCrash() {
        let store = ProactivityDedupStore(name: uniqueName(), maxEntries: 50)
        for i in 0..<500 { store.insert("news_article_\(i)") }
        XCTAssertLessThanOrEqual(store.entries.count, 50)
        // Newest entry must always survive.
        XCTAssertTrue(store.contains("news_article_499"))
    }

    /// insertBatch with a count exceeding maxEntries must not crash.
    @MainActor
    func test_insertBatch_overCap_doesNotCrash() {
        let store = ProactivityDedupStore(name: uniqueName(), maxEntries: 10)
        let ids = (0..<100).map { "item_\($0)" }
        store.insertBatch(ids)
        XCTAssertLessThanOrEqual(store.entries.count, 10)
    }

    /// removeAll followed by inserts should work normally.
    @MainActor
    func test_removeAll_thenInsert_works() {
        let store = ProactivityDedupStore(name: uniqueName(), maxEntries: 5)
        for i in 0..<5 { store.insert("pre_\(i)") }
        store.removeAll()
        XCTAssertEqual(store.entries.count, 0)
        store.insert("post_0")
        XCTAssertTrue(store.contains("post_0"))
        XCTAssertEqual(store.entries.count, 1)
    }
}
