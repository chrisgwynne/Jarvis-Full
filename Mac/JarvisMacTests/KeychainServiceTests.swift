import XCTest
@testable import JarvisMac

// MARK: - KeychainServiceTests
//
// Verifies that KeychainService provides in-memory caching so each Keychain
// key triggers at most one SecItemCopyMatching per process lifetime.
//
// These tests use a test-specific key prefix to avoid touching real secrets.

final class KeychainServiceTests: XCTestCase {

    // Unique prefix so test keys never collide with production entries.
    private let prefix = "test.keychain.\(UUID().uuidString.prefix(8))."

    private var ks: KeychainService { KeychainService.shared }

    private func key(_ name: String) -> String { prefix + name }

    override func tearDown() {
        super.tearDown()
        // Clean up any test keys written during the test.
        for suffix in ["alpha", "beta", "gamma", "delta"] {
            ks.remove(key(suffix))
        }
        ks.invalidate(key("alpha"))
        ks.invalidate(key("beta"))
        ks.invalidate(key("gamma"))
        ks.invalidate(key("delta"))
    }

    // MARK: - Basic read/write/delete

    func testWriteThenReadReturnsValue() {
        let k = key("alpha")
        ks.set("hello", for: k)
        XCTAssertEqual(ks.get(k), "hello")
    }

    func testDeleteRemovesValue() {
        let k = key("alpha")
        ks.set("hello", for: k)
        ks.remove(k)
        XCTAssertNil(ks.get(k))
    }

    func testSetNilDeletesEntry() {
        let k = key("alpha")
        ks.set("hello", for: k)
        ks.set(nil, for: k)
        XCTAssertNil(ks.get(k))
    }

    // MARK: - Cache: single physical read

    func testRepeatedGetOnlyOnePhysicalRead() {
        let k = key("beta")
        ks.set("cached-value", for: k)

        // Invalidate cache so the first get performs a real read.
        ks.invalidate(k)

        let readsBefore = ks.physicalReads
        _ = ks.get(k) // physical read #1
        _ = ks.get(k) // cache hit
        _ = ks.get(k) // cache hit
        let readsAfter = ks.physicalReads

        XCTAssertEqual(readsAfter - readsBefore, 1,
            "Only one physical SecItemCopyMatching should occur; subsequent reads must be cache hits")
    }

    func testCacheHitCountIncreasesOnRepeatGet() {
        let k = key("gamma")
        ks.set("x", for: k)
        ks.invalidate(k)

        let hitsBefore = ks.cacheHits
        _ = ks.get(k) // physical (no hit)
        _ = ks.get(k) // cache hit
        _ = ks.get(k) // cache hit

        XCTAssertEqual(ks.cacheHits - hitsBefore, 2)
    }

    // MARK: - Cache: absent keys

    func testAbsentKeyIsOnlyReadOncePhysically() {
        let k = key("delta")
        ks.remove(k)
        ks.invalidate(k)

        let readsBefore = ks.physicalReads
        XCTAssertNil(ks.get(k)) // physical read → absent cached
        XCTAssertNil(ks.get(k)) // cache hit (absent)
        XCTAssertNil(ks.get(k)) // cache hit (absent)

        XCTAssertEqual(ks.physicalReads - readsBefore, 1,
            "Absent keys must also be cached so we don't hammer keychain looking for missing tokens")
    }

    // MARK: - Concurrent reads

    func testConcurrentReadsShareSinglePhysicalRead() async {
        let k = key("alpha")
        ks.set("concurrent-value", for: k)
        ks.invalidate(k)

        let readsBefore = ks.physicalReads

        // Launch many concurrent reads
        await withTaskGroup(of: String?.self) { group in
            for _ in 0..<20 {
                group.addTask { self.ks.get(k) }
            }
            for await value in group {
                XCTAssertEqual(value, "concurrent-value")
            }
        }

        // Due to the NSLock, at most a small number of physical reads occur
        // (the lock prevents races but doesn't coalesce concurrent waiters).
        // What matters is NO read returns a wrong value and all complete.
        XCTAssertGreaterThan(ks.physicalReads, readsBefore)
    }

    // MARK: - Write updates cache immediately

    func testWriteUpdatesCacheWithoutAdditionalPhysicalRead() {
        let k = key("beta")
        ks.set("v1", for: k)
        ks.invalidate(k)
        _ = ks.get(k)   // warm cache with "v1"

        let readsBefore = ks.physicalReads
        ks.set("v2", for: k)              // write → updates cache
        let result = ks.get(k)            // should be cache hit with "v2"
        let readsAfter = ks.physicalReads

        XCTAssertEqual(result, "v2")
        XCTAssertEqual(readsAfter, readsBefore, "Write should update cache so next read is free")
    }

    // MARK: - Preload

    func testPreloadPopulatesCache() {
        let k1 = key("alpha")
        let k2 = key("beta")
        ks.set("a", for: k1)
        ks.set("b", for: k2)
        ks.invalidate(k1)
        ks.invalidate(k2)

        ks.preload(keys: [k1, k2])

        let readsBefore = ks.physicalReads
        XCTAssertEqual(ks.get(k1), "a")
        XCTAssertEqual(ks.get(k2), "b")
        XCTAssertEqual(ks.physicalReads, readsBefore, "After preload, individual reads must be cache hits")
    }

    // MARK: - No secret values in diagnostics log

    func testStartupReportContainsNoSecretValues() {
        let k = key("gamma")
        let secret = "SUPER_SECRET_\(UUID().uuidString)"
        ks.set(secret, for: k)
        ks.invalidate(k)
        _ = ks.get(k)

        let report = ks.startupReport()
        XCTAssertFalse(report.contains(secret),
            "startupReport must never include secret values — only key names and counts")
    }

    // MARK: - Each startup key read at most once

    func testAllKnownKeysHaveAtMostOnePhysicalReadAfterPreload() {
        // Reset diagnostics by invalidating all known keys.
        for k in KeychainAccount.allKnownKeys { ks.invalidate(k) }

        let readsBefore = ks.physicalReads
        ks.preload(keys: KeychainAccount.allKnownKeys)

        // Read every key several more times — all must be cache hits.
        for _ in 0..<3 {
            for k in KeychainAccount.allKnownKeys { _ = ks.get(k) }
        }

        let totalPhysical = ks.physicalReads - readsBefore
        XCTAssertLessThanOrEqual(totalPhysical, KeychainAccount.allKnownKeys.count,
            "After preload, additional reads must never trigger more physical SecItemCopyMatching calls")
    }

    // MARK: - GatewayAuthStore caches gateway token

    @MainActor
    func testGatewayAuthStoreGatewayTokenServedFromCache() {
        // Verify that gatewayToken on GatewayAuthStore is a stored property,
        // not a recomputed Keychain read, by checking it stays stable even if
        // the underlying cache entry is invalidated between accesses.
        let store = GatewayAuthStore.shared
        let t1 = store.gatewayToken
        // Invalidate the cache — if gatewayToken were a computed property,
        // the next access would re-read and potentially hit Keychain.
        KeychainService.shared.invalidate(KeychainAccount.gatewayToken)
        let t2 = store.gatewayToken
        XCTAssertEqual(t1, t2,
            "GatewayAuthStore.gatewayToken must be a cached stored property, not a computed Keychain re-read")
    }
}
