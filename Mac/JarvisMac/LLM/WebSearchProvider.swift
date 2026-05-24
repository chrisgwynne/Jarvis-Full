import Foundation

// MARK: - WebSearchProvider protocol

/// Pluggable web-search backend.  Real implementations (Brave Search,
/// DuckDuckGo, SerpAPI, etc.) conform to this protocol and are selected
/// via Settings.  The disabled default `NoopWebSearchProvider` is wired
/// in by default so call sites compile and return `nil` until the user
/// configures a real provider.
///
/// Returning `nil` from `search(query:)` is the documented "no search
/// available" signal — callers fall through to LLM free-text answer.
protocol WebSearchProvider: AnyObject, Sendable {
    /// Stable id for diagnostics ("brave", "ddg", "serpapi", "noop").
    var id: String { get }
    /// Whether the provider can answer right now (key present, online, etc).
    func isAvailable() async -> Bool
    /// Returns up to `limit` results, newest/most-relevant first.  Returns
    /// nil when no provider is configured or all attempts fail; the caller
    /// then falls back to a pure LLM answer.
    func search(query: String, limit: Int) async -> WebSearchResults?
}

// MARK: - WebSearchResults

/// One web search response — a list of results plus a short LLM-renderable
/// digest the caller can hand to TTS without further processing.
struct WebSearchResults: Sendable, Equatable {
    let query: String
    let results: [WebSearchResult]
    /// Provider-supplied digest if it has one (some search APIs return an
    /// answer-card snippet); nil → caller asks the LLM to summarise.
    let answerDigest: String?
    let timestamp: Date

    var isEmpty: Bool { results.isEmpty && (answerDigest ?? "").isEmpty }
}

struct WebSearchResult: Sendable, Equatable, Identifiable {
    let id: UUID
    let title: String
    let url: String
    let snippet: String

    init(title: String, url: String, snippet: String) {
        self.id = UUID()
        self.title = title
        self.url = url
        self.snippet = snippet
    }
}

// MARK: - Noop implementation

/// The "no web search configured" default.  Always returns nil.  Wired
/// into `JarvisController` by default so the conversational pipeline can
/// reference `webSearch` without any settings work — and so future real
/// providers drop in without changing the call site.
final class NoopWebSearchProvider: WebSearchProvider, @unchecked Sendable {
    let id = "noop"
    func isAvailable() async -> Bool { false }
    func search(query: String, limit: Int) async -> WebSearchResults? { nil }
}
