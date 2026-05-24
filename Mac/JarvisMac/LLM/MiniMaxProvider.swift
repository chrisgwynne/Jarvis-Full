import Foundation

/// MiniMax chat-completion provider.
///
/// OpenAI-compatible endpoint:
///   International:  https://api.minimax.io/v1/chat/completions
///   China:          https://api.minimaxi.com/v1/chat/completions
///
/// Configure in Settings → AI:
///   Base URL:  https://api.minimax.io/v1   (or /v1 China variant)
///   Model:     MiniMax-M2.7
///
/// `/chat/completions` is appended to whatever base URL is stored —
/// see `buildEndpointURL()` for the safe-join rules.
///
/// API key lives in the macOS Keychain only, never in preferences JSON.

private extension String {
    func trimmingTrailingSlash() -> String {
        var s = self
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

final class MiniMaxProvider: LLMProvider {
    let id   = "minimax"
    let name = "MiniMax"

    private let baseURL:   () -> String
    private let modelName: () -> String
    private let enabled:   () -> Bool
    private let apiKey:    () -> String?

    init(baseURL:   @escaping () -> String,
         modelName: @escaping () -> String,
         enabled:   @escaping () -> Bool,
         apiKey:    @escaping () -> String?) {
        self.baseURL   = baseURL
        self.modelName = modelName
        self.enabled   = enabled
        self.apiKey    = apiKey
    }

    // MARK: - Availability

    func isAvailable() async -> Bool {
        guard enabled() else { return false }
        guard let key = apiKey(), !key.isEmpty else { return false }
        // No cheap GET probe — treat "enabled + key present" as available;
        // any real error will surface on the first `complete` call.
        return true
    }

    // MARK: - Completion

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        guard enabled() else {
            throw LLMError.providerDisabled("MiniMax disabled in Settings")
        }
        guard let key = apiKey(), !key.isEmpty else {
            throw LLMError.notConfigured("MiniMax API key missing")
        }

        let url   = try buildEndpointURL()
        let model = modelName().trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else {
            throw LLMError.notConfigured("MiniMax model name is empty")
        }

        // ── URL / model diagnostic log (key is never logged) ──────────────────
        Log.llm.info("""
            MiniMax request \
            baseURL=\(self.baseURL(), privacy: .public) \
            endpoint=\(url.absoluteString, privacy: .public) \
            model=\(model, privacy: .public) \
            keyLen=\(key.count, privacy: .public) \
            stream=false
            """)

        let client = OpenAIChatClient(
            endpoint:            url,
            authorizationHeader: "Bearer \(key)",
            model:               model
        )

        let start = Date()
        do {
            let (text, raw) = try await client.complete(
                systemPrompt:   request.systemPrompt,
                userPrompt:     request.userPrompt,
                contextSummary: request.contextSummary,
                temperature:    request.temperature,
                maxTokens:      request.maxTokens,
                responseFormat: request.responseFormat,
                timeoutSeconds: request.timeoutSeconds,
                imageData:      request.visionImageData
            )
            let ms = Int(-start.timeIntervalSinceNow * 1000)
            Log.llm.info("MiniMax OK — \(ms, privacy: .public)ms model=\(model, privacy: .public)")
            return LLMResponse(text: text, model: model,
                               providerID: id, latencyMs: ms, rawJSON: raw)

        } catch LLMError.http(let code, let body) {
            Log.llm.error("""
                MiniMax HTTP \(code, privacy: .public) \
                endpoint=\(url.absoluteString, privacy: .public) \
                model=\(model, privacy: .public) \
                body=\(body.prefix(500), privacy: .public)
                """)
            if code == 404 {
                throw LLMError.http(404,
                    "404 — URL not found: \(url.absoluteString)\n" +
                    "Expected endpoint: POST /v1/chat/completions\n" +
                    "Check base URL in Settings → AI → MiniMax.\n" +
                    "Body: \(body.prefix(300))")
            }
            throw LLMError.http(code, body)

        } catch LLMError.timeout {
            // Do NOT retry with a blocking sleep — the circuit breaker handles
            // repeated failures and a 600 ms sleep doubles perceived latency.
            // Surface the error immediately so the circuit breaker can open fast.
            Log.llm.warning("MiniMax timeout — surfacing to circuit breaker")
            throw LLMError.timeout

        } catch LLMError.network(let msg) {
            Log.llm.warning("MiniMax network error — surfacing to circuit breaker: \(msg, privacy: .public)")
            throw LLMError.network(msg)
        }
    }

    // MARK: - Streaming

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                guard self.enabled() else {
                    continuation.finish(throwing: LLMError.providerDisabled("MiniMax disabled"))
                    return
                }
                guard let key = self.apiKey(), !key.isEmpty else {
                    continuation.finish(throwing: LLMError.notConfigured("MiniMax API key missing"))
                    return
                }
                guard let url = try? self.buildEndpointURL() else {
                    continuation.finish(throwing: LLMError.notConfigured("Invalid MiniMax URL"))
                    return
                }
                let model = self.modelName().trimmingCharacters(in: .whitespaces)
                guard !model.isEmpty else {
                    continuation.finish(throwing: LLMError.notConfigured("MiniMax model empty"))
                    return
                }
                let client = OpenAIChatClient(
                    endpoint: url,
                    authorizationHeader: "Bearer \(key)",
                    model: model
                )
                let inner = client.streamComplete(
                    systemPrompt:   request.systemPrompt,
                    userPrompt:     request.userPrompt,
                    contextSummary: request.contextSummary,
                    temperature:    request.temperature,
                    maxTokens:      request.maxTokens,
                    timeoutSeconds: request.timeoutSeconds
                )
                do {
                    for try await chunk in inner { continuation.yield(chunk) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - URL construction

    /// Safely joins the stored base URL with `/chat/completions`.
    ///
    /// Rules (in order):
    ///   1. Strip leading/trailing whitespace.
    ///   2. Strip any trailing `/` characters.
    ///   3. If the base already ends with `/chat/completions`, return as-is
    ///      (prevents double-appending if user pastes the full endpoint).
    ///   4. Append `/chat/completions` exactly once.
    ///
    /// Warnings logged but NOT thrown:
    ///   • Base contains `/api/v1` — likely misconfigured (expected `/v1`).
    ///   • Base path does not include `/v1` at all — may be missing version segment.
    ///
    /// Throws `LLMError.notConfigured` if the resulting string is not a valid URL.
    func buildEndpointURL() throws -> URL {
        let raw  = baseURL().trimmingCharacters(in: .whitespaces)
        let base = raw.trimmingTrailingSlash()

        guard !base.isEmpty else {
            throw LLMError.notConfigured("MiniMax base URL is empty — set it in Settings → AI")
        }

        // Already a full endpoint URL?
        if base.hasSuffix("/chat/completions") {
            guard let url = URL(string: base) else {
                throw LLMError.notConfigured("Invalid MiniMax URL: \(base)")
            }
            return url
        }

        // Sanity warnings — helpful in logs but not fatal.
        if base.contains("/api/v1") {
            Log.llm.warning("""
                MiniMax baseURL contains /api/v1 — expected pattern is /v1 \
                (e.g. https://api.minimax.io/v1). \
                Got: \(base, privacy: .public). \
                If you see a 404, try removing the /api prefix.
                """)
        } else if !base.contains("/v1") {
            Log.llm.warning("""
                MiniMax baseURL has no /v1 path segment — \
                expected https://api.minimax.io/v1 or https://api.minimaxi.com/v1. \
                Got: \(base, privacy: .public)
                """)
        }

        let fullString = base + "/chat/completions"
        guard let url = URL(string: fullString) else {
            throw LLMError.notConfigured("Invalid MiniMax URL after join: \(fullString)")
        }
        return url
    }

    /// Returns the final endpoint URL string that would be used for the next
    /// request, without throwing. Returns nil if the base URL is invalid.
    /// Used by the Settings test UI to show the exact URL before connecting.
    var previewEndpointURL: String {
        (try? buildEndpointURL())?.absoluteString ?? "(invalid base URL)"
    }
}
