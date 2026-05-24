import XCTest
@testable import JarvisMac

/// Tests the cross-subsystem context registry.  Two invariants matter
/// most for the global-fallback bug:
///
///   1. `resolve(pronoun:)` returns the highest-priority recent item that
///      answers to that pronoun — drives "call him back" / "open it" /
///      "summarise that".
///   2. `resolve(pronoun: ordinal:)` indexes into the matching candidates
///      in newest-first order — drives "open the second one".
@MainActor
final class ActiveContextRegistryTests: XCTestCase {

    /// Fresh registry per test — `shared` is a singleton, so we use a
    /// local instance.  Production code always reads `shared`; the
    /// instance API is identical.
    private func makeRegistry() -> ActiveContextRegistry {
        ActiveContextRegistry(maxItems: 50)
    }

    // MARK: - Basic insertion and order

    func test_record_insertsNewestFirst() {
        let reg = makeRegistry()
        reg.record(source: .camera, title: "Scene A")
        reg.record(source: .camera, title: "Scene B")
        XCTAssertEqual(reg.items.first?.title, "Scene B")
        XCTAssertEqual(reg.items.count, 2)
    }

    func test_maxItemsCap_dropsOldest() {
        let reg = ActiveContextRegistry(maxItems: 3)
        for i in 0..<5 {
            reg.record(source: .camera, title: "T\(i)")
        }
        XCTAssertEqual(reg.items.count, 3)
        XCTAssertEqual(reg.items.map(\.title), ["T4", "T3", "T2"])
    }

    // MARK: - Pronoun resolution

    func test_resolvePronounIt_returnsMostRecent() {
        let reg = makeRegistry()
        reg.record(source: .shopifyOrder, title: "#1041")
        reg.record(source: .camera, title: "Scene", priority: 2)
        let r = reg.resolve(pronoun: "it")
        XCTAssertEqual(r?.title, "Scene")
    }

    func test_resolvePronounHim_picksAndroidCallCandidate() {
        let reg = makeRegistry()
        reg.record(source: .camera, title: "Scene", priority: 2)
        reg.record(source: .androidCall,
                    title: "Mike",
                    pronouns: ["him", "her", "they"],
                    priority: 3)
        let r = reg.resolve(pronoun: "him")
        XCTAssertEqual(r?.title, "Mike")
        XCTAssertEqual(r?.source, .androidCall)
    }

    func test_higherPriority_beatsOlderRecency() {
        let reg = makeRegistry()
        // Add a low-priority item just now…
        reg.record(source: .obsidianNote, title: "Note", priority: 0)
        // …and a high-priority item a microsecond later.
        reg.record(source: .androidCall, title: "Mike",
                    pronouns: ["him"], priority: 3)
        let r = reg.resolve(pronoun: "him")
        XCTAssertEqual(r?.title, "Mike")
    }

    // MARK: - Ordinal resolution

    func test_resolveOrdinal_picksFromMatchingCandidates() {
        let reg = makeRegistry()
        // File search produces three items, newest-first.
        reg.record(source: .fileSearchResult, title: "result-3",
                    pronouns: ["them"])
        reg.record(source: .fileSearchResult, title: "result-2",
                    pronouns: ["them"])
        reg.record(source: .fileSearchResult, title: "result-1",
                    pronouns: ["them"])
        // "the second one" → second among the newest-first matches.
        let second = reg.resolve(pronoun: "them", ordinal: 2)
        XCTAssertEqual(second?.title, "result-2")
    }

    func test_resolveOrdinal_outOfRange_returnsNil() {
        let reg = makeRegistry()
        reg.record(source: .fileSearchResult, title: "only-one",
                    pronouns: ["them"])
        let oob = reg.resolve(pronoun: "them", ordinal: 5)
        XCTAssertNil(oob)
    }

    // MARK: - Window cutoff

    func test_recentWindow_excludesOldItems() {
        let reg = makeRegistry()
        reg.record(source: .camera, title: "old")
        // A 0-second window means nothing returned.
        let recent = reg.recent(within: 0)
        XCTAssertTrue(recent.isEmpty)
    }

    // MARK: - LLM context block

    func test_contextBlock_includesEverySource() {
        let reg = makeRegistry()
        reg.record(source: .shopifyOrder, title: "#1041",
                    summary: "Cath — £42")
        reg.record(source: .androidCall, title: "Mike",
                    summary: "Incoming call",
                    pronouns: ["him"], priority: 3)
        let block = reg.contextBlock(maxItems: 8)
        // Source rawValue is the case name as-is (lowerCamelCase, not snake_case).
        XCTAssertTrue(block.contains("[androidCall]"))
        XCTAssertTrue(block.contains("[shopifyOrder]"))
        XCTAssertTrue(block.contains("Mike"))
        XCTAssertTrue(block.contains("#1041"))
    }

    func test_contextBlock_isEmpty_whenNoItems() {
        let reg = makeRegistry()
        XCTAssertEqual(reg.contextBlock(), "")
    }

    // MARK: - Clear

    func test_clear_emptiesRegistry() {
        let reg = makeRegistry()
        reg.record(source: .camera, title: "x")
        reg.clear()
        XCTAssertTrue(reg.items.isEmpty)
    }
}
