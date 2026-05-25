import Foundation

/// Executes the LLM fallback flow when the deterministic phrase router cannot
/// classify a transcript.
///
/// Extracted from JarvisController.tryLLMFallback() — Sprint N decomposition.
/// All mutable controller state is accessed through injected closures so this
/// class has no direct reference to JarvisController.
@MainActor
final class LLMFallbackHandler {

    // MARK: - Injected services

    private let llmRouter: LLMRouter
    let circuitBreaker: LLMProviderCircuitBreaker
    private let state: AppState
    private let renderer: ResponseRenderer
    private let context: ContextEngine
    private let contextBuilder: PersonalityContextBuilder
    private let prefs: PreferencesStore
    private let search: SearchService?
    private let memories: MemoryStore?
    private let obsidianVault: ObsidianVaultService
    private let latency: LatencyTracker
    private let unmatched: UnmatchedCommandStore

    // MARK: - Controller state accessors (closures avoid circular refs)

    /// Returns the current pending conversation context from JarvisController.
    var getPendingContext: () -> PendingConversationContext? = { nil }

    // MARK: - Controller callbacks

    /// Called with the text to speak — routes through JarvisController.speak().
    var speak: (String) -> Void = { _ in }
    /// Executes the resolved intent through JarvisController.execute().
    var executeIntent: (Intent) async -> Void = { _ in }
    /// Sets a pending conversation context on JarvisController.
    var setPendingContext: (PendingConversationContext) -> Void = { _ in }
    /// Returns true if the transcript warrants an immediate acknowledgement.
    var shouldAcknowledgeQuery: (String) -> Bool = { _ in false }

    // MARK: - Learning engine (injected)

    var learningEngine: LocalLearningEngine? = nil

    /// Called when local learning resolves an intent; converts a string to Intent.
    /// Injected by JarvisController — matches IntentRouter.route(_:) signature.
    var routeFromString: ((String) -> Intent?)? = nil

    // MARK: - Own state

    /// One-shot context block injected by VisionActionPipeline / ToolExecutionGraph
    /// before a post-tool reasoning call. Consumed and cleared on the next `handle()`.
    var temporaryAdditionalContext: String? = nil

    private var ackIndex = -1
    private let acknowledgements = ["Let me check.", "One moment.", "On it.",
                                    "Looking into that.", "Working on it."]

    // MARK: - Init

    init(
        llmRouter: LLMRouter,
        circuitBreaker: LLMProviderCircuitBreaker,
        state: AppState,
        renderer: ResponseRenderer,
        context: ContextEngine,
        contextBuilder: PersonalityContextBuilder,
        prefs: PreferencesStore,
        search: SearchService?,
        memories: MemoryStore?,
        obsidianVault: ObsidianVaultService,
        latency: LatencyTracker,
        unmatched: UnmatchedCommandStore
    ) {
        self.llmRouter = llmRouter
        self.circuitBreaker = circuitBreaker
        self.state = state
        self.renderer = renderer
        self.context = context
        self.contextBuilder = contextBuilder
        self.prefs = prefs
        self.search = search
        self.memories = memories
        self.obsidianVault = obsidianVault
        self.latency = latency
        self.unmatched = unmatched
    }

    // MARK: - Handle

    /// Ask the LLM to interpret a transcript the deterministic router couldn't
    /// classify. Returns true if the command was handled (intent executed or
    /// clarification spoken), false if nothing could be done.
    @discardableResult
    func handle(rawText: String, normalized: String) async -> Bool {
        guard llmRouter.mode != .disabled else { return false }

        // Local learning engine pre-check (before cloud LLM)
        if let engine = learningEngine {
            if let result = await engine.handle(transcript: rawText) {
                if result.shouldAskClarification {
                    speak(result.spokenResponse)
                    return true
                }
                if let intent = routeFromString?(result.intent) {
                    if !result.spokenResponse.isEmpty { speak(result.spokenResponse) }
                    await executeIntent(intent)
                    return true
                }
                // intent string not resolvable — fall through to cloud LLM
            }
        }

        if circuitBreaker.allCircuitsOpen {
            state.log("llm", .warn, "llm_skipped all_circuits_open")
            speak(renderer.render(ResponseKey.llmUnavailableFallback))
            return false
        }

        let llmDecision = LLMDecision.required(reason: "unmatched_intent")
        state.log("llm", .info,
            "llm_decision=\(llmDecision.label) reason=\(llmDecision.reasonString)")

        if shouldAcknowledgeQuery(normalized) {
            ackIndex = (ackIndex + 1) % acknowledgements.count
            speak(acknowledgements[ackIndex])
        }

        // Context assembly
        let rawCtx = context.snapshot.summaryString()
        var ctx = PromptBudgeter.trimContext(rawCtx)

        let recentTurns = state.chatMessages.suffix(4)
        if !recentTurns.isEmpty {
            let historyLines = recentTurns.map { turn -> String in
                let roleLabel = turn.role == .user ? "User" : "Jarvis"
                return "\(roleLabel): \(turn.text)"
            }
            let historyBlock = "Recent conversation:\n" + historyLines.joined(separator: "\n")
            ctx = ctx.isEmpty ? historyBlock : ctx + "\n\n" + historyBlock
        }
        if let pending = getPendingContext() {
            ctx += "\n\nJarvis asked: \"\(pending.assistantQuestion)\" — awaiting reply."
        }

        let personalityPrompt = contextBuilder.buildSystemPrompt(
            userName:      context.snapshot.userName.isEmpty ? nil : context.snapshot.userName,
            assistantName: context.snapshot.assistantName
        )
        let composedSystemPrompt = personalityPrompt.isEmpty
            ? LLMPrompts.intentClassifierSystem
            : personalityPrompt + "\n\n---\n\n" + LLMPrompts.intentClassifierSystem

        // Memory injection
        if let svc = search {
            let memResults = await svc.hybridSearch(query: rawText, limit: 3)
            let memTexts = memResults.filter { $0.kind == .memory }.map { $0.text }
            if !memTexts.isEmpty {
                let memBlock = "Relevant memories:\n" + memTexts.map { "- \($0)" }.joined(separator: "\n")
                ctx = ctx.isEmpty ? memBlock : ctx + "\n\n" + memBlock
            }
        } else if let mem = memories {
            let memRows = await mem.search(query: rawText, limit: 3)
            if !memRows.isEmpty {
                let memBlock = "Relevant memories:\n" + memRows.map { "- \($0.text)" }.joined(separator: "\n")
                ctx = ctx.isEmpty ? memBlock : ctx + "\n\n" + memBlock
            }
        }

        // Obsidian vault RAG
        if prefs.current.obsidianLLMContextEnabled,
           let vaultCtx = await obsidianVault.contextForLLM(
               query: rawText,
               maxNotes: prefs.current.obsidianMaxContextNotes,
               maxCharsPerNote: 600
           ) {
            ctx = ctx.isEmpty ? vaultCtx : ctx + "\n\n" + vaultCtx
        }

        // Brain long-term memory context
        let brainCtx = await BrainMemoryStore.shared.contextForLLM(query: rawText, maxItems: 5)
        if !brainCtx.isEmpty {
            ctx = ctx.isEmpty ? brainCtx : ctx + "\n\n" + brainCtx
        }

        // Codebase self-knowledge context (for queries about Jarvis itself)
        if prefs.current.selfKnowledgeEnabled {
            let selfSvc = JarvisSelfQueryService.shared
            if selfSvc.isAboutSelf(normalized) {
                if let result = await selfSvc.query(userQuery: rawText,
                                                    activeTopic: RollingDialogueMemory.shared.activeTopic) {
                    let block = selfSvc.contextBlock(for: result)
                    if !block.isEmpty {
                        ctx = ctx.isEmpty ? block : ctx + "\n\n" + block
                    }
                }
            }
        }

        // Rolling dialogue context (recent turns for pronoun resolution)
        let dialogueBlock = RollingDialogueMemory.shared.buildContextBlock(limit: 6)
        if !dialogueBlock.isEmpty {
            ctx = ctx.isEmpty ? dialogueBlock : ctx + "\n\n" + dialogueBlock
        }

        // Vision context (fresh < 60s)
        let visionCtx = state.lastVisionContext
        if visionCtx.isFresh && !visionCtx.summary.isEmpty {
            let vBlock = visionCtx.toLLMContextString()
            ctx = ctx.isEmpty ? vBlock : ctx + "\n\n" + vBlock
        }

        // Post-tool reasoning context (one-shot, consumed here)
        if let toolCtx = temporaryAdditionalContext {
            temporaryAdditionalContext = nil
            ctx = ctx.isEmpty ? toolCtx : ctx + "\n\n" + toolCtx
        }

        let diag = PromptBudgeter.diagnose(
            system: composedSystemPrompt, user: rawText,
            context: ctx.isEmpty ? nil : ctx
        )
        if diag.isOverBudget {
            state.log("llm", .warn,
                "prompt_over_budget tokens≈\(diag.estimatedTokens) ctx=\(diag.contextChars)chars")
        }

        latency.mark(.llmStart)
        SpeechTurnStore.shared.update { $0.llmUsed = true; $0.route = .llmFallback }
        let req = LLMRequest(
            systemPrompt: composedSystemPrompt,
            userPrompt:   rawText,
            contextSummary: ctx.isEmpty ? nil : ctx,
            temperature:  0.2,
            maxTokens:    350,
            responseFormat: .json,
            timeoutSeconds: 8
        )

        let response: LLMResponse
        do {
            response = try await llmRouter.complete(req, circuitBreaker: circuitBreaker)
            latency.mark(.llmComplete)
            latency.measure(from: .llmStart, to: .llmComplete, recordAs: .llmComplete)
        } catch {
            latency.mark(.llmComplete)
            state.llmLastError = error.localizedDescription
            state.log("llm", .warn, "llm_fallback_failed: \(error.localizedDescription)")
            if case LLMError.timeout = error {
                speak(renderer.render(ResponseKey.llmTimeoutFallback))
            } else if case LLMError.notConfigured = error, error.localizedDescription.contains("circuit") {
                speak(renderer.render(ResponseKey.llmUnavailableFallback))
            } else {
                speak(renderer.render(ResponseKey.llmUnavailableFallback))
            }
            return false
        }

        state.llmProviderUsed  = response.providerID
        state.llmModelUsed     = response.model
        state.llmLatencyMs     = response.latencyMs
        state.llmLastError     = nil
        state.llmFallbackUsed  = true
        state.llmParsedJSON    = String(response.text.prefix(200))

        guard let json = LLMIntentBridge.parse(response.text) else {
            state.llmValidationResult = "parse_failed"
            state.log("llm", .warn, "llm_parse_failed text=\"\(response.text.prefix(80))\"")
            speak(renderer.render(ResponseKey.llmMalformedFallback))
            return false
        }

        let speakText = json.speak ?? ""

        // Inner helper: if the JSON requests a follow-up, create pending context
        // BEFORE speaking so rewireSpeakingObserver enters .awaitingResponse.
        func applyPendingContextIfNeeded(originalText: String) {
            guard json.awaitResponse == true else { return }
            guard let question = json.speak, !question.isEmpty else { return }
            let responseType: PendingResponseType
            switch (json.pendingResponseType ?? "").lowercased() {
            case "yesno":         responseType = .yesNo
            case "clarification": responseType = .clarification
            default:              responseType = .freeform
            }
            let onYes: PendingOutcome? = {
                if let y = json.pendingOnYes, !y.isEmpty { return .speak(y) }
                return .callLLMWithHistory
            }()
            let onNo: PendingOutcome? = {
                if let n = json.pendingOnNo, !n.isEmpty { return .speak(n) }
                return .speak(renderer.render(ResponseKey.llmNoProblem))
            }()
            let pendingCtx = PendingConversationContext.make(
                originalTranscript: originalText,
                assistantQuestion: question,
                responseType: responseType,
                onYes: onYes,
                onNo: onNo,
                onFreeform: .callLLMWithHistory
            )
            setPendingContext(pendingCtx)
        }

        switch LLMIntentBridge.intent(from: json) {

        case .success(let intent):
            let label = String(describing: intent).components(separatedBy: "(").first ?? ""
            state.llmValidationResult = "ok:\(label)"
            state.log("llm", .info,
                "llm_routed via=\(response.providerID) intent=\(label) latency=\(response.latencyMs)ms speak=\"\(speakText.prefix(40))\" awaitResponse=\(json.awaitResponse ?? false)")
            let resolutionLabel = speakText.isEmpty ? label : String(speakText.prefix(80))
            unmatched.updateLLMResolution(resolutionLabel, forNormalizedText: normalized)
            applyPendingContextIfNeeded(originalText: rawText)
            if !speakText.isEmpty { speak(speakText) }
            await executeIntent(intent)
            return true

        case .failure(let err):
            switch err {
            case .lowConfidence(let j):
                let question = j.speak ?? "I didn't quite catch that. Could you try again?"
                state.llmValidationResult =
                    "low_confidence(\(String(format: "%.2f", j.confidence ?? 0)))"
                applyPendingContextIfNeeded(originalText: rawText)
                if getPendingContext() == nil {
                    let inferredCtx = PendingConversationContext.clarification(
                        originalTranscript: rawText,
                        question: question
                    )
                    setPendingContext(inferredCtx)
                }
                speak(question)
                return true

            case .blockedAction(let name):
                state.llmValidationResult = "blocked:\(name)"
                state.log("llm", .warn, "blocked_llm_action: \(name)")
                speak(renderer.render(ResponseKey.llmBlocked))
                return true

            case .unmapped(let j):
                state.llmValidationResult = "unmapped:\(j.intent)"
                if !speakText.isEmpty {
                    applyPendingContextIfNeeded(originalText: rawText)
                    speak(speakText)
                    return true
                }
                speak(renderer.render(ResponseKey.llmUnknownFallback))
                return false

            case .parseFailed(let s):
                state.llmValidationResult = "parse_failed:\(s)"
                speak(renderer.render(ResponseKey.llmMalformedFallback))
                return false
            }
        }
    }
}
