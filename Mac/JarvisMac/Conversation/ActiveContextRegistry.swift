import Foundation

// MARK: - ActiveContextItem

/// A single piece of "what Jarvis last did or saw" that follow-up commands
/// can refer to via pronouns ("it", "that", "him", "the second one", …).
///
/// Sourced from every subsystem — camera describes the desk, the Android
/// bridge reports an incoming call, Shopify lists 3 orders, the file-search
/// overlay lists results, the proactivity engine speaks an alert — and every
/// one of those events pushes one or more `ActiveContextItem` values into
/// `ActiveContextRegistry`.  The conversational layer reads back from the
/// registry when it needs to resolve a referring expression.
///
/// **Privacy:** `summary` is short and not for LLM logging.  Caller decides
/// whether to include a particular field when serialising for the LLM
/// prompt — see `ActiveContextRegistry.contextBlock(for:)`.
struct ActiveContextItem: Identifiable, Equatable {

    /// Which subsystem produced this item.  Drives both UI affordances and
    /// LLM-context labelling.
    enum Source: String, Codable, Equatable, Hashable {
        case news
        case camera
        case screen
        case androidCall
        case androidSMS
        case androidWhatsApp
        case androidNotification
        case email
        case calendar
        case shopifyOrder
        case todoistTask
        case obsidianNote
        case fileSearchResult
        case webArticle
        case appWindow
        case proactiveAlert
        case llmAnswer
        case other
    }

    /// What action follow-up resolution can naturally take when the user
    /// refers to this item.  The conversational layer treats these as hints.
    enum SuggestedAction: String, Codable, Equatable, Hashable {
        case open                // "open it" / "open that" / "show me"
        case reply               // "reply saying X"
        case call                // "call him back"
        case dismiss             // "dismiss it"
        case summarise           // "summarise that"
        case markDone            // "mark it done"
        case describeMore        // "tell me more" / "what colour is it"
    }

    /// Pronouns / referring words this item answers to.  Lower-cased.
    /// `it` / `that` / `this` are added implicitly — callers don't need to
    /// repeat them in `pronouns`.
    let pronouns: Set<String>

    let id: UUID
    let source: Source
    /// Short user-facing label ("Mike", "order #1042", "BBC story",
    /// "Invoice March.pdf").  Used in pronoun-disambiguation prompts.
    let title: String
    /// 1-2 sentence summary of the item.  Goes into the LLM context block.
    let summary: String
    /// Free-form entity tags ("Cath", "GBP", "UK politics") — used by the
    /// LLM to match a user reference like "Cath emailed you" against the
    /// stored email-thread item.
    let entities: [String]
    /// External identifier the caller can use to act on this item
    /// (`order_id`, `contact_id`, file URL, note ID, message thread ID, …).
    let externalIdentifier: String?
    /// Optional URL/path/contact reference for "open it" follow-up.
    let openableURL: String?
    let timestamp: Date
    /// Higher wins ties when the user's pronoun matches multiple items.
    /// `proactiveAlert` and `androidCall` are typically high, `news` low.
    let priority: Int
    let suggestedActions: [SuggestedAction]

    init(source: Source,
         title: String,
         summary: String = "",
         entities: [String] = [],
         externalIdentifier: String? = nil,
         openableURL: String? = nil,
         pronouns: [String] = [],
         priority: Int = 0,
         suggestedActions: [SuggestedAction] = [.describeMore]) {
        self.id = UUID()
        self.source = source
        self.title = title
        self.summary = summary
        self.entities = entities
        self.externalIdentifier = externalIdentifier
        self.openableURL = openableURL
        // Always answer the default pronouns; callers add gendered/contextual
        // pronouns ("him", "her", "they") via `pronouns`.
        var p = Set(pronouns.map { $0.lowercased() })
        p.formUnion(["it", "that", "this"])
        self.pronouns = p
        self.timestamp = Date()
        self.priority = priority
        self.suggestedActions = suggestedActions
    }

    /// True if this item *can* be the referent of `pronoun` (case-insensitive).
    func matches(pronoun: String) -> Bool {
        pronouns.contains(pronoun.lowercased())
    }
}

// MARK: - ActiveContextRegistry

/// Process-global, MainActor-isolated rolling log of recent context items
/// from every subsystem.  Bounded; oldest evicted on overflow.
///
/// **Reader:** the conversational layer (`JarvisController.handleTranscript`
/// + a new `ContextualReferenceResolver`) consults the registry whenever
/// the user's utterance doesn't map to a deterministic command.
///
/// **Writers:** every subsystem that produces user-visible context calls
/// `record(...)` after speaking / showing.  Existing subsystems are wired
/// up in this sprint; new subsystems just call `record` after their
/// user-visible action.
@MainActor
final class ActiveContextRegistry {

    static let shared = ActiveContextRegistry()

    /// Maximum entries kept.  Older items are dropped first.  Bounded so a
    /// long-running session doesn't bloat memory.
    let maxItems: Int

    /// Newest-first.  Exposed `let` so observers / Settings can read.
    private(set) var items: [ActiveContextItem] = []

    init(maxItems: Int = 50) {
        self.maxItems = maxItems
    }

    // MARK: - Mutation

    func record(_ item: ActiveContextItem) {
        items.insert(item, at: 0)
        if items.count > maxItems {
            items.removeLast(items.count - maxItems)
        }
        JarvisTelemetry.shared.record(
            JarvisEvent(.intentResolved, [
                "active_ctx_source": item.source.rawValue,
                "active_ctx_title":  String(item.title.prefix(40)),
            ])
        )
    }

    /// Convenience builder — most call sites just need source + title + summary.
    @discardableResult
    func record(source: ActiveContextItem.Source,
                title: String,
                summary: String = "",
                entities: [String] = [],
                externalIdentifier: String? = nil,
                openableURL: String? = nil,
                pronouns: [String] = [],
                priority: Int = 0,
                suggestedActions: [ActiveContextItem.SuggestedAction] = [.describeMore]
    ) -> ActiveContextItem {
        let item = ActiveContextItem(
            source: source, title: title, summary: summary, entities: entities,
            externalIdentifier: externalIdentifier, openableURL: openableURL,
            pronouns: pronouns, priority: priority,
            suggestedActions: suggestedActions)
        record(item)
        return item
    }

    /// Reset on emergency stop / explicit "forget that".  Telemetry kept.
    func clear() { items.removeAll() }

    // MARK: - Lookup

    /// Most recent item from `source`, or nil.
    func latest(from source: ActiveContextItem.Source) -> ActiveContextItem? {
        items.first(where: { $0.source == source })
    }

    /// Most recent item overall.  Used by "open it" / "summarise that"
    /// pronoun resolution when source isn't otherwise constrained.
    var mostRecent: ActiveContextItem? { items.first }

    /// Resolve a pronoun ("it", "him", "the second one") against the
    /// registry.  Returns the best-priority item that answers to that
    /// pronoun, plus any near-misses for disambiguation prompts.
    ///
    /// Time-decayed scoring: newer items get a tiny bonus so "it" right
    /// after a camera describe goes to the camera, not to a 5-minute-old
    /// Shopify list.
    func resolve(pronoun: String,
                 within: TimeInterval = 600,
                 ordinal: Int? = nil) -> ActiveContextItem? {
        let cutoff = Date().addingTimeInterval(-within)
        let candidates = items
            .filter { $0.timestamp >= cutoff }
            .filter { $0.matches(pronoun: pronoun) }
        guard !candidates.isEmpty else { return nil }

        // Ordinal access — "the second one", "open the third".  Items are
        // newest-first; ordinal indexes into that list.  If the caller
        // explicitly asked for ordinal N and N is out of range, return
        // nil rather than silently returning the top-scored candidate —
        // a missing "third one" must surface, not be paved over.
        if let ordinal {
            guard ordinal > 0, ordinal <= candidates.count else { return nil }
            return candidates[ordinal - 1]
        }

        // Score = priority + recency bonus (within 5 minutes adds 1.0).
        let scored = candidates.map { item -> (ActiveContextItem, Double) in
            let ageSec = Date().timeIntervalSince(item.timestamp)
            let recencyBonus = max(0.0, 1.0 - (ageSec / 300.0))
            return (item, Double(item.priority) + recencyBonus)
        }
        return scored.max(by: { $0.1 < $1.1 })?.0
    }

    /// Items emitted in the last `seconds` interval — used by the LLM
    /// context block so the model sees recent state across subsystems.
    func recent(within seconds: TimeInterval = 600) -> [ActiveContextItem] {
        let cutoff = Date().addingTimeInterval(-seconds)
        return items.filter { $0.timestamp >= cutoff }
    }

    // MARK: - LLM serialisation

    /// Render up to `maxItems` recent context items as a short text block
    /// the LLM can read.  Bounded to keep prompt budget in check.
    ///
    /// Output shape (one item per line):
    ///   `[source] title — summary (entities)`
    func contextBlock(maxItems: Int = 8,
                      window: TimeInterval = 600) -> String {
        let recent = recent(within: window).prefix(maxItems)
        guard !recent.isEmpty else { return "" }
        let lines = recent.map { item -> String in
            var line = "[\(item.source.rawValue)] \(item.title)"
            if !item.summary.isEmpty {
                line += " — \(item.summary.prefix(140))"
            }
            if !item.entities.isEmpty {
                line += " (" + item.entities.prefix(4).joined(separator: ", ") + ")"
            }
            return line
        }
        return "Active context (most recent first):\n" + lines.joined(separator: "\n")
    }
}
