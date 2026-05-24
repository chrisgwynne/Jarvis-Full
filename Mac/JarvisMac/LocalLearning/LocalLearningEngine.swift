import Foundation

struct LearningEngineResult {
    let intent: String
    let target: String?
    let spokenResponse: String
    let confidence: Double
    let source: InteractionSource
    var shouldAskClarification: Bool { confidence < 0.55 }
}

struct LearningDiagnostics {
    var endpointReachable: Bool = false
    var lastLatencyMs: Double = 0
    var totalLocalLLMCalls: Int = 0
    var totalAliasHits: Int = 0
    var totalCorrectionHits: Int = 0
    var totalRouteHits: Int = 0
    var correctionCount: Int = 0
    var failedUtteranceCount: Int = 0
    var aliasCount: Int = 0
    var trainingExampleCount: Int = 0
}

@MainActor
final class LocalLearningEngine {

    // MARK: - Stores

    let interactionRecorder   = InteractionRecorder()
    let correctionStore       = UserCorrectionStore()
    let aliasStore            = LearnedCommandAliasStore()
    let failedStore           = FailedUtteranceStore()
    let successfulRouteStore  = SuccessfulRouteStore()
    let conversationMemory    = LocalConversationMemoryStore()
    let trainingExampleStore  = TrainingExampleStore()

    // MARK: - Dependencies (set by JarvisController)

    var routeFromString: ((String) -> (intent: String, target: String?)?)? = nil

    // MARK: - Diagnostics

    private(set) var diagnostics = LearningDiagnostics()

    // MARK: - Private

    private let llmClient = LocalLLMClient()
    private var config: LocalLLMConfig = .init()

    func configure(config: LocalLLMConfig) {
        self.config = config
    }

    // MARK: - Main routing entry point

    /// Called from LLMFallbackHandler before hitting cloud LLM.
    /// Returns a result if the local engine can handle it, nil otherwise.
    func handle(transcript: String) async -> LearningEngineResult? {
        let norm = transcript.lowercased().trimmingCharacters(in: .whitespaces)

        // 1. Exact phrase match from successful routes (hit count ≥ 2)
        if let route = successfulRouteStore.match(normalizedTranscript: norm) {
            diagnostics.totalRouteHits += 1
            return LearningEngineResult(
                intent: route.intent, target: route.target,
                spokenResponse: "", confidence: route.confidenceAvg,
                source: route.routingSource
            )
        }

        // 2. Learned alias match
        if let alias = aliasStore.match(normalizedTranscript: norm) {
            aliasStore.incrementUsage(id: alias.id)
            diagnostics.totalAliasHits += 1
            return LearningEngineResult(
                intent: alias.intent, target: alias.target,
                spokenResponse: "", confidence: 0.80 + alias.confidenceBoost,
                source: .learnedAlias
            )
        }

        // 3. Recent corrections
        for correction in correctionStore.recent(limit: 20) {
            guard let correctedPhrase = correction.correctedPhrase else { continue }
            let normPhrase = correctedPhrase.lowercased().trimmingCharacters(in: .whitespaces)
            if norm == normPhrase || norm.contains(normPhrase) {
                diagnostics.totalCorrectionHits += 1
                if let resolved = routeFromString?(correctedPhrase) {
                    correctionStore.markApplied(id: correction.id)
                    return LearningEngineResult(
                        intent: resolved.intent, target: resolved.target,
                        spokenResponse: "", confidence: 0.85,
                        source: .learnedAlias
                    )
                }
            }
        }

        // 4. Local LLM
        guard config.enabled else { return nil }
        return await queryLocalLLM(transcript: transcript, norm: norm)
    }

    // MARK: - Correction detection

    func detectAndRecordCorrection(transcript: String) -> Bool {
        let lastTranscript = conversationMemory.lastUserTranscript()
        guard let correction = CorrectionDetector.detect(transcript: transcript, lastTranscript: lastTranscript) else {
            return false
        }

        let record = UserCorrection(
            id: UUID(), timestamp: Date(),
            originalTranscript: correction.originalPhrase ?? lastTranscript ?? "",
            originalIntent: nil,
            correctedPhrase: correction.correctedIntentHint,
            correctedIntentHint: correction.correctedIntentHint,
            target: nil,
            applied: false,
            learnedAliasID: nil
        )
        correctionStore.record(record)
        diagnostics.correctionCount = correctionStore.corrections.count

        if let original = correction.originalPhrase, !original.isEmpty {
            aliasStore.add(
                phrase: original,
                intent: correction.correctedIntentHint,
                target: nil,
                source: .userCorrection,
                confidenceBoost: 0.20
            )
        }
        return true
    }

    // MARK: - Recording

    func recordInteraction(transcript: String, intent: String, target: String?,
                           source: InteractionSource, response: String, success: Bool) {
        let record = InteractionRecord(
            transcript: transcript, intent: intent, source: source,
            response: response, success: success
        )
        interactionRecorder.record(record)
        conversationMemory.addUserTurn(transcript: transcript, intent: intent, source: source)
        conversationMemory.addAssistantTurn(response: response, intent: intent)

        if success {
            successfulRouteStore.record(
                transcript: transcript, intent: intent, target: target,
                source: source, confidence: 0.90
            )
        } else {
            failedStore.record(transcript: transcript, detectedIntent: intent)
            diagnostics.failedUtteranceCount = failedStore.failures.count
        }

        let example = TrainingExample(
            id: UUID(), timestamp: Date(),
            transcript: transcript, correctedTranscript: nil,
            intent: intent, target: target, spokenResponse: response,
            routingSource: source,
            approvalState: success ? .pending : .rejected,
            source: .interaction
        )
        trainingExampleStore.add(example)
        diagnostics.trainingExampleCount = trainingExampleStore.examples.count
    }

    func recordCorrection(originalTranscript: String, correctedIntent: String,
                          correctedResponse: String, target: String?) {
        let example = TrainingExample(
            id: UUID(), timestamp: Date(),
            transcript: originalTranscript, correctedTranscript: nil,
            intent: correctedIntent, target: target, spokenResponse: correctedResponse,
            routingSource: .learnedAlias, approvalState: .approved,
            source: .userCorrection
        )
        trainingExampleStore.add(example)
        aliasStore.add(
            phrase: originalTranscript, intent: correctedIntent, target: target,
            source: .userCorrection, confidenceBoost: 0.20
        )
        diagnostics.aliasCount = aliasStore.aliases.count
    }

    // MARK: - Export

    func exportTrainingData() async {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("JarvisTrainingData")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let approved = trainingExampleStore.exportJSONL(approved: true, pending: false)
        let pending  = trainingExampleStore.exportJSONL(approved: false, pending: true)
        let rejected = trainingExampleStore.rejected().map(\.jsonlLine).joined(separator: "\n")
        let report   = buildExportReport()

        try? approved.write(to: dir.appendingPathComponent("approved_training_examples.jsonl"), atomically: true, encoding: .utf8)
        try? pending.write(to:  dir.appendingPathComponent("live_learned_examples.jsonl"),      atomically: true, encoding: .utf8)
        try? rejected.write(to: dir.appendingPathComponent("rejected_examples.jsonl"),          atomically: true, encoding: .utf8)
        try? report.write(to:   dir.appendingPathComponent("export_report.md"),                 atomically: true, encoding: .utf8)
    }

    // MARK: - LoRA stubs

    func exportForLoRATraining() {
        // Stub: export approved examples in LoRA-ready format
    }

    func setLoRAAdapterPath(_ path: String) {
        // Stub: load fine-tuned LoRA adapter
    }

    func setTunedModelEndpoint(_ url: String) {
        // Stub: switch to tuned model endpoint
    }

    // MARK: - Health check

    func checkEndpointHealth() async {
        guard config.enabled,
              let url = URL(string: config.baseURL + "/health") else {
            diagnostics.endpointReachable = false; return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        let reachable = (try? await URLSession.shared.data(for: req)) != nil
        diagnostics.endpointReachable = reachable
    }

    // MARK: - Private helpers

    private func queryLocalLLM(transcript: String, norm: String) async -> LearningEngineResult? {
        let context = conversationMemory.buildContextBlock(limit: 6)
        let start = Date()
        do {
            let result = try await llmClient.query(transcript: transcript, context: context, config: config)
            let latency = Date().timeIntervalSince(start) * 1000
            diagnostics.lastLatencyMs = latency
            diagnostics.totalLocalLLMCalls += 1
            diagnostics.endpointReachable = true
            return LearningEngineResult(
                intent: result.intent, target: result.target,
                spokenResponse: result.spokenResponse,
                confidence: result.confidence,
                source: .localLLM
            )
        } catch LocalLLMError.lowConfidence(let c) {
            diagnostics.totalLocalLLMCalls += 1
            failedStore.record(transcript: transcript, detectedIntent: nil)
            return LearningEngineResult(
                intent: "unknown", target: nil,
                spokenResponse: "I'm not sure I understood. Could you rephrase?",
                confidence: c, source: .localLLM
            )
        } catch {
            if case LocalLLMError.disabled = error { } else {
                diagnostics.endpointReachable = false
            }
            return nil
        }
    }

    private func buildExportReport() -> String {
        let now = ISO8601DateFormatter().string(from: Date())
        return """
        # Jarvis Training Data Export
        Date: \(now)

        ## Counts
        - Total examples: \(trainingExampleStore.examples.count)
        - Approved: \(trainingExampleStore.approved().count)
        - Pending: \(trainingExampleStore.pending().count)
        - Rejected: \(trainingExampleStore.rejected().count)

        ## Stores
        - Learned aliases: \(aliasStore.aliases.count)
        - User corrections: \(correctionStore.corrections.count)
        - Successful routes: \(successfulRouteStore.routes.count)
        - Failed utterances: \(failedStore.failures.count)

        ## Diagnostics
        - Total interactions: \(interactionRecorder.records.count)
        - Success rate: \(String(format: "%.1f%%", interactionRecorder.successRate * 100))
        - Local LLM calls: \(diagnostics.totalLocalLLMCalls)
        - Alias hits: \(diagnostics.totalAliasHits)
        - Route hits: \(diagnostics.totalRouteHits)
        """
    }
}
