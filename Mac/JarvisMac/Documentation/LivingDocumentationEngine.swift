import Foundation

// MARK: - DocumentationContributor

/// Anything that contributes a `DocumentationSection` to the living help
/// system implements this protocol.  Built-in contributors live alongside
/// the engine; new subsystems just register their own at app launch.
///
/// `section()` returns `nil` to say "I have nothing to document right now"
/// — the engine simply skips it.  That's how disabled providers (Gemini
/// off, Obsidian off) hide their own docs without the engine knowing.
@MainActor
protocol DocumentationContributor: AnyObject {
    /// Stable identifier — `"android.calls"`, `"vision.camera"`, etc.
    /// Used as a sort key in the sidebar and as the dedupe key in caches.
    var id: String { get }
    /// Produce a section *now* based on current runtime state.  Return
    /// `nil` to hide this contributor entirely (e.g. an LLM provider
    /// the user has disabled).
    func section() -> DocumentationSection?
}

// MARK: - LivingDocumentationEngine

/// Process-global registry + producer of `DocumentationSection` values.
/// Every section is regenerated freshly on each `allSections()` call so
/// status badges, examples, and troubleshooting items reflect the *live*
/// state of the app.
///
/// Why no cache? Sections are cheap (~20 KB of strings combined), and the
/// help overlay is opened rarely.  Re-rendering on each open removes the
/// "stale docs" class of bug — toggling a provider in Settings doesn't
/// require any cache invalidation logic on our side.
@MainActor
final class LivingDocumentationEngine {

    /// Shared instance so the help overlay and the conversational
    /// `documentationLookup` intent see the same set of contributors.
    static let shared = LivingDocumentationEngine()

    private var contributors: [DocumentationContributor] = []

    init() {}

    // MARK: - Registration

    /// Register a contributor.  Idempotent — a contributor with the same
    /// `id` replaces any previous registration.
    func register(_ contributor: DocumentationContributor) {
        contributors.removeAll { $0.id == contributor.id }
        contributors.append(contributor)
    }

    /// Unregister a contributor (rarely used; mainly for tests).
    func unregister(id: String) {
        contributors.removeAll { $0.id == id }
    }

    func registeredIds() -> [String] {
        contributors.map { $0.id }
    }

    // MARK: - Query

    /// Build all sections fresh.  Disabled contributors return nil and
    /// are skipped.  Sorted by category (declared order) then title.
    func allSections() -> [DocumentationSection] {
        let raw = contributors.compactMap { $0.section() }
        return raw.sorted { lhs, rhs in
            if lhs.category != rhs.category {
                let order = DocumentationCategory.allCases
                let li = order.firstIndex(of: lhs.category) ?? 0
                let ri = order.firstIndex(of: rhs.category) ?? 0
                return li < ri
            }
            return lhs.title < rhs.title
        }
    }

    /// Sections in a single category.  Useful for the sidebar grouping.
    func sections(in category: DocumentationCategory) -> [DocumentationSection] {
        allSections().filter { $0.category == category }
    }

    /// Lookup by stable id.  Returns nil when the contributor declined
    /// (e.g. a Gemini section requested while Gemini is disabled).
    func section(id: String) -> DocumentationSection? {
        allSections().first(where: { $0.id == id })
    }

    /// Categories that have at least one visible section right now.
    /// Drives the sidebar so empty categories don't render.
    func nonEmptyCategories() -> [DocumentationCategory] {
        let visible = Set(allSections().map { $0.category })
        return DocumentationCategory.allCases.filter { visible.contains($0) }
    }

    // MARK: - Conversational helper

    /// Answer a user's "how do I…" / "what can you do with…" question
    /// from live documentation.  Returns a short spoken summary plus the
    /// matching section (so the overlay can deep-link), or nil if nothing
    /// scored above the minimum-confidence threshold.
    func answer(for query: String) -> (spoken: String, section: DocumentationSection)? {
        let hits = DocumentationSearchIndex.search(
            query: query, sections: allSections(), limit: 3)
        guard let top = hits.first, top.score >= 0.20 else { return nil }
        let s = top.section

        // Build a 1–2-sentence spoken summary.  Prefer the subtitle when
        // present (those are written for spoken consumption); otherwise
        // synthesise from the first example.
        var spoken = s.subtitle ?? s.title
        if let firstExample = s.examples.first {
            spoken += " For example: \"\(firstExample.phrase)\"."
        }
        if s.status == .disabled || s.status == .notConfigured {
            spoken += " (Currently \(s.status.rawValue) — check Settings.)"
        }
        return (spoken, s)
    }
}

// MARK: - DocumentationSearchIndex

/// Substring + word-stem search over the section corpus.  Tiny enough
/// (under 50 sections) that we don't need a real index — every query
/// scans all sections.  ~1 ms typical.
///
/// Scoring (highest wins):
///   * title contains query        → 1.0
///   * exact example phrase match  → 0.9
///   * example phrase contains q   → 0.7
///   * troubleshooting symptom     → 0.6
///   * search tag                  → 0.5
///   * body contains query         → 0.3 + per-word bonus
enum DocumentationSearchIndex {

    static func search(query: String,
                       sections: [DocumentationSection],
                       limit: Int = 8) -> [DocumentationSearchResult] {
        let q = normalise(query)
        guard !q.isEmpty else { return [] }
        let qWords = q.split(separator: " ").map(String.init)

        var results: [DocumentationSearchResult] = []
        for s in sections {
            let scored = score(section: s, q: q, qWords: qWords)
            if scored.score > 0 {
                results.append(scored)
            }
        }
        return results
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Scoring

    private static func score(section: DocumentationSection,
                              q: String,
                              qWords: [String])
        -> DocumentationSearchResult {

        var bestScore = 0.0
        var bestField: DocumentationSearchResult.MatchField = .body

        // Title
        let title = normalise(section.title)
        if title == q                                  { bestScore = 1.0; bestField = .title }
        else if title.contains(q)                      { bestScore = max(bestScore, 0.95); bestField = .title }
        // Examples — exact then contains
        for ex in section.examples {
            let p = normalise(ex.phrase)
            if p == q {
                bestScore = max(bestScore, 0.92)
                bestField = .examplePhrase
            } else if p.contains(q) {
                bestScore = max(bestScore, 0.78)
                bestField = .examplePhrase
            } else if qWords.allSatisfy({ p.contains($0) }) {
                bestScore = max(bestScore, 0.65)
                bestField = .examplePhrase
            }
        }
        // Troubleshooting symptom
        for t in section.troubleshooting {
            let s = normalise(t.symptom)
            if s.contains(q) {
                bestScore = max(bestScore, 0.65)
                bestField = .troubleshootingSymptom
            }
        }
        // Search tags
        for tag in section.searchTags {
            let t = normalise(tag)
            if t == q || t.contains(q) {
                bestScore = max(bestScore, 0.55)
                bestField = .tag
            }
        }
        // Body — word-overlap bonus.  Cheap heuristic: count how many
        // query words appear; score scales with coverage.
        let body = normalise(section.bodyMarkdown)
        if body.contains(q) {
            bestScore = max(bestScore, 0.35)
            bestField = .body
        }
        let matched = qWords.reduce(0) { $0 + (body.contains($1) ? 1 : 0) }
        if matched > 0 && qWords.count > 1 {
            let coverage = Double(matched) / Double(qWords.count)
            let bonus = 0.15 * coverage
            if bonus + 0.15 > bestScore {
                bestScore = max(bestScore, 0.15 + bonus)
                bestField = .body
            }
        }

        return DocumentationSearchResult(
            section: section, score: bestScore, matchedField: bestField)
    }

    static func normalise(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "[.,!?;:'\"]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
