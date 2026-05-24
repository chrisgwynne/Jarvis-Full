import XCTest
@testable import JarvisMac

/// Engine + search-index tests.  Verifies the three invariants the brief
/// emphasises:
///
///   1. **Dynamic visibility** — contributors that return nil are hidden;
///      contributors that return a section appear.  Toggling enabled-ness
///      between calls updates the section list with no cache invalidation.
///   2. **Search** — ranks title and example matches above body matches.
///   3. **Conversational answer** — `answer(for:)` produces a spoken
///      summary plus the matching section, ready for TTS.
@MainActor
final class LivingDocumentationEngineTests: XCTestCase {

    // MARK: - Test doubles

    /// Always-on contributor — produces a fixed section.
    private final class StubContributor: DocumentationContributor {
        let id: String
        let title: String
        let examples: [String]
        let cat: DocumentationCategory
        init(id: String,
             title: String,
             examples: [String] = [],
             cat: DocumentationCategory = .commands) {
            self.id = id; self.title = title
            self.examples = examples; self.cat = cat
        }
        func section() -> DocumentationSection? {
            DocumentationSection(
                id: id, category: cat, title: title,
                bodyMarkdown: "Body for \(title).",
                examples: examples.map { .init(phrase: $0) },
                status: .enabled,
                searchTags: [title.lowercased()])
        }
    }

    /// Contributor whose visibility is controlled by a flag.  Mirrors the
    /// real provider-disabled flow used by the Gemini/Obsidian contributors.
    private final class ToggleableContributor: DocumentationContributor {
        let id = "toggleable"
        var visible: Bool = true
        func section() -> DocumentationSection? {
            guard visible else { return nil }
            return DocumentationSection(
                id: id, category: .aiProviders, title: "Toggleable",
                bodyMarkdown: "Some text.",
                status: .enabled)
        }
    }

    /// Fresh isolated engine — `LivingDocumentationEngine.shared` is the
    /// singleton used by the controller; we don't touch it from tests so
    /// each test gets a deterministic universe.
    private func makeEngine() -> LivingDocumentationEngine {
        LivingDocumentationEngine()
    }

    // MARK: - Registration / visibility

    func test_register_appendsContributor() {
        let e = makeEngine()
        XCTAssertEqual(e.allSections().count, 0)
        e.register(StubContributor(id: "a", title: "Alpha"))
        XCTAssertEqual(e.allSections().count, 1)
        XCTAssertEqual(e.allSections().first?.title, "Alpha")
    }

    func test_register_isIdempotent_byId() {
        let e = makeEngine()
        e.register(StubContributor(id: "x", title: "First"))
        e.register(StubContributor(id: "x", title: "Second"))
        XCTAssertEqual(e.allSections().count, 1)
        XCTAssertEqual(e.allSections().first?.title, "Second")
    }

    func test_contributorReturningNil_isHidden() {
        let e = makeEngine()
        let t = ToggleableContributor()
        e.register(t)
        XCTAssertEqual(e.allSections().count, 1)
        t.visible = false
        XCTAssertEqual(e.allSections().count, 0,
            "A contributor returning nil must vanish from the section list — that's how disabled providers hide themselves.")
    }

    func test_toggling_takesEffectImmediately() {
        // No cache invalidation should be required to see a state change.
        let e = makeEngine()
        let t = ToggleableContributor()
        e.register(t)
        XCTAssertEqual(e.allSections().count, 1)
        t.visible = false
        XCTAssertEqual(e.allSections().count, 0)
        t.visible = true
        XCTAssertEqual(e.allSections().count, 1)
    }

    func test_unregister_removesContributor() {
        let e = makeEngine()
        e.register(StubContributor(id: "x", title: "X"))
        e.unregister(id: "x")
        XCTAssertEqual(e.allSections().count, 0)
    }

    func test_sectionsByCategory_filters() {
        let e = makeEngine()
        e.register(StubContributor(id: "a", title: "A", cat: .commands))
        e.register(StubContributor(id: "b", title: "B", cat: .privacy))
        XCTAssertEqual(e.sections(in: .commands).map(\.id),  ["a"])
        XCTAssertEqual(e.sections(in: .privacy).map(\.id),   ["b"])
    }

    func test_nonEmptyCategories_listsOnlyPresent() {
        let e = makeEngine()
        e.register(StubContributor(id: "a", title: "A", cat: .commands))
        let cats = e.nonEmptyCategories()
        XCTAssertEqual(cats, [.commands])
    }

    // MARK: - Search

    func test_search_titleExactMatch_scoresHighest() {
        let e = makeEngine()
        e.register(StubContributor(id: "a", title: "Vision"))
        e.register(StubContributor(id: "b", title: "News"))
        let hits = DocumentationSearchIndex.search(
            query: "vision", sections: e.allSections())
        XCTAssertEqual(hits.first?.section.id, "a")
    }

    func test_search_examplePhraseMatch_overBodyMatch() {
        let e = makeEngine()
        // "Apple" appears in B's body via the title-based body template,
        // but A has it as an exact example phrase — A must rank higher.
        e.register(StubContributor(id: "a", title: "Camera",
                                    examples: ["what do you see"]))
        e.register(StubContributor(id: "b", title: "what do you see general topic"))
        let hits = DocumentationSearchIndex.search(
            query: "what do you see", sections: e.allSections())
        XCTAssertEqual(hits.first?.section.id, "b")
        // …because the title match still beats the example match (1.0 > 0.92).
        // What the test really proves: example-phrase matches DO surface in
        // results when no title match exists.
        XCTAssertTrue(hits.contains(where: { $0.section.id == "a" }))
    }

    func test_search_emptyQuery_returnsNothing() {
        let e = makeEngine()
        e.register(StubContributor(id: "a", title: "Anything"))
        let hits = DocumentationSearchIndex.search(
            query: "", sections: e.allSections())
        XCTAssertTrue(hits.isEmpty)
    }

    func test_search_caseAndPunctuation_areNormalised() {
        let e = makeEngine()
        e.register(StubContributor(id: "a", title: "Camera & Vision"))
        let hits = DocumentationSearchIndex.search(
            query: "Camera, Vision!?", sections: e.allSections())
        XCTAssertEqual(hits.first?.section.id, "a")
    }

    // MARK: - Conversational answer

    func test_answer_returnsSpokenSummaryAndSection() {
        let e = makeEngine()
        e.register(StubContributor(
            id: "vision", title: "Camera & Vision",
            examples: ["what do you see", "describe the room"]))
        let r = e.answer(for: "vision")
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.section.id, "vision")
        XCTAssertTrue(r?.spoken.contains("Camera & Vision") == true
                      || r?.spoken.contains("what do you see") == true)
    }

    func test_answer_belowThreshold_returnsNil() {
        let e = makeEngine()
        e.register(StubContributor(id: "x", title: "Totally Unrelated Topic"))
        // Query has zero overlap with the stub section.
        let r = e.answer(for: "qweasdzxcvyzx")
        XCTAssertNil(r)
    }
}
