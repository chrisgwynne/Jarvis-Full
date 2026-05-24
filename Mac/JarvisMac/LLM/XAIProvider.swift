import Foundation

/// xAI (Grok) chat-completion provider.
///
/// OpenAI-compatible endpoint:
///   https://api.x.ai/v1/chat/completions
///
/// Configure in Settings → AI → xAI:
///   Base URL:  https://api.x.ai/v1
///   Model:     grok-3-mini  (or grok-3, grok-beta)
///
/// `/chat/completions` is appended to the stored base URL automatically.
/// API key lives in the macOS Keychain only, never in preferences JSON.

private extension String {
    func trimmingTrailingSlash() -> String {
        var s = self
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

final class XAIProvider: LLMProvider {
    let id   = "xai"
    let name = "xAI (Grok)"

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
        return !modelName().trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Completion

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        guard enabled() else {
            throw LLMError.providerDisabled("xAI disabled in Settings")
        }
        guard let key = apiKey(), !key.isEmpty else {
            throw LLMError.notConfigured("xAI API key missing")
        }

        let url   = try buildEndpointURL()
        let model = modelName().trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else {
            throw LLMError.notConfigured("xAI model name is empty")
        }

        Log.llm.info("""
            xAI request \
            endpoint=\(url.absoluteString, privacy: .public) \
            model=\(model, privacy: .public) \
            keyLen=\(key.count, privacy: .public)
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
            Log.llm.info("xAI OK — \(ms, privacy: .public)ms model=\(model, privacy: .public)")
            return LLMResponse(text: text, model: model,
                               providerID: id, latencyMs: ms, rawJSON: raw)

        } catch LLMError.http(let code, let body) {
            Log.llm.error("""
                xAI HTTP \(code, privacy: .public) \
                endpoint=\(url.absoluteString, privacy: .public) \
                body=\(body.prefix(500), privacy: .public)
                """)
            if code == 401 {
                throw LLMError.http(401,
                    "401 Unauthorized — check your xAI API key in Settings → AI → xAI.\n" +
                    "Get a key at https://console.x.ai/")
            }
            if code == 404 {
                throw LLMError.http(404,
                    "404 — URL not found: \(url.absoluteString)\n" +
                    "Expected endpoint: POST https://api.x.ai/v1/chat/completions\n" +
                    "Check base URL in Settings → AI → xAI.")
            }
            throw LLMError.http(code, body)

        } catch LLMError.timeout {
            Log.llm.warning("xAI timeout")
            throw LLMError.timeout

        } catch LLMError.network(let msg) {
            Log.llm.warning("xAI network error: \(msg, privacy: .public)")
            throw LLMError.network(msg)
        }
    }

    // MARK: - Streaming

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                guard self.enabled() else {
                    continuation.finish(throwing: LLMError.providerDisabled("xAI disabled"))
                    return
                }
                guard let key = self.apiKey(), !key.isEmpty else {
                    continuation.finish(throwing: LLMError.notConfigured("xAI API key missing"))
                    return
                }
                guard let url = try? self.buildEndpointURL() else {
                    continuation.finish(throwing: LLMError.notConfigured("Invalid xAI URL"))
                    return
                }
                let model = self.modelName().trimmingCharacters(in: .whitespaces)
                guard !model.isEmpty else {
                    continuation.finish(throwing: LLMError.notConfigured("xAI model empty"))
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

    func buildEndpointURL() throws -> URL {
        let raw  = baseURL().trimmingCharacters(in: .whitespaces)
        let base = raw.trimmingTrailingSlash()

        guard !base.isEmpty else {
            throw LLMError.notConfigured("xAI base URL is empty — set it in Settings → AI")
        }

        if base.hasSuffix("/chat/completions") {
            guard let url = URL(string: base) else {
                throw LLMError.notConfigured("Invalid xAI URL: \(base)")
            }
            return url
        }

        let fullString = base + "/chat/completions"
        guard let url = URL(string: fullString) else {
            throw LLMError.notConfigured("Invalid xAI URL after join: \(fullString)")
        }
        return url
    }

    var previewEndpointURL: String {
        (try? buildEndpointURL())?.absoluteString ?? "(invalid base URL)"
    }

    // MARK: - Test connection

    /// Returns (result string, isError). Used by the Settings UI.
    func testConnection() async -> (String, Bool) {
        guard enabled() else { return ("Disabled in Settings", true) }
        guard let key = apiKey(), !key.isEmpty else { return ("No API key set", true) }
        let model = modelName().trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else { return ("No model name set", true) }
        guard let url = try? buildEndpointURL() else { return ("Invalid base URL", true) }

        let req = LLMRequest(
            systemPrompt:   "You are a helpful assistant.",
            userPrompt:     "Reply with exactly: xAI connection OK",
            temperature:    0.0,
            maxTokens:      16,
            timeoutSeconds: 12
        )
        do {
            let resp = try await complete(req)
            return ("Connected — \(resp.latencyMs)ms — \(resp.model)\n\(resp.text.prefix(120))", false)
        } catch {
            return (error.localizedDescription, true)
        }
    }
}
