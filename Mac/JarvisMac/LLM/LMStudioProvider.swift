import Foundation

/// LM Studio's local OpenAI-compatible server.
/// Default: http://localhost:1234/v1
///
/// LM Studio exposes `/v1/models` for a cheap availability probe and
/// `/v1/chat/completions` for inference. Both follow the OpenAI shape
/// exactly — no auth required by default.
final class LMStudioProvider: LLMProvider {
    let id = "lm_studio"
    let name = "LM Studio (local)"

    private let baseURL: () -> String
    private let modelName: () -> String
    private let enabled: () -> Bool

    init(baseURL: @escaping () -> String,
         modelName: @escaping () -> String,
         enabled: @escaping () -> Bool) {
        self.baseURL = baseURL
        self.modelName = modelName
        self.enabled = enabled
    }

    func isAvailable() async -> Bool {
        guard enabled() else { return false }
        guard let url = URL(string: baseURL().trimmingTrailingSlash() + "/models") else {
            return false
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 2.0
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            return (response as? HTTPURLResponse).map { (200..<400).contains($0.statusCode) } ?? false
        } catch {
            return false
        }
    }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        guard enabled() else { throw LLMError.providerDisabled("LM Studio disabled in Settings") }
        let endpoint = URL(string: baseURL().trimmingTrailingSlash() + "/chat/completions")
        guard let endpoint else {
            throw LLMError.notConfigured("Invalid LM Studio base URL")
        }
        let model = modelName().trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else {
            throw LLMError.notConfigured("LM Studio model name is empty")
        }
        let client = OpenAIChatClient(
            endpoint: endpoint,
            authorizationHeader: nil,
            model: model
        )
        let start = Date()
        let (text, raw) = try await client.complete(
            systemPrompt: request.systemPrompt,
            userPrompt: request.userPrompt,
            contextSummary: request.contextSummary,
            temperature: request.temperature,
            maxTokens: request.maxTokens,
            responseFormat: request.responseFormat,
            timeoutSeconds: request.timeoutSeconds
        )
        let ms = Int(-start.timeIntervalSinceNow * 1000)
        return LLMResponse(
            text: text,
            model: model,
            providerID: id,
            latencyMs: ms,
            rawJSON: raw
        )
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                guard self.enabled() else {
                    continuation.finish(throwing: LLMError.providerDisabled("LM Studio disabled"))
                    return
                }
                guard let endpoint = URL(string: self.baseURL().trimmingTrailingSlash() + "/chat/completions") else {
                    continuation.finish(throwing: LLMError.notConfigured("Invalid LM Studio URL"))
                    return
                }
                let model = self.modelName().trimmingCharacters(in: .whitespaces)
                guard !model.isEmpty else {
                    continuation.finish(throwing: LLMError.notConfigured("LM Studio model empty"))
                    return
                }
                let client = OpenAIChatClient(
                    endpoint: endpoint,
                    authorizationHeader: nil,
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
}

private extension String {
    func trimmingTrailingSlash() -> String {
        var s = self
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
