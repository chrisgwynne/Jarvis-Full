import Foundation

enum LocalLLMError: Error, LocalizedError {
    case disabled
    case invalidURL
    case requestFailed(String)
    case invalidResponse
    case malformedJSON(String)
    case lowConfidence(Double)

    var errorDescription: String? {
        switch self {
        case .disabled:              return "Local LLM is disabled"
        case .invalidURL:            return "Invalid LLM endpoint URL"
        case .requestFailed(let m):  return "Request failed: \(m)"
        case .invalidResponse:       return "Invalid response from LLM"
        case .malformedJSON(let s):  return "Malformed JSON: \(s)"
        case .lowConfidence(let c):  return "Low confidence: \(String(format: "%.2f", c))"
        }
    }
}

final class LocalLLMClient {

    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: cfg)
    }

    func query(transcript: String, context: String, config: LocalLLMConfig) async throws -> LocalLLMStructuredResponse {
        guard config.enabled else { throw LocalLLMError.disabled }
        guard let url = buildURL(config: config) else { throw LocalLLMError.invalidURL }

        let systemPrompt = buildSystemPrompt(context: context)
        let userMessage  = "Transcript: \"\(transcript)\"\n\nRespond with JSON only."

        let body: Data
        if config.provider.usesOpenAISchema {
            body = try buildOpenAIBody(system: systemPrompt, user: userMessage, config: config)
        } else {
            body = try buildOllamaBody(system: systemPrompt, user: userMessage, config: config)
        }

        var req = URLRequest(url: url)
        req.httpMethod  = "POST"
        req.httpBody    = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = config.apiKey, !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = Double(config.timeoutSeconds)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let preview = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw LocalLLMError.requestFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1): \(preview)")
        }

        return try parseResponse(data: data, provider: config.provider)
    }

    // MARK: - URL

    private func buildURL(config: LocalLLMConfig) -> URL? {
        var base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasSuffix("/") { base = String(base.dropLast()) }
        let path = config.provider.chatPath
        return URL(string: base + path)
    }

    // MARK: - Request bodies

    private func buildOpenAIBody(system: String, user: String, config: LocalLLMConfig) throws -> Data {
        var obj: [String: Any] = [
            "messages": [
                ["role": "system",    "content": system],
                ["role": "user",      "content": user]
            ],
            "temperature": config.temperature,
            "max_tokens":  config.maxTokens
        ]
        if !config.modelName.isEmpty { obj["model"] = config.modelName }
        return try JSONSerialization.data(withJSONObject: obj)
    }

    private func buildOllamaBody(system: String, user: String, config: LocalLLMConfig) throws -> Data {
        var obj: [String: Any] = [
            "messages": [
                ["role": "system",    "content": system],
                ["role": "user",      "content": user]
            ],
            "stream": false,
            "options": ["temperature": config.temperature, "num_predict": config.maxTokens]
        ]
        if !config.modelName.isEmpty { obj["model"] = config.modelName }
        return try JSONSerialization.data(withJSONObject: obj)
    }

    // MARK: - Response parsing

    private func parseResponse(data: Data, provider: LocalLLMProvider) throws -> LocalLLMStructuredResponse {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LocalLLMError.invalidResponse
        }

        let content: String
        if provider.usesOpenAISchema {
            guard let choices = root["choices"] as? [[String: Any]],
                  let first   = choices.first,
                  let message = first["message"] as? [String: Any],
                  let c       = message["content"] as? String
            else { throw LocalLLMError.invalidResponse }
            content = c
        } else {
            guard let message = root["message"] as? [String: Any],
                  let c       = message["content"] as? String
            else { throw LocalLLMError.invalidResponse }
            content = c
        }

        return try extractStructured(from: content)
    }

    private func extractStructured(from raw: String) throws -> LocalLLMStructuredResponse {
        // Strip markdown fences if present
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            let lines = text.components(separatedBy: "\n")
            let inner = lines.dropFirst().prefix(while: { !$0.hasPrefix("```") })
            text = inner.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let data = text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(LocalLLMStructuredResponse.self, from: data)
        else {
            throw LocalLLMError.malformedJSON(String(text.prefix(200)))
        }

        guard decoded.isValid else {
            throw LocalLLMError.lowConfidence(decoded.confidence)
        }
        return decoded
    }

    // MARK: - System prompt

    private func buildSystemPrompt(context: String) -> String {
        var prompt = """
        You are a voice assistant intent classifier. Given a transcript, return a single JSON object with these fields:
        - "intent": snake_case intent name (required)
        - "target": specific target entity or nil (optional)
        - "confidence": 0.0–1.0 float (required)
        - "spoken_response": short spoken reply, under 80 chars (required)
        - "action": optional action hint

        RULES:
        - Return JSON ONLY. No markdown, no prose.
        - confidence < 0.55 means you are uncertain — ask a clarification question in spoken_response.
        - Never execute destructive intents; set confidence low instead.
        - If truly unknown, use intent "unknown" with confidence 0.10.
        """
        if !context.isEmpty {
            prompt += "\n\nCONTEXT:\n\(context)"
        }
        return prompt
    }
}
