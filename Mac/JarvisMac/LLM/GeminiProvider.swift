import Foundation
import CoreGraphics
import ImageIO

// MARK: - GeminiProviderError

/// Typed, actionable failures for the Gemini parser.  Distinct from
/// `LLMError` so the parser can be unit-tested without inventing strings
/// and so the diagnostic message tells the user *which* of Gemini's
/// many non-error-but-no-text outcomes occurred:
///
///   * `MAX_TOKENS`     — token budget exhausted before any text emitted
///   * `SAFETY`         — output blocked by Gemini's safety filters
///   * `RECITATION`     — output blocked because it matched training data
///   * empty `parts`    — content present but no `text` parts (e.g. only
///                        a `functionCall` part)
///   * missing `content`— candidate exists but model produced no content
///   * empty candidates — `candidates: []` (rare; usually safety)
///   * promptBlocked    — input itself was blocked by safety filters
///
/// `userMessage` is short enough for the Settings → Test Connection result
/// row; `errorDescription` is what we propagate via `LLMError`.
enum GeminiProviderError: Error, Equatable {
    case promptBlocked(reason: String, safety: [String])
    case noCandidates
    case noContentInCandidate(finishReason: String?)
    case noPartsInContent(finishReason: String?)
    case partsHadNoText(finishReason: String?)
    case safetyBlocked(finishReason: String, safety: [String])
    case maxTokensNoText
    case malformedJSON(String)

    var userMessage: String {
        func frSuffix(_ fr: String?) -> String {
            guard let fr else { return "" }
            return " (finishReason: \(fr))"
        }
        switch self {
        case .promptBlocked(let reason, _):
            return "Gemini blocked your prompt (reason: \(reason)). Try rephrasing."
        case .noCandidates:
            return "Gemini returned no candidates. Most often this means the prompt was blocked — check safety settings or rephrase."
        case .noContentInCandidate(let fr):
            return "Gemini produced a candidate but no content" + frSuffix(fr) + "."
        case .noPartsInContent(let fr):
            return "Gemini produced content but no parts" + frSuffix(fr)
                + ". The model may have emitted only a function call or non-text content."
        case .partsHadNoText(let fr):
            return "Gemini produced parts but none were text" + frSuffix(fr)
                + ". Increase maxOutputTokens or change the prompt."
        case .safetyBlocked(let fr, _):
            return "Gemini blocked the response on safety grounds (\(fr))."
        case .maxTokensNoText:
            return "Gemini hit the max output tokens limit before generating any text. With 2.5-class \"thinking\" models, internal reasoning tokens count toward this budget — try a larger maxOutputTokens (the test button now uses 256 with thinking disabled), or switch to gemini-1.5-flash for the test."
        case .malformedJSON(let s):
            return "Gemini response was malformed: \(s)"
        }
    }

    /// Convert to an `LLMError` for surfacing through the existing
    /// provider plumbing.  Distinguishes `MAX_TOKENS` (transient/budget,
    /// caller may retry with a bigger budget) from `SAFETY` (won't
    /// resolve on retry) so the circuit breaker doesn't mark the provider
    /// degraded for what's really a prompt-shape problem.
    var asLLMError: LLMError {
        // ALL variants surface via `.decode(userMessage)` so the
        // actionable text we wrote ("Gemini hit the max output tokens
        // limit before generating any text. Increase maxOutputTokens…")
        // reaches the user — instead of being squashed into the
        // unhelpful generic "Empty response" string that `.empty`
        // produces via `LLMError.errorDescription`.
        //
        // Both `.decode` and `.empty` are in `OpenAIChatClient.shouldRetry`'s
        // no-retry set, so this doesn't change retry/circuit semantics.
        return .decode(userMessage)
    }
}

// MARK: - GeminiModelStatus

/// Tracks the last-known health of the configured Gemini model so the
/// caller can surface meaningful diagnostics without an extra round-trip.
enum GeminiModelStatus {
    /// The model responded successfully on the last call.
    case available
    /// The model returned HTTP 404 — it doesn't exist at this endpoint.
    case missing
    /// The model exists but doesn't support generateContent (rare).
    case unsupported
    /// The provider is disabled in Settings or the API key is absent.
    case disabled
    /// The API key is present but authentication failed (401/403).
    case authFailed
}

// MARK: - GeminiProvider (text + JSON via LLMProvider protocol)

/// Google Gemini text/JSON provider.
///
/// Uses the Generative Language REST API directly — the shape is not
/// OpenAI-compatible, so we don't reuse `OpenAIChatClient`.
///
/// Endpoint pattern:
///   POST  {baseURL}/models/{model}:generateContent?key={apiKey}
///
/// `{baseURL}` defaults to `https://generativelanguage.googleapis.com/v1beta`
/// and is user-overridable in Settings (lets enterprise users point at a
/// reverse proxy).  Model names are free-form strings stored in
/// Preferences — `gemini-1.5-flash`, `gemini-1.5-pro`, `gemini-2.0-flash`,
/// and any future identifier all work without an app update.
///
/// **API-key handling:** the key is read from a closure at call time, the
/// closure pulls it from the macOS Keychain.  The key is included in the
/// URL query (Google's documented auth method) but is never logged, never
/// written to AppState, and never persisted to preferences.json.
///
/// **404 model fallback:** when `generateContent` returns HTTP 404 (model
/// retired or renamed), the provider calls `discoverModels()` to list all
/// available models, picks the best one from `knownFallbackModels`, and
/// retries the original request once.  This makes the app self-healing
/// across Gemini model deprecations without requiring a user action.
final class GeminiProvider: LLMProvider {

    // MARK: - Known fallback models (priority order)

    /// Tried in order when the configured model returns HTTP 404.
    /// The list is intentionally short — we want a stable, widely-available
    /// model, not the newest experimental one.
    static let knownFallbackModels: [String] = [
        "gemini-2.0-flash",
        "gemini-2.0-flash-lite",
        "gemini-1.5-pro",
        "gemini-1.5-flash-002",
        "gemini-2.5-flash-preview-05-20",
    ]

    let id   = "gemini"
    let name = "Gemini"

    private let baseURL:    () -> String
    private let modelName:  () -> String
    private let visionModel: () -> String
    private let enabled:    () -> Bool
    private let apiKey:     () -> String?

    // MARK: - Model status diagnostics

    /// The model name read from Preferences at the last call site.
    private(set) var configuredModel: String = ""
    /// The model actually used on the last successful request — may differ
    /// from `configuredModel` when the fallback resolver selected a
    /// substitute after a 404.
    private(set) var resolvedModel: String?
    /// Health of the Gemini model as of the last request attempt.
    private(set) var modelStatus: GeminiModelStatus = .disabled
    /// When `discoverModels()` last ran (nil = never called).
    private(set) var lastListModelsAt: Date?
    /// Short human-readable reason for the last non-success status.
    private(set) var lastFailureReason: String?

    /// Shared session — same connection-pool / timeout shape as
    /// `OpenAIChatClient` so behaviour is consistent across providers.
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.httpMaximumConnectionsPerHost = 4
        cfg.timeoutIntervalForRequest = 25
        cfg.timeoutIntervalForResource = 60
        return URLSession(configuration: cfg)
    }()

    /// Total attempts including the first try — matches `OpenAIChatClient`.
    private static let maxAttempts = 3
    private static let baseBackoffMs = 250

    init(baseURL:     @escaping () -> String,
         modelName:   @escaping () -> String,
         visionModel: @escaping () -> String,
         enabled:     @escaping () -> Bool,
         apiKey:      @escaping () -> String?) {
        self.baseURL     = baseURL
        self.modelName   = modelName
        self.visionModel = visionModel
        self.enabled     = enabled
        self.apiKey      = apiKey
    }

    // MARK: - Availability

    func isAvailable() async -> Bool {
        // Config-only check — no Keychain read. Key presence is verified lazily
        // inside complete() so Keychain is only touched when a request actually fires.
        guard enabled() else { return false }
        return !modelName().trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Completion (text + JSON)

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        guard enabled() else {
            modelStatus = .disabled
            throw LLMError.providerDisabled("Gemini disabled in Settings")
        }
        guard let key = apiKey(), !key.isEmpty else {
            modelStatus = .disabled
            throw LLMError.notConfigured("Gemini API key missing")
        }

        // Pick text vs vision model based on whether image data is attached.
        // Most modern Gemini models are multimodal so the two often match.
        var model = (request.visionImageData == nil ? modelName() : visionModel())
            .trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else {
            throw LLMError.notConfigured("Gemini model name is empty")
        }
        configuredModel = model
        let url = try buildEndpointURL(model: model, apiKey: key)

        // Diagnostic log — redacted URL (key=***) so triage has the full
        // endpoint shape without ever leaking the API key.
        let safeURL = Self.redact(url: url)
        Log.llm.info("""
            Gemini request \
            url=\(safeURL, privacy: .public) \
            model=\(model, privacy: .public) \
            keyLen=\(key.count, privacy: .public) \
            vision=\(request.visionImageData != nil, privacy: .public) \
            maxTokens=\(request.maxTokens, privacy: .public) \
            temperature=\(request.temperature, privacy: .public)
            """)

        let body = try buildRequestBody(request: request)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = request.timeoutSeconds
        req.httpBody = body

        let start = Date()
        do {
            let (text, raw) = try await sendWithRetry(req: req)
            let ms = Int(-start.timeIntervalSinceNow * 1000)
            Log.llm.info("Gemini OK — \(ms, privacy: .public)ms model=\(model, privacy: .public)")
            modelStatus = .available
            resolvedModel = model
            return LLMResponse(text: text, model: model,
                               providerID: id, latencyMs: ms, rawJSON: raw)
        } catch let err as LLMError {
            // Handle 404 (model retired/renamed) with one auto-recovery attempt.
            if case .http(let code, _) = err, code == 404 {
                modelStatus = .missing
                lastFailureReason = "HTTP 404: model \(model) not found"
                Log.llm.warning("gemini_model_404 model=\(model, privacy: .public) — attempting model discovery")
                if let fallback = await resolveWorkingModel(apiKey: key) {
                    Log.llm.info("gemini_model_resolved fallback=\(fallback, privacy: .public)")
                    model = fallback
                    let retryURL = try buildEndpointURL(model: fallback, apiKey: key)
                    req.url = retryURL
                    let (text2, raw2) = try await sendWithRetry(req: req)
                    let ms2 = Int(-start.timeIntervalSinceNow * 1000)
                    modelStatus = .available
                    resolvedModel = fallback
                    return LLMResponse(text: text2, model: fallback,
                                       providerID: id, latencyMs: ms2, rawJSON: raw2)
                } else {
                    lastFailureReason = "No working Gemini model found via ListModels"
                    Log.llm.error("gemini_no_fallback_model — all candidates exhausted")
                    throw err
                }
            } else if case .http(let code, _) = err, code == 401 || code == 403 {
                modelStatus = .authFailed
                lastFailureReason = "HTTP \(code): authentication failed"
                throw err
            }
            throw err
        }
    }

    // MARK: - Model discovery + fallback resolution

    /// Calls the ListModels endpoint and returns model names that support
    /// `generateContent`. Used for 404 recovery.
    ///
    /// - Returns: Array of model name strings (without `"models/"` prefix),
    ///   or empty on network/auth failure.
    func discoverModels() async -> [String] {
        guard let key = apiKey(), !key.isEmpty else { return [] }
        var base = baseURL().trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        let keySlug = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
        guard let listURL = URL(string: "\(base)/models?key=\(keySlug)") else { return [] }
        do {
            let (data, response) = try await Self.session.data(from: listURL)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return []
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else { return [] }
            return models.compactMap { model -> String? in
                guard let fullName = model["name"] as? String else { return nil }
                let methods = model["supportedGenerationMethods"] as? [String] ?? []
                guard methods.contains("generateContent") else { return nil }
                // Strip the "models/" prefix to match how the user stores model names.
                return fullName.hasPrefix("models/") ? String(fullName.dropFirst(7)) : fullName
            }
        } catch {
            Log.llm.warning("gemini_list_models_failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Runs ListModels and returns the first available model from the
    /// fallback priority list, or nil if none are available.
    private func resolveWorkingModel(apiKey key: String) async -> String? {
        let discovered = await discoverModels()
        lastListModelsAt = Date()
        // Try the configured model first in case ListModels reveals it is available
        // (it might have been a transient 404).
        if discovered.contains(configuredModel) {
            return configuredModel
        }
        // Walk the known fallback list in priority order.
        for candidate in Self.knownFallbackModels {
            if discovered.contains(candidate) {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Test connection (used by Settings)

    /// Sends a minimal "Reply with exactly: OK" prompt and returns either
    /// the response text or a human-readable error.
    ///
    /// **Why 256 tokens + disableThinking:** Gemini 2.5-class models
    /// ("flash" / "pro") have an internal *thinking* phase whose tokens
    /// count against `maxOutputTokens`.  At 32 tokens the model exhausts
    /// the budget mid-thinking and emits **no visible text** — the
    /// candidate's `parts` array is empty with `finishReason: MAX_TOKENS`.
    /// That was the cause of the user-reported "Empty response" failure.
    ///
    /// Fix: bump the budget to 256 AND set `thinkingConfig.thinkingBudget = 0`
    /// so 2.5 models skip the thinking phase entirely for this trivial probe.
    /// Older Gemini 1.5 models ignore the `thinkingConfig` field.
    ///
    /// `temperature: 0` removes sampling randomness so the connection
    /// test is deterministic.
    ///
    /// Returns (message, isError).
    func testConnection() async -> (String, Bool) {
        do {
            let result = try await complete(LLMRequest(
                systemPrompt:    "",                    // no system instruction
                userPrompt:      "Reply with exactly: OK",
                temperature:     0.0,
                maxTokens:       256,
                timeoutSeconds:  12,
                disableThinking: true))
            return ("✓ Gemini reached. Response: \(result.text)", false)
        } catch let e as LLMError {
            return ("⚠ Gemini test failed: \(e.errorDescription ?? "unknown")", true)
        } catch {
            return ("⚠ Gemini test failed: \(error.localizedDescription)", true)
        }
    }

    // MARK: - URL + body construction

    /// `{base}/models/{model}:generateContent?key={apiKey}`.
    /// The API key is in the query string (Google's documented mechanism)
    /// and never logged.
    func buildEndpointURL(model: String, apiKey: String) throws -> URL {
        var base = baseURL().trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else {
            throw LLMError.notConfigured("Gemini base URL is empty")
        }
        // Escape model so e.g. slashes never break the path.
        let modelSlug = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        let keySlug   = apiKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? apiKey
        let s = "\(base)/models/\(modelSlug):generateContent?key=\(keySlug)"
        guard let url = URL(string: s) else {
            throw LLMError.notConfigured("Invalid Gemini URL constructed")
        }
        return url
    }

    /// Build the Gemini request body.  Maps `LLMRequest` to Gemini's
    /// `{ contents, systemInstruction, generationConfig }` schema.
    private func buildRequestBody(request: LLMRequest) throws -> Data {
        // User parts — text plus optional inline image.
        var userParts: [[String: Any]] = [
            ["text": userPromptWithContext(request)]
        ]
        if let jpeg = request.visionImageData {
            userParts.append([
                "inline_data": [
                    "mime_type": "image/jpeg",
                    "data": jpeg.base64EncodedString(),
                ]
            ])
        }

        var generationConfig: [String: Any] = [
            "temperature":     request.temperature,
            "maxOutputTokens": request.maxTokens,
        ]
        // Disable Gemini 2.5+ thinking when the caller asked for a fast,
        // tight response (test-connection, brief acknowledgement, etc.).
        // The `thinkingConfig.thinkingBudget = 0` field is documented for
        // Gemini 2.5+ models; older models silently ignore it because
        // `generationConfig` is a per-model open dictionary on Google's
        // REST endpoint.  Safe to send unconditionally — never causes a
        // 400 on the models we support.
        if request.disableThinking {
            generationConfig["thinkingConfig"] = ["thinkingBudget": 0]
        }
        if request.responseFormat == .json {
            generationConfig["responseMimeType"] = "application/json"
        }

        var body: [String: Any] = [
            "contents": [
                ["role": "user", "parts": userParts]
            ],
            "generationConfig": generationConfig,
        ]

        // System prompt — Gemini calls this `systemInstruction`.
        if !request.systemPrompt.isEmpty {
            body["systemInstruction"] = [
                "parts": [["text": request.systemPrompt]]
            ]
        }

        return try JSONSerialization.data(withJSONObject: body)
    }

    /// Combine an optional `contextSummary` into the user-prompt text.
    /// Gemini's `contents` array doesn't have a dedicated context-system
    /// slot like OpenAI does, so we prefix the user prompt instead.
    private func userPromptWithContext(_ request: LLMRequest) -> String {
        guard let ctx = request.contextSummary, !ctx.isEmpty else {
            return request.userPrompt
        }
        return "Context:\n\(ctx)\n\n\(request.userPrompt)"
    }

    // MARK: - Send + parse + retry

    /// One send/parse cycle.  Throws an `LLMError` typed for the retry layer.
    private func performOnce(_ req: URLRequest) async throws -> (String, [String: Any]) {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await Self.session.data(for: req)
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw LLMError.timeout
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw LLMError.cancelled
        } catch {
            throw LLMError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.network("Non-HTTP response")
        }
        if http.statusCode == 429 { throw LLMError.rateLimited }
        guard (200..<300).contains(http.statusCode) else {
            // Body might contain prompts in the error JSON — Gemini echoes
            // the request fields on error.  Truncate aggressively before
            // surfacing so logs don't include user content.
            let body = String(data: data, encoding: .utf8) ?? ""
            Log.llm.warning("""
                Gemini HTTP \(http.statusCode, privacy: .public) \
                host=\(req.url?.host ?? "?", privacy: .public) \
                body=\(body.prefix(400), privacy: .public)
                """)
            throw LLMError.http(http.statusCode, String(body.prefix(300)))
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Self.logResponseDiagnostic(req: req, http: http, data: data,
                                        outcome: "top_level_not_object")
            throw LLMError.decode("Top-level JSON not an object")
        }
        // Defensive parse — handles every "valid 200, no text" shape Gemini
        // can emit (MAX_TOKENS, SAFETY, RECITATION, only-function-call,
        // empty candidates, ...).  Returns a typed error we map to LLMError.
        switch Self.parseResponse(json) {
        case .success(let parsed):
            Self.logResponseDiagnostic(req: req, http: http, data: data,
                                        outcome: "ok",
                                        finishReason: parsed.finishReason,
                                        textLength: parsed.text.count)
            return (parsed.text, json)
        case .failure(let provErr):
            Self.logResponseDiagnostic(req: req, http: http, data: data,
                                        outcome: String(describing: provErr))
            throw provErr.asLLMError
        }
    }

    /// Pure response-shape parser.  Public+static for unit tests.
    ///
    /// Tolerates every documented "200 OK but no text" Gemini outcome:
    /// MAX_TOKENS, SAFETY, RECITATION, function-call-only parts, etc.
    /// Always returns a typed result — never raw decode error.
    static func parseResponse(_ json: [String: Any])
        -> Result<(text: String, finishReason: String?), GeminiProviderError> {

        // 1. Prompt block — input itself was rejected before any candidate.
        if let pf = json["promptFeedback"] as? [String: Any] {
            if let block = pf["blockReason"] as? String {
                let safety = extractSafetyRatingSummaries(pf["safetyRatings"])
                return .failure(.promptBlocked(reason: block, safety: safety))
            }
        }

        // 2. candidates[] — must exist and be non-empty.
        guard let candidates = json["candidates"] as? [[String: Any]] else {
            return .failure(.noCandidates)
        }
        guard !candidates.isEmpty else {
            return .failure(.noCandidates)
        }

        // 3. Walk every candidate.  Concatenate all `text` parts across
        //    every candidate's content (Gemini may emit multi-candidate
        //    responses, and within one candidate the `parts` array may
        //    interleave text + functionCall + executableCode etc.).
        var collectedText = ""
        var firstFinishReason: String? = nil
        var anyContentWithParts = false
        var anyParts = false

        for cand in candidates {
            let finish = cand["finishReason"] as? String
            if firstFinishReason == nil { firstFinishReason = finish }

            guard let content = cand["content"] as? [String: Any] else {
                continue
            }
            anyContentWithParts = true
            guard let parts = content["parts"] as? [[String: Any]],
                  !parts.isEmpty else {
                continue
            }
            anyParts = true
            for part in parts {
                if let t = part["text"] as? String, !t.isEmpty {
                    collectedText.append(t)
                }
            }
        }

        let trimmed = collectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return .success((text: trimmed, finishReason: firstFinishReason))
        }

        // 4. We have candidates but no text.  Classify why.
        // Safety / recitation block — first candidate's finishReason names it.
        if let fr = firstFinishReason {
            switch fr.uppercased() {
            case "SAFETY":
                let safety = candidates.first
                    .flatMap { extractSafetyRatingSummaries($0["safetyRatings"]) }
                    ?? []
                return .failure(.safetyBlocked(finishReason: fr, safety: safety))
            case "RECITATION":
                return .failure(.safetyBlocked(finishReason: fr, safety: []))
            case "MAX_TOKENS":
                return .failure(.maxTokensNoText)
            default:
                break
            }
        }

        if !anyContentWithParts {
            return .failure(.noContentInCandidate(finishReason: firstFinishReason))
        }
        if !anyParts {
            return .failure(.noPartsInContent(finishReason: firstFinishReason))
        }
        return .failure(.partsHadNoText(finishReason: firstFinishReason))
    }

    /// Pull `["category — probability"]` summaries out of a `safetyRatings`
    /// array (which Gemini returns as `[{category, probability, blocked}]`).
    /// Used purely for log/error context.
    private static func extractSafetyRatingSummaries(_ raw: Any?) -> [String] {
        guard let arr = raw as? [[String: Any]] else { return [] }
        return arr.compactMap { item in
            let cat  = item["category"]    as? String ?? "?"
            let prob = item["probability"] as? String ?? "?"
            let blocked = (item["blocked"] as? Bool) ?? false
            return blocked ? "\(cat)=\(prob) [BLOCKED]" : "\(cat)=\(prob)"
        }
    }

    /// Redacted diagnostic log — never includes the API key (we replace
    /// the `key=` query parameter with `key=***`).  Includes everything
    /// useful for triaging "200 OK but no text" cases:
    /// finishReason, promptFeedback.blockReason, safety ratings, raw body
    /// truncated to 400 chars.
    private static func logResponseDiagnostic(req: URLRequest,
                                              http: HTTPURLResponse,
                                              data: Data,
                                              outcome: String,
                                              finishReason: String? = nil,
                                              textLength: Int? = nil) {
        let redactedURL = redact(url: req.url)
        let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        var blockReason = "—"
        var safetyLines: [String] = []
        var firstFinish = finishReason ?? "—"
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let pf = json["promptFeedback"] as? [String: Any],
               let br = pf["blockReason"] as? String { blockReason = br }
            if let cands = json["candidates"] as? [[String: Any]],
               let first = cands.first {
                if let fr = first["finishReason"] as? String { firstFinish = fr }
                safetyLines = extractSafetyRatingSummaries(first["safetyRatings"])
            }
        }
        Log.llm.info("""
            Gemini response diag \
            outcome=\(outcome, privacy: .public) \
            status=\(http.statusCode, privacy: .public) \
            url=\(redactedURL, privacy: .public) \
            finish=\(firstFinish, privacy: .public) \
            promptBlock=\(blockReason, privacy: .public) \
            textLen=\(textLength.map(String.init) ?? "—", privacy: .public) \
            safety=[\(safetyLines.joined(separator: "; "), privacy: .public)] \
            body=\(body.prefix(400), privacy: .public)
            """)
    }

    /// Replace the `key=…` query parameter with `key=***` so URLs in logs
    /// never leak the API key.  Pure / side-effect free; testable.
    static func redact(url: URL?) -> String {
        guard let url else { return "?" }
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        comps.queryItems = comps.queryItems?.map { item in
            item.name == "key" ? URLQueryItem(name: "key", value: "***") : item
        }
        return comps.string ?? url.absoluteString
    }

    /// Up to 3 attempts with exponential backoff on transient failures.
    /// Mirrors `OpenAIChatClient.sendWithRetry` so circuit-breaker semantics
    /// and user-visible latency stay consistent across providers.
    private func sendWithRetry(req: URLRequest) async throws -> (String, [String: Any]) {
        var lastError: LLMError = .empty
        for attempt in 1...Self.maxAttempts {
            if Task.isCancelled { throw LLMError.cancelled }
            do {
                let result = try await performOnce(req)
                if attempt > 1 {
                    Log.llm.info("gemini_request_recovered_after_retry attempts=\(attempt) host=\(req.url?.host ?? "?", privacy: .public)")
                }
                return result
            } catch let err as LLMError {
                lastError = err
                let retryable = OpenAIChatClient.shouldRetry(error: err)
                if !retryable || attempt == Self.maxAttempts {
                    Log.llm.warning("gemini_request_failed attempts=\(attempt) retryable=\(retryable) error=\(err.errorDescription ?? "unknown", privacy: .public)")
                    throw err
                }
                let delayMs = Self.baseBackoffMs * Int(pow(2.0, Double(attempt - 1)))
                Log.llm.info("gemini_retry attempt=\(attempt) next_delay_ms=\(delayMs)")
                try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            } catch {
                throw error
            }
        }
        throw lastError
    }
}

// MARK: - GeminiVisionProvider (camera-frame descriptions)

/// VisionProvider adapter around `GeminiProvider`.
///
/// Reuses the text provider's request/response plumbing; the only
/// vision-specific work is per-mode system-prompt selection and
/// the image encoding (JPEG, downscaled to `maxWidth`).
///
/// Falls back to `AppleVisionFallbackProvider` whenever any guard fails
/// (provider disabled, key missing, network/HTTP error, decode error).
/// The fallback dispatch is mode-aware — same pattern as
/// `MiniMaxVisionProvider.earlyFallback`.
final class GeminiVisionProvider: VisionProvider {

    var providerName: String { "Gemini Vision" }

    private let provider: GeminiProvider
    private let maxWidth:  () -> Int
    private let isEnabled: () -> Bool
    private let fallback:  AppleVisionFallbackProvider
    private weak var appState: AppState?

    init(provider: GeminiProvider,
         isEnabled: @escaping () -> Bool,
         maxWidth: @escaping () -> Int = { 1024 },
         appState: AppState? = nil,
         fallback: AppleVisionFallbackProvider = AppleVisionFallbackProvider()) {
        self.provider  = provider
        self.isEnabled = isEnabled
        self.maxWidth  = maxWidth
        self.appState  = appState
        self.fallback  = fallback
    }

    func isAvailable() async -> Bool {
        guard isEnabled() else { return false }
        return await provider.isAvailable()
    }

    // MARK: - VisionProvider methods — same prompt set as MiniMaxVisionProvider

    func describeScene(image: CGImage) async -> VisionProviderResult {
        let sys = """
        You are Jarvis, a camera vision assistant.
        Describe what you see in this camera frame in 2–3 precise sentences.

        Cover all of the following that are visible:
        - People: clothing (exact colours and type), facial accessories (glasses, hat, beard), \
        what they are holding in their hands
        - Objects, devices, and items in the scene
        - Environment and background

        Be specific, not generic. Say "thick black glasses" not just "glasses". \
        Say "dark grey hoodie" not "a shirt". \
        Mention held objects explicitly — do not ignore items in hands. \
        NEVER identify or name any person.
        """
        return await run(image: image, mode: .describe,
                         systemPrompt: sys,
                         userPrompt: "What can you see in this camera frame?")
    }

    func describePerson(image: CGImage) async -> VisionProviderResult {
        let sys = """
        You are Jarvis, a camera vision assistant.
        Describe the person visible in this camera frame precisely.

        Cover these in order:
        1. FACE & ACCESSORIES: glasses (frame style and colour), hat, beard or facial hair, \
        visible jewellery, piercings.
        2. CLOTHING: exact colours and garment type — e.g. "dark grey zip-up hoodie", \
        "white t-shirt", "blue denim jacket". Do not say "a shirt" when you can be specific.
        3. POSTURE & POSITION: sitting or standing, facing direction, distance from camera.
        4. HANDS & HELD ITEMS: anything visible in the person's hands — phone, mug, remote, \
        book, controller, etc. Do not skip this even if small.
        5. ACTIVITY: what they appear to be doing.

        Rules:
        - Be precise and specific throughout.
        - NEVER identify, name, or infer the identity of the person.
        - Do not infer sensitive personal attributes.
        - If no person is visible, say so clearly.
        """
        return await run(image: image, mode: .describePerson,
                         systemPrompt: sys,
                         userPrompt: "Describe the person in this camera frame.")
    }

    func describeDesk(image: CGImage) async -> VisionProviderResult {
        let sys = """
        You are Jarvis, a camera vision assistant.
        Describe the desk or workspace and all visible objects in 2–3 sentences.

        Be specific: name every device (laptop brand/colour, monitor size, keyboard, phone, \
        tablet, headphones), papers, notebooks, food, drinks, and any other items.
        Mention the approximate layout (e.g. "two monitors side by side", "keyboard in front").
        Focus on what is physically present — not inferences.
        """
        return await run(image: image, mode: .describeDesk,
                         systemPrompt: sys,
                         userPrompt: "What objects and items can you see in this camera frame, particularly on the desk or workspace?")
    }

    func extractText(image: CGImage) async -> VisionProviderResult {
        let sys = """
        You are Jarvis, a camera vision assistant specialising in text extraction.
        Read all visible text in the image and list it clearly.
        Preserve the original wording exactly — do not paraphrase or correct.
        Organise by visual location (top, middle, bottom) if there are multiple blocks.
        If no text is visible, say so briefly.
        """
        return await run(image: image, mode: .readText,
                         systemPrompt: sys,
                         userPrompt: "Extract and list all readable text visible in this image.")
    }

    func detectObjects(image: CGImage) async -> VisionProviderResult {
        let sys = """
        You are Jarvis, a camera vision assistant.
        List the notable objects, devices, and people visible in this image.
        Mention facial accessories (glasses, hat) and held items.
        Use 1–2 natural sentences. Do not use bullet points.
        """
        return await run(image: image, mode: .detectPeople,
                         systemPrompt: sys,
                         userPrompt: "What objects and people are visible in this camera frame?")
    }

    func detectHeldObject(image: CGImage) async -> VisionProviderResult {
        let sys = """
        You are Jarvis, a camera vision assistant.
        Focus specifically on what the person is holding in their hands.

        Describe:
        1. The primary held object — name it precisely: "iPhone", "Android phone", \
        "coffee mug", "TV remote", "book", "pen", "gaming controller", "cup of tea", etc.
        2. Which hand or how it is held (left hand, both hands, etc.) if visible.
        3. Any secondary held items.

        If the person is not holding anything, say: "I don't see anything in their hands."
        If no person is visible, say: "No person is visible in the frame."
        Do not describe clothing or background unless it helps identify the object.
        Be direct and concise — one to three sentences maximum.
        NEVER identify or name any person.
        """
        return await run(image: image, mode: .detectHeldObject,
                         systemPrompt: sys,
                         userPrompt: "What is the person holding in their hands right now?")
    }

    // MARK: - Core

    private func run(image: CGImage,
                     mode: VisionMode,
                     systemPrompt: String,
                     userPrompt: String) async -> VisionProviderResult {
        let totalStart = Date()
        guard isEnabled() else {
            return await earlyFallback(image: image, mode: mode,
                                       reason: "Gemini vision not enabled")
        }
        if !(await provider.isAvailable()) {
            return await earlyFallback(image: image, mode: mode,
                                       reason: "Gemini not configured (key/model)")
        }

        // Encode image — JPEG at 0.80 quality, downscaled to maxWidth.
        let encodeStart = Date()
        guard let jpeg = Self.encodeJPEG(image, maxWidth: maxWidth()) else {
            return await earlyFallback(image: image, mode: mode,
                                       reason: "JPEG encode failed")
        }
        let encodeMs = Int(-encodeStart.timeIntervalSinceNow * 1000)
        let sizeKB   = jpeg.count / 1024
        let scaledW  = Self.scaledDimensions(width: image.width,
                                             height: image.height,
                                             maxSide: maxWidth()).0

        let request = LLMRequest(
            systemPrompt:    systemPrompt,
            userPrompt:      userPrompt,
            contextSummary:  nil,
            temperature:     0.3,
            maxTokens:       350,
            responseFormat:  .text,
            timeoutSeconds:  30,
            visionImageData: jpeg)
        do {
            let resp = try await provider.complete(request)
            let totalMs = Int(-totalStart.timeIntervalSinceNow * 1000)
            let result = VisionProviderResult(
                description:      resp.text,
                providerUsed:     providerName,
                modelUsed:        resp.model,
                latencyMs:        totalMs,
                imageWidthPx:     scaledW,
                imageSizeKB:      sizeKB,
                error:            nil,
                timestamp:        Date(),
                detectedEntities: [],
                confidenceScore:  nil)
            await updateDiagnostics(result, encodeMs: encodeMs)
            return result
        } catch {
            let reason = (error as? LLMError)?.errorDescription ?? error.localizedDescription
            Log.llm.warning("Gemini vision failed: \(reason, privacy: .public) — falling back to Apple Vision")
            let appleResult = await fallback.analyze(image: image, mode: mode)
            let diag = VisionProviderResult(
                description:      appleResult.description,
                providerUsed:     "Apple Vision (fallback)",
                modelUsed:        nil,
                latencyMs:        Int(-totalStart.timeIntervalSinceNow * 1000),
                imageWidthPx:     scaledW,
                imageSizeKB:      sizeKB,
                error:            reason,
                timestamp:        Date(),
                detectedEntities: [],
                confidenceScore:  nil)
            await updateDiagnostics(diag, encodeMs: encodeMs)
            return diag
        }
    }

    private func earlyFallback(image: CGImage,
                                mode: VisionMode,
                                reason: String) async -> VisionProviderResult {
        let appleResult = await fallback.analyze(image: image, mode: mode)
        let result = VisionProviderResult(
            description:      appleResult.description,
            providerUsed:     "Apple Vision (fallback)",
            modelUsed:        nil,
            latencyMs:        appleResult.latencyMs,
            imageWidthPx:     appleResult.imageWidthPx,
            imageSizeKB:      appleResult.imageSizeKB,
            error:            reason,
            timestamp:        Date(),
            detectedEntities: [],
            confidenceScore:  nil)
        await updateDiagnostics(result, encodeMs: 0)
        return result
    }

    @MainActor
    private func updateDiagnostics(_ result: VisionProviderResult, encodeMs: Int) {
        guard let s = appState else { return }
        s.lastVisionProvider    = result.providerUsed
        s.lastVisionImageSizeKB = result.imageSizeKB
        s.lastVisionEncodeMs    = encodeMs
        s.lastVisionRequestMs   = max(0, result.latencyMs - encodeMs)
        s.lastVisionTotalMs     = result.latencyMs
        s.lastVisionError       = result.error
        s.visionIsLoading       = false
    }

    // MARK: - Image encoding helpers (lifted from MiniMaxVisionProvider)

    private static func encodeJPEG(_ image: CGImage, maxWidth: Int) -> Data? {
        let (w, h) = scaledDimensions(width: image.width,
                                       height: image.height,
                                       maxSide: maxWidth)
        let target: CGImage
        if w < image.width || h < image.height {
            let space = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(data: nil, width: w, height: h,
                                       bitsPerComponent: 8, bytesPerRow: 0,
                                       space: space,
                                       bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                return nil
            }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let scaled = ctx.makeImage() else { return nil }
            target = scaled
        } else {
            target = image
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
                data as CFMutableData, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, target,
            [kCGImageDestinationLossyCompressionQuality: 0.80] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    private static func scaledDimensions(width: Int, height: Int, maxSide: Int) -> (Int, Int) {
        guard maxSide > 0, width > 0, height > 0 else { return (width, height) }
        let longest = max(width, height)
        guard longest > maxSide else { return (width, height) }
        let scale = Double(maxSide) / Double(longest)
        return (max(1, Int(Double(width) * scale)),
                max(1, Int(Double(height) * scale)))
    }
}
