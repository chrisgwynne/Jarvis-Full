import Foundation

// MARK: - Public surface

protocol LLMProvider: AnyObject {
    /// Stable identifier used in logs and AppState diagnostics.
    var id: String { get }
    /// Human-readable name shown in Settings/Debug HUD.
    var name: String { get }
    /// Quick health check. Fast and side-effect free.
    func isAvailable() async -> Bool
    /// One-shot text completion. Throws on network / auth / decode error.
    func complete(_ request: LLMRequest) async throws -> LLMResponse
    /// Streaming completion — yields text chunks as they arrive.
    /// Default implementation wraps `complete()` in a single-yield stream.
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error>
}

extension LLMProvider {
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let response = try await self.complete(request)
                    continuation.yield(response.text)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

struct LLMRequest {
    var systemPrompt: String
    var userPrompt: String
    var contextSummary: String?
    var temperature: Double = 0.2
    var maxTokens: Int = 500
    var responseFormat: ResponseFormat = .text
    var timeoutSeconds: TimeInterval = 20
    /// Optional JPEG image data to include as a vision attachment.
    /// When set, the user message is sent as a multimodal content array
    /// (OpenAI vision format). Only providers that support vision will use
    /// this; text-only providers silently ignore it.
    var visionImageData: Data? = nil
    /// When true, providers that have a "thinking" / extended-reasoning
    /// mode should disable it for this request.  Gemini 2.5+ counts its
    /// thinking tokens against `maxTokens`, which can exhaust the budget
    /// before any visible text is emitted (the cause of the "Empty
    /// response" test-connection bug).  Other providers ignore this flag.
    /// Default false — preserves regular conversational behaviour where
    /// thinking is desirable.
    var disableThinking: Bool = false

    enum ResponseFormat { case text, json }
}

struct LLMResponse {
    let text: String
    let model: String
    let providerID: String
    let latencyMs: Int
    let rawJSON: [String: Any]?
}

enum LLMError: LocalizedError {
    case notConfigured(String)
    case providerDisabled(String)
    case network(String)
    case http(Int, String)
    case decode(String)
    case timeout
    case empty
    case rateLimited
    /// The request was cancelled by the caller (Task.cancel or URLSession
    /// cancellation).  Never retried — propagate up unchanged.
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notConfigured(let s): return "Not configured: \(s)"
        case .providerDisabled(let s): return "Provider disabled: \(s)"
        case .network(let s):       return "Network error: \(s)"
        case .http(let code, let body):
            return "HTTP \(code): \(body.prefix(120))"
        case .decode(let s):        return "Decode error: \(s)"
        case .timeout:              return "Request timed out"
        case .empty:                return "Empty response"
        case .rateLimited:          return "Rate limited"
        case .cancelled:            return "Request cancelled"
        }
    }
}

// MARK: - Provider routing mode

enum LLMProviderMode: String, Codable, CaseIterable, Identifiable {
    case auto           // Local → xAI → MiniMax → Gemini (local-first; only enabled providers)
    case xaiFirst       // xAI → MiniMax → Gemini → llama.cpp
    case xaiOnly
    case miniMaxFirst   // MiniMax → xAI → Gemini → llama.cpp
    case localFirst
    case localOnly
    case miniMaxOnly
    case geminiFirst    // Gemini → xAI → MiniMax → llama.cpp
    case geminiOnly
    case disabled

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto:          return "Auto (Local → xAI → MiniMax → Gemini)"
        case .xaiFirst:      return "xAI (Grok) first"
        case .xaiOnly:       return "xAI only"
        case .miniMaxFirst:  return "MiniMax first"
        case .localFirst:    return "Local first"
        case .localOnly:     return "Local only"
        case .miniMaxOnly:   return "MiniMax only"
        case .geminiFirst:   return "Gemini first"
        case .geminiOnly:    return "Gemini only"
        case .disabled:      return "Disabled"
        }
    }
}

// MARK: - LLM Decision

/// Explicit classification of whether an LLM call is warranted.
/// Every path through `tryLLMFallback` produces one of these and logs it.
/// This makes the decision visible in diagnostics without requiring the LLM itself.
enum LLMDecision {
    /// The query can be answered deterministically — no LLM needed.
    case notNeeded(reason: String)
    /// The LLM could improve the answer but a deterministic fallback exists.
    case optional(reason: String)
    /// The LLM is the only way to handle this query.
    case required(reason: String)

    var requiresLLM: Bool {
        if case .required = self { return true }
        return false
    }

    var reasonString: String {
        switch self {
        case .notNeeded(let r), .optional(let r), .required(let r): return r
        }
    }

    var label: String {
        switch self {
        case .notNeeded:  return "not_needed"
        case .optional:   return "optional"
        case .required:   return "required"
        }
    }
}

// MARK: - Disabled provider stub

/// Always-unavailable provider used as a placeholder when nothing is
/// configured. Keeping the protocol non-optional means call sites don't
/// have to check for nil — they just get a clear `providerDisabled`
/// error if no real provider is enabled.
final class DisabledLLMProvider: LLMProvider {
    let id = "disabled"
    let name = "Disabled"
    func isAvailable() async -> Bool { false }
    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        throw LLMError.providerDisabled("No LLM provider is configured")
    }
}
