import Foundation

// MARK: - ConversationRoute

/// High-level classification of a voice transcript into a conversation category.
/// Used by `ConversationRouter` to decide whether to invoke the normal command
/// pipeline, answer from project knowledge, update memory, or just chat.
enum ConversationRoute: String, Codable, Sendable {
    /// Clear executable intent — hand off to the existing command pipeline.
    case command
    /// General casual conversation or factual Q&A unrelated to the project.
    case generalChat
    /// User discussing work they did, asking about roadmap / status / next steps.
    case projectReflection
    /// User asking to remember / save / log / forget something.
    case memoryUpdate
    /// User asking what was decided / built / done previously.
    case knowledgeQuery
    /// Transcript contains both a command portion and a conversational portion.
    case mixedChatAndCommand
    /// Transcript triggers a tool (camera, screenshot, diagnostics) AND contains a
    /// conversational query that requires reasoning over the tool's output.
    /// Route: tool executes → result injected into LLM → conversational reply.
    case chatPlusToolPlusReasoning
    /// Jarvis needs to ask the user a clarifying question before acting.
    case clarification
    /// Transcript is too short, empty, or clearly noise — do nothing.
    case ignore
}

// MARK: - ConversationRouteResult

/// Outcome of classifying one transcript through `ConversationRouter`.
struct ConversationRouteResult: Sendable {
    /// The best-matching route.
    let route: ConversationRoute
    /// Classifier confidence in [0.0, 1.0].
    let confidence: Double
    /// For `.mixedChatAndCommand`: the command portion of the utterance.
    let commandHint: String?
    /// Human-readable explanation for diagnostics and logging.
    let rationale: String
    /// `true` when the result came from rule-based fast classification;
    /// `false` when an LLM was consulted.
    let fastPath: Bool

    /// When `true` the conversational layer should respond directly and skip
    /// the normal command pipeline entirely.
    ///
    /// Conservative by design — only short-circuits when the route is
    /// unambiguously non-command AND confidence is high enough that we are
    /// sure we are not accidentally dropping a real command.
    var shouldShortCircuit: Bool {
        // Commands, clarifications, ignores, and mixed routes always let the
        // pipeline run (mixed is handled specially after intent resolution).
        // chatPlusToolPlusReasoning also short-circuits so JarvisController can
        // intercept it before the command pipeline and run the tool+reasoning flow.
        guard route != .command,
              route != .ignore,
              route != .clarification,
              route != .mixedChatAndCommand else { return false }
        return confidence >= 0.70
    }
}

// MARK: - MemoryCandidateType

/// The semantic category of a piece of information worth persisting.
enum MemoryCandidateType: String, Codable {
    /// A durable user preference ("I prefer short answers").
    case userPreference
    /// An architectural or implementation decision ("we'll use SQLite").
    case projectDecision
    /// Completed work the user reported ("I built the tracking layer").
    case projectProgress
    /// A change to the planned roadmap or sprint scope.
    case roadmapChange
    /// A reported bug or regression.
    case bugReport
    /// A future improvement idea ("we could add X").
    case idea
    /// A stable personal fact ("I'm based in London").
    case personalFact
    /// Short-lived context that is unlikely to matter tomorrow.
    case temporaryNote
    /// Random chat with no lasting value — should not be stored.
    case discard
}

// MARK: - MemoryTier

/// Persistence tier for a memory candidate.
/// Higher tiers survive longer and are surfaced more prominently in LLM context.
enum MemoryTier: String, Codable {
    /// Raw transcript fragment — high volume, short-lived.
    case rawTranscript
    /// End-of-day roll-up produced by `ConversationSummariser`.
    case dailySummary
    /// Durable project-scoped facts (decisions, progress, roadmap).
    case projectMemory
    /// Stable user preferences that span projects and sessions.
    case longTermUserPreference
    /// In-session scratch-pad; cleared on restart.
    case ephemeral
}

// MARK: - MemoryCandidate

/// A piece of information extracted from a conversation turn that is a
/// candidate for persistence in `MemoryStore` or `BrainMemoryStore`.
///
/// `MemoryExtractor` produces these; the caller decides whether to commit
/// them based on confidence, user confirmation, or auto-save policy.
/// `BrainMemoryStore.commit(_:)` is the authoritative durable destination.
struct MemoryCandidate: Identifiable, Codable {
    var id = UUID()
    /// Semantic classification of what kind of information this is.
    var type: MemoryCandidateType
    /// Suggested persistence tier.
    var tier: MemoryTier
    /// Short display title for the memory (max ~80 chars).
    var title: String
    /// 1–2 sentence summary suitable for LLM injection.
    var summary: String
    /// The original transcript fragment this was extracted from.
    var rawText: String
    /// Extractor confidence in [0.0, 1.0].
    var confidence: Double
    /// 0.0–1.0 importance weight. Higher values surface in retrieval sooner.
    var importance: Double = 0.5
    /// Freeform tags for retrieval (e.g. `["project", "progress"]`).
    var tags: [String]
    /// When the candidate was created (not necessarily when it will be saved).
    var createdAt: Date
    /// Last modification date (updated on edits in BrainMemoryStore).
    var updatedAt: Date = Date()
    /// Optional expiry. nil = never expires.
    var expiresAt: Date? = nil
    /// Where this memory originated.
    var source: BrainMemorySource = .memoryExtractor
    /// EntityGraph node IDs this memory is linked to.
    var linkedEntityIds: [String] = []
    /// The conversation session that generated this memory.
    var originalConversationId: String? = nil
    /// Controls LLM injection and search export visibility.
    var privacyLevel: BrainPrivacyLevel = .normal
    /// Pinned memories are excluded from pruning and never evicted automatically.
    var isPinned: Bool = false
}

// MARK: - RouteDiagnostics

/// Per-turn diagnostic record written after the full route-classify → respond
/// → extract cycle completes.  Consumed by `DebugHUDView` and the EventStore.
struct RouteDiagnostics {
    /// The raw transcript that was classified.
    var transcript: String
    /// The route that was chosen.
    var route: ConversationRoute
    /// Classifier confidence.
    var confidence: Double
    /// Why this route was chosen.
    var rationale: String
    /// Whether classification used the fast rule-based path.
    var fastPath: Bool
    /// Wall-clock time spent in classification, in milliseconds.
    var routeLatencyMs: Double
    /// Which knowledge sources contributed to the response context.
    var retrievalSources: [String]
    /// Types of memory candidates extracted from this turn.
    var memoryCandidates: [MemoryCandidateType]
    /// The intent label of the command that was executed, if any.
    var commandExecuted: String?
    /// Wall-clock time from route decision to spoken response, in milliseconds.
    var responseLatencyMs: Double?
}
