import Foundation

/// llama.cpp local inference server (OpenAI-compatible API).
/// Default: http://localhost:8080/v1
///
/// llama.cpp's server exposes `/v1/models` for availability probing and
/// `/v1/chat/completions` for inference. No auth required by default.
/// Start with: `llama-server -m your-model.gguf --port 8080`
final class LlamaCppProvider: LLMProvider {
    let id = "llama_cpp"
    let name = "llama.cpp"

    /// llama.cpp server does not support multimodal vision input by default.
    /// Set true only when using a server build with multimodal plugin support.
    var supportsVision: Bool = false

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
        guard enabled() else { throw LLMError.providerDisabled("llama.cpp disabled in Settings") }
        let endpoint = URL(string: baseURL().trimmingTrailingSlash() + "/chat/completions")
        guard let endpoint else {
            throw LLMError.notConfigured("Invalid llama.cpp base URL")
        }
        let model = modelName().trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else {
            throw LLMError.notConfigured("No local model is available. Set a model name in Settings → Models → Local LLM.")
        }
        let client = OpenAIChatClient(
            endpoint: endpoint,
            authorizationHeader: nil,
            model: model
        )
        let start = Date()
        do {
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
            return LLMResponse(text: text, model: model, providerID: id, latencyMs: ms, rawJSON: raw)
        } catch let err as LLMError {
            throw err
        } catch {
            let msg = error.localizedDescription.lowercased()
            if msg.contains("connection refused") || msg.contains("could not connect") {
                throw LLMError.providerDisabled("llama.cpp is not running. Start with: llama-server -m model.gguf --port 8080")
            }
            throw error
        }
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                guard self.enabled() else {
                    continuation.finish(throwing: LLMError.providerDisabled("llama.cpp disabled"))
                    return
                }
                guard let endpoint = URL(string: self.baseURL().trimmingTrailingSlash() + "/chat/completions") else {
                    continuation.finish(throwing: LLMError.notConfigured("Invalid llama.cpp URL"))
                    return
                }
                let model = self.modelName().trimmingCharacters(in: .whitespaces)
                guard !model.isEmpty else {
                    continuation.finish(throwing: LLMError.notConfigured("No local model is available."))
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
