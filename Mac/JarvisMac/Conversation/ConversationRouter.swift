import Foundation

// MARK: - ConversationRouter

/// Classifies a voice transcript into a `ConversationRoute` so the caller
/// can decide whether to invoke the command pipeline, answer from project
/// knowledge, update memory, or respond conversationally.
///
/// **Design goals**
/// - All classification is synchronous and O(n) string matching — no heap
///   allocations per call, no regex compilation on the hot path.
/// - The LLM path is opt-in and only called when fast-path confidence < 0.65.
/// - The classifier is *conservative*: when in doubt it returns `.command`
///   with low confidence so the existing phrase-matcher + IntentRouter can
///   have first crack.  The conversational layer only short-circuits when
///   `ConversationRouteResult.shouldShortCircuit` is true (confidence ≥ 0.70
///   AND route is not `.command`/`.ignore`/`.clarification`).
@MainActor
final class ConversationRouter {

    // MARK: - Signal tables (static — allocated once)

    /// Utterances starting with these strings are almost certainly commands.
    /// Checked first so a phrase like "turn on the lights, also remind me…"
    /// is never misrouted to `projectReflection`.
    private static let commandPrefixes: [String] = [
        "turn on", "turn off", "switch on", "switch off",
        "set the", "set my", "set a timer", "start timer",
        "play ", "pause ", "stop playing", "skip ", "mute ",
        "open ", "close ", "launch ", "quit ",
        "send ", "call ", "text ", "message cath", "whatsapp",
        "create ", "make a ", "add task", "add reminder",
        "remind me", "remind me to",
        "show me", "find me", "search for", "look up",
        "what's the weather", "what is the weather",
        "what time", "what's the time",
        "lock the", "unlock the", "dim the", "brighten the",
        "volume up", "volume down", "set volume", "next track", "previous track",
        "go to sleep", "sleep mode", "do not disturb",
        "take a screenshot", "screenshot",
        "check github", "show github", "open github",
        "check shopify", "show shopify",
    ]

    /// Phrases that signal the user wants Jarvis to persist something.
    /// Checked before command prefixes because "remember that we'll use SQLite"
    /// starts with a memory signal, not a command prefix.
    private static let memorySignals: [String] = [
        "remember that", "remember this", "remember i ",
        "save that", "save this", "log that", "log this",
        "log that as", "log this as", "mark that as done", "mark this as done",
        "don't save", "do not save", "stop logging", "start logging again",
        "forget that", "forget this", "delete that memory", "delete that",
        "what do you remember about", "show today's jarvis log",
        "add to roadmap", "save to roadmap", "add that to the roadmap",
    ]

    /// Phrases that indicate the user wants to query stored project knowledge.
    private static let knowledgeSignals: [String] = [
        "what did we decide", "what did we agree",
        "what did i build", "what have i built", "what have we built",
        "what did i say", "what was the plan", "what's the plan",
        "what was the decision", "what was decided",
        "tell me what", "do you know about",
        "what's in the roadmap", "what's on the roadmap",
        "what are the open issues", "what bugs", "what issues",
        "remind me about", "what did we talk about", "what have we discussed",
        "last time we talked about", "previously we decided",
        "what's missing from", "what's left to build",
        "what should i work on", "what should i build next", "what next",
        "how far are we", "how far along",
    ]

    /// Tool-trigger phrases paired with a hint label for VisionActionPipeline routing.
    /// Checked BEFORE the command prefix scan so "open camera and tell me X" is routed
    /// to the reasoning pipeline rather than silently opening the camera with no follow-up.
    private static let toolTriggers: [(phrase: String, hint: String)] = [
        ("open camera", "camera"),
        ("open the camera", "camera"),
        ("look at me", "camera"),
        ("look at this", "camera"),
        ("look at what", "camera"),
        ("turn on the camera", "camera"),
        ("turn on camera", "camera"),
        ("can you see if", "camera"),
        ("take a screenshot", "screenshot"),
        ("screenshot and", "screenshot"),
        ("check my screen", "screenshot"),
        ("look at my screen", "screenshot"),
        ("check diagnostics", "diagnostics"),
        ("run diagnostics", "diagnostics"),
        ("check my browser", "browser"),
        ("look at my browser", "browser"),
        ("inspect the page", "browser"),
    ]

    /// Connector phrases that signal a reasoning follow-up after the tool trigger.
    private static let reasoningConnectors: [String] = [
        " and tell me", " and explain", " and describe",
        " and say ", " and let me know", " and check if",
        " and see if", " and say whether", " and assess",
        " then tell me", " then explain", " then say",
        " and figure out", " and determine",
    ]

    /// Conjunctions that can separate a command from a conversational aside in
    /// a single utterance. Used to detect CHAT_PLUS_TOOL dual-track patterns.
    /// Checked against the whole transcript before the command prefix scan.
    private static let mixedConjunctions: [String] = [
        ", but ", ", though ", ", although ", ", however ",
        ", yeah ", " but yeah ", " and yeah ", " but also ",
        " although ", " even though ", " but i ", " though i ",
        " but the ", " but that ",
    ]

    /// Short follow-up phrases that continue a prior exchange rather than
    /// issuing a new command. Matched by exact equality only so that compound
    /// commands ("why not just turn off the lights") fall through to the normal
    /// command pipeline.
    private static let exactFollowUpSignals: Set<String> = [
        "why not",
        "why is that",
        "why was that",
        "how come",
        "what happened",
        "what went wrong",
        "what do you mean",
        "what do you mean by that",
        "explain that",
        "tell me more",
        "why though",
        "but why",
        "and why",
        "how so",
        "is that right",
        "are you sure",
        "why would that be",
        "what caused that",
    ]

    /// Phrases that signal the user is reflecting on project progress, asking
    /// for feedback on what they built, or discussing roadmap alignment.
    /// False-positive cost is low — misrouted utterances fall through to
    /// `generalChat` which is a safe catch-all.
    private static let projectSignals: [String] = [
        "i built", "i just built", "i finished", "i just finished",
        "i completed", "i just completed", "i implemented", "i just implemented",
        "i added", "i just added", "i fixed", "i just fixed",
        "i shipped", "i released", "i deployed",
        "been working on", "been building", "i've been",
        "today i", "this morning i", "this week i", "yesterday i",
        "what do you think", "what do you think about",
        "thoughts on", "does this fit", "does it fit",
        "fits the roadmap", "fits the plan",
        "is this the right", "does this make sense",
        "the architecture", "the design",
        "the sprint", "the feature", "this feature",
        "this module", "this system", "this component",
        "is this good", "is this right", "am i on track",
    ]

    // MARK: - Fast-path classification

    /// Synchronous O(n) rule-based classification.
    ///
    /// Returns a result with `fastPath = true`.  When `confidence` < 0.65
    /// the caller should optionally follow up with `classifyWithLLM(_:llmRouter:)`.
    ///
    /// - Parameters:
    ///   - normalized: Lowercased, whitespace-trimmed transcript.
    ///   - rawText: Original transcript (for diagnostics).
    func classifyFast(_ normalized: String, rawText: String = "") -> ConversationRouteResult {
        let t = normalized.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        guard t.count >= 3 else {
            return ConversationRouteResult(
                route: .ignore, confidence: 0.95,
                commandHint: nil,
                rationale: "transcript too short (\(t.count) chars)",
                fastPath: true
            )
        }

        // ── 1. Memory signals — highest priority ──────────────────────────
        // Checked first because a memory-update phrase like
        // "remember that we decided on SwiftUI" could also prefix-match a
        // command signal ("set") when read less carefully.
        for signal in Self.memorySignals {
            if t.hasPrefix(signal) || t.contains(signal) {
                return ConversationRouteResult(
                    route: .memoryUpdate, confidence: 0.92,
                    commandHint: nil,
                    rationale: "memory signal: '\(signal)'",
                    fastPath: true
                )
            }
        }

        // ── 1.5. Mixed chat + command detection ──────────────────────────
        // "Turn the lights on, but yeah the calibration might fix the drift"
        // → command portion gets executed silently (Track B) while the
        //   conversational aside gets a spoken reply (Track A).
        // Must run BEFORE the command-prefix check so the full utterance
        // is visible (the prefix check would swallow the conversational tail).
        if t.count > 25 {
            for conj in Self.mixedConjunctions {
                if let conjRange = t.range(of: conj) {
                    let cmdPart = String(t[..<conjRange.lowerBound])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let isCmd = Self.commandPrefixes.contains { cmdPart.hasPrefix($0) }
                    if isCmd {
                        let conjTrimmed = conj.trimmingCharacters(in: .whitespacesAndNewlines)
                        return ConversationRouteResult(
                            route: .mixedChatAndCommand, confidence: 0.85,
                            commandHint: cmdPart,
                            rationale: "mixed: cmd=\"\(cmdPart.prefix(30))\" conj=\"\(conjTrimmed)\"",
                            fastPath: true
                        )
                    }
                }
            }
        }

        // ── 1.7. Tool + conversational reasoning ─────────────────────────
        // "Open the camera and tell me if I'm soaking" → camera opens, frame
        // analyzed, Jarvis replies conversationally. Must run BEFORE the command
        // prefix scan (step 2) since "open camera" would otherwise be routed as
        // a silent command with no reasoning follow-up.
        for (trigger, hint) in Self.toolTriggers {
            if t.contains(trigger) {
                for connector in Self.reasoningConnectors {
                    if t.contains(connector) {
                        let connectorTrimmed = connector.trimmingCharacters(in: .whitespacesAndNewlines)
                        return ConversationRouteResult(
                            route: .chatPlusToolPlusReasoning, confidence: 0.88,
                            commandHint: hint,
                            rationale: "tool_reasoning trigger=\"\(trigger)\" connector=\"\(connectorTrimmed)\"",
                            fastPath: true
                        )
                    }
                }
            }
        }

        // ── 2. Explicit command prefixes ──────────────────────────────────
        for prefix in Self.commandPrefixes {
            if t.hasPrefix(prefix) {
                return ConversationRouteResult(
                    route: .command, confidence: 0.93,
                    commandHint: nil,
                    rationale: "command prefix: '\(prefix)'",
                    fastPath: true
                )
            }
        }

        // ── 3. Knowledge queries ──────────────────────────────────────────
        for signal in Self.knowledgeSignals {
            if t.contains(signal) {
                return ConversationRouteResult(
                    route: .knowledgeQuery, confidence: 0.82,
                    commandHint: nil,
                    rationale: "knowledge signal: '\(signal)'",
                    fastPath: true
                )
            }
        }

        // ── 4. Project reflection ─────────────────────────────────────────
        // Multiple matching signals raise confidence; a single match yields
        // a modest 0.68 which may still short-circuit (≥ 0.70 threshold).
        var projectScore = 0
        var projectMatched: [String] = []
        for signal in Self.projectSignals {
            if t.contains(signal) {
                projectScore += 1
                projectMatched.append(signal)
            }
        }
        if projectScore >= 1 {
            let conf = min(0.68 + Double(projectScore) * 0.07, 0.92)
            let matched = projectMatched.prefix(2).joined(separator: ", ")
            return ConversationRouteResult(
                route: .projectReflection, confidence: conf,
                commandHint: nil,
                rationale: "project signals: \(matched)",
                fastPath: true
            )
        }

        // ── 5. Short follow-up phrases ────────────────────────────────────
        // Exact match only — avoids misrouting commands that share a prefix
        // (e.g. "why not turn on the lights"). Routes to generalChat so the
        // LLM answers using recent chatMessages context rather than the intent
        // classifier JSON format.
        if Self.exactFollowUpSignals.contains(t) {
            return ConversationRouteResult(
                route: .generalChat, confidence: 0.78,
                commandHint: nil,
                rationale: "follow-up signal: '\(t)'",
                fastPath: true
            )
        }

        // ── 6. Default: let the existing command pipeline try ─────────────
        // Returning `.command` with low confidence means `shouldShortCircuit`
        // is false, so the phrase-matcher + IntentRouter run normally.
        // Only truly unmatched utterances ever reach the LLM fallback.
        return ConversationRouteResult(
            route: .command, confidence: 0.40,
            commandHint: nil,
            rationale: "no strong signals — deferring to command pipeline",
            fastPath: true
        )
    }

    // MARK: - LLM-assisted classification

    /// Calls the LLM with a tiny (5-token) completion to get a route label
    /// for transcripts where the fast path returned low confidence.
    ///
    /// Uses temperature 0.0 and a 5-second timeout so it is non-blocking
    /// in practice.  Falls back to `.generalChat` on any error.
    ///
    /// - Parameters:
    ///   - transcript: The original (un-normalised) transcript.
    ///   - llmRouter: The LLM router to use for the classification call.
    func classifyWithLLM(_ transcript: String, llmRouter: LLMRouter) async -> ConversationRoute {
        let prompt = """
        Classify this voice assistant utterance. Reply with ONLY one word.

        Categories: COMMAND, GENERAL_CHAT, PROJECT_REFLECTION, MEMORY_UPDATE, KNOWLEDGE_QUERY, MIXED

        Rules:
        - COMMAND: turn on/off something, play/pause, open app, send message, set timer, create task
        - GENERAL_CHAT: casual conversation, opinions, factual questions unrelated to project
        - PROJECT_REFLECTION: user discussing what they built, roadmap status, architecture, what to build next
        - MEMORY_UPDATE: save/remember/log/forget something
        - KNOWLEDGE_QUERY: ask what was decided/built/done previously
        - MIXED: contains both a command and conversation

        Utterance: "\(transcript.prefix(200))"

        Answer:
        """
        let req = LLMRequest(
            systemPrompt: "You classify voice assistant utterances. Reply with one word only.",
            userPrompt: prompt,
            contextSummary: nil,
            temperature: 0.0,
            maxTokens: 5,
            responseFormat: .text,
            timeoutSeconds: 5
        )
        guard let response = try? await llmRouter.complete(req) else {
            return .generalChat
        }
        let word = response.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        switch word {
        case "COMMAND":            return .command
        case "GENERAL_CHAT":       return .generalChat
        case "PROJECT_REFLECTION": return .projectReflection
        case "MEMORY_UPDATE":      return .memoryUpdate
        case "KNOWLEDGE_QUERY":    return .knowledgeQuery
        case "MIXED":              return .mixedChatAndCommand
        default:                   return .generalChat
        }
    }
}
