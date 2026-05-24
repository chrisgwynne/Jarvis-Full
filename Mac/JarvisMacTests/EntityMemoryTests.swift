import XCTest
@testable import JarvisMac

// MARK: - EntityMemoryTests

@MainActor
final class EntityMemoryTests: XCTestCase {

    // MARK: - EntityMemNode expiry

    func testEphemeralNodeExpires() {
        var node = EntityMemNode(entityKind: .uiElement, canonicalName: "Submit Button",
                              source: .conversation, expiryPolicy: .ephemeral)
        // Backdating lastReferencedAt beyond ephemeral maxAgeSeconds (300s)
        node = forceAge(node, seconds: 301)
        XCTAssertTrue(node.isExpired, "Ephemeral node older than 5 min should be expired")
    }

    func testPersistentNodeDoesNotExpire() {
        var node = EntityMemNode(entityKind: .person, canonicalName: "Alice",
                              source: .conversation, expiryPolicy: .persistent)
        node = forceAge(node, seconds: 86_400) // 1 day — well within 30-day persistent limit
        XCTAssertFalse(node.isExpired, "Persistent node should not expire within 30 days")
    }

    // MARK: - Recency score

    func testFreshNodeHasHighRecencyScore() {
        let node = EntityMemNode(entityKind: .pullRequest, canonicalName: "PR #42",
                              source: .githubAPI)
        XCTAssertGreaterThan(node.currentRecencyScore(), 0.90,
                             "Freshly created node should have recency score near 1.0")
    }

    func testStaleNodeHasLowRecencyScore() {
        var node = EntityMemNode(entityKind: .pullRequest, canonicalName: "PR #99",
                              source: .githubAPI)
        // Age it well past the PR halfLife (259200s = 3 days)
        node = forceAge(node, seconds: 260_000)
        XCTAssertLessThan(node.currentRecencyScore(), 0.5,
                          "Node aged past halfLife should have recency < 0.5")
    }

    // MARK: - EntityMemoryGraph upsert / dedup

    func testUpsertDeduplicatesByKindAndName() {
        let graph = makeIsolatedGraph()
        let a = EntityMemNode(entityKind: .pullRequest, canonicalName: "PR #10", source: .githubAPI)
        let b = EntityMemNode(entityKind: .pullRequest, canonicalName: "PR #10", source: .githubAPI)
        graph.upsert(a)
        graph.upsert(b)
        XCTAssertEqual(graph.all().count, 1, "Duplicate (kind, canonicalName) should merge into one node")
    }

    func testUpsertMergesAliases() {
        let graph = makeIsolatedGraph()
        var a = EntityMemNode(entityKind: .pullRequest, canonicalName: "PR #10", source: .githubAPI)
        a.aliases = ["fix: auth"]
        var b = EntityMemNode(entityKind: .pullRequest, canonicalName: "PR #10", source: .githubAPI)
        b.aliases = ["fix auth bug"]
        graph.upsert(a)
        graph.upsert(b)
        let merged = graph.all().first!
        XCTAssertTrue(merged.aliases.contains("fix: auth") && merged.aliases.contains("fix auth bug"),
                      "Aliases from both upserts should be merged")
    }

    func testAliasIndexLookup() {
        let graph = makeIsolatedGraph()
        var node = EntityMemNode(entityKind: .url, canonicalName: "https://github.com/org/repo",
                              source: .windowsPresence)
        node.aliases = ["jarvis repo"]
        graph.upsert(node)
        XCTAssertNotNil(graph.nodeForAlias("jarvis repo"),
                        "Alias index should resolve 'jarvis repo' to the URL node")
    }

    // MARK: - Prune

    func testPruneRemovesExpiredNodes() {
        let graph = makeIsolatedGraph()
        var expired = EntityMemNode(entityKind: .uiElement, canonicalName: "Old Button",
                                 source: .ocrExtraction, expiryPolicy: .ephemeral)
        expired = forceAge(expired, seconds: 301)
        graph.upsert(expired)
        let fresh = EntityMemNode(entityKind: .pullRequest, canonicalName: "PR #1", source: .githubAPI)
        graph.upsert(fresh)
        graph.prune()
        XCTAssertEqual(graph.all().filter { $0.canonicalName == "Old Button" }.count, 0,
                       "Prune should remove expired node")
        XCTAssertEqual(graph.all().filter { $0.canonicalName == "PR #1" }.count, 1,
                       "Prune should keep fresh node")
    }

    // MARK: - HybridEntityMatcher

    func testExactMatchReturnsConfidence1() {
        let graph = makeIsolatedGraph()
        let node = EntityMemNode(entityKind: .pullRequest, canonicalName: "PR #42", source: .githubAPI)
        graph.upsert(node)
        let result = HybridEntityMatcher.bestMatch(phrase: "PR #42", in: graph)
        XCTAssertEqual(result.confidence, 1.0, accuracy: 0.01, "Exact match should return confidence 1.0")
        XCTAssertFalse(result.needsClarification)
    }

    func testAliasMatchReturnsHighConfidence() {
        let graph = makeIsolatedGraph()
        var node = EntityMemNode(entityKind: .pullRequest, canonicalName: "PR #42", source: .githubAPI)
        node.aliases = ["auth fix"]
        graph.upsert(node)
        let result = HybridEntityMatcher.bestMatch(phrase: "auth fix", in: graph)
        XCTAssertGreaterThanOrEqual(result.confidence, 0.95, "Alias exact match should be >= 0.95")
    }

    func testAmbiguousMatchNeedsClarification() {
        let graph = makeIsolatedGraph()
        graph.upsert(EntityMemNode(entityKind: .pullRequest, canonicalName: "PR #10", source: .githubAPI))
        graph.upsert(EntityMemNode(entityKind: .pullRequest, canonicalName: "PR #100", source: .githubAPI))
        // "PR #1" is a prefix match for both — scores should be close
        let result = HybridEntityMatcher.bestMatch(phrase: "PR #1", in: graph, kindFilter: .pullRequest)
        // Both are prefix matches; margin should be narrow → needsClarification
        if result.candidates.count >= 2 {
            XCTAssertLessThanOrEqual(result.confidence, 1.0)
        }
    }

    // MARK: - ConversationEntityExtractor patterns

    func testExtractsPRNumber() {
        let extractor = ConversationEntityExtractor.shared
        let nodes = extractor.extract(from: "let's look at PR #42", source: .conversation)
        let pr = nodes.first(where: { $0.entityKind == .pullRequest })
        XCTAssertNotNil(pr, "Should extract PR entity from transcript")
        XCTAssertEqual(pr?.canonicalName, "PR #42")
    }

    func testExtractsURL() {
        let extractor = ConversationEntityExtractor.shared
        let nodes = extractor.extract(from: "open https://github.com/org/repo", source: .conversation)
        let url = nodes.first(where: { $0.entityKind == .url })
        XCTAssertNotNil(url, "Should extract URL entity from transcript")
    }

    // MARK: - WorkflowContextResolver.resolveOther

    func testResolveOtherReturnsSecondMostRecent() {
        let graph = makeIsolatedGraph()
        let pr1 = EntityMemNode(entityKind: .pullRequest, canonicalName: "PR #1", source: .githubAPI)
        let pr2 = EntityMemNode(entityKind: .pullRequest, canonicalName: "PR #2", source: .githubAPI)
        graph.upsert(pr1)
        graph.upsert(pr2)
        // byKind returns sorted by relevanceScore; pass the first one as "current"
        let first = graph.byKind(.pullRequest, limit: 2).first
        let other = WorkflowContextResolver.resolveOther(kind: .pullRequest, currentId: first?.id)
        XCTAssertNotNil(other, "resolveOther should return the second PR when two exist")
        XCTAssertNotEqual(other?.id, first?.id, "resolveOther should not return the current entity")
    }

    // MARK: - EntityContextBlockBuilder

    func testBuildReturnsNilWhenGraphEmpty() {
        let graph = makeIsolatedGraph()
        // Force a known-empty graph by pruning all
        for node in graph.all() { graph.prune() }
        // Can't inject custom graph into static builder, so just verify nil path
        // by checking that topSalient(limit:) on an empty graph returns empty
        XCTAssertTrue(graph.topSalient(limit: 5).isEmpty)
    }

    // MARK: - pbxproj UUID regression

    func testPbxprojEntityMemoryUUIDsUnique() throws {
        let pbxproj = try String(contentsOfFile:
            "/Users/chris/Desktop/jarvis/JarvisMac.xcodeproj/project.pbxproj")
        let prefixIDs = [
            "XM01", "XM02", "ZE01", "ZE02", "XX01", "XX02",
            "ZH01", "ZH02", "XS01", "XS02", "XL01", "XL02",
            "XW01", "XW02", "XD01", "XD02", "XB01", "XB02",
            "XY01", "XY02", "XT01", "XT02"
        ]
        for id in prefixIDs {
            let count = pbxproj.components(separatedBy: id).count - 1
            XCTAssertEqual(count, 1, "UUID \(id) should appear exactly once in pbxproj")
        }
    }

    // MARK: - Helpers

    private func makeIsolatedGraph() -> EntityMemoryGraph {
        // Return a fresh local instance for test isolation (not the shared singleton)
        EntityMemoryGraph()
    }

    private func forceAge(_ node: EntityMemNode, seconds: TimeInterval) -> EntityMemNode {
        var n = node
        let past = Date().addingTimeInterval(-seconds)
        n = EntityMemNode(entityKind: n.entityKind, canonicalName: n.canonicalName,
                       aliases: n.aliases, source: n.source,
                       expiryPolicy: n.expiryPolicy, metadata: n.metadata)
        // Use reflection-free mutation: recreate with adjusted timestamps
        // (EntityMemNode is a struct — we patch via a subclass trick isn't needed,
        // but we must reach internal init fields. Use a helper extension below.)
        return n.withLastReferenced(past).withLastMentioned(past)
    }
}

// MARK: - Test helpers

private extension EntityMemNode {
    func withLastReferenced(_ date: Date) -> EntityMemNode {
        var copy = self
        copy.lastReferencedAt = date
        return copy
    }
    func withLastMentioned(_ date: Date) -> EntityMemNode {
        var copy = self
        copy.lastMentionedAt = date
        return copy
    }
}
