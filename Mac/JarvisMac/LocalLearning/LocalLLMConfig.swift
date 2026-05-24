import Foundation

// MARK: - Provider

enum LocalLLMProvider: String, Codable, CaseIterable, Identifiable {
    case openAICompatible = "openai_compatible"
    case llamaCpp         = "llama_cpp"
    case mlxServer        = "mlx_server"
    case ollama           = "ollama"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAICompatible: return "OpenAI-Compatible"
        case .llamaCpp:         return "llama.cpp"
        case .mlxServer:        return "MLX Server"
        case .ollama:           return "Ollama"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAICompatible: return "http://localhost:1234"
        case .llamaCpp:         return "http://localhost:8080"
        case .mlxServer:        return "http://localhost:8080"
        case .ollama:           return "http://localhost:11434"
        }
    }

    var chatPath: String {
        switch self {
        case .openAICompatible, .llamaCpp, .mlxServer: return "/v1/chat/completions"
        case .ollama:                                   return "/api/chat"
        }
    }

    var usesOpenAISchema: Bool {
        switch self {
        case .openAICompatible, .llamaCpp, .mlxServer: return true
        case .ollama:                                   return false
        }
    }
}

// MARK: - Structured response

struct LocalLLMStructuredResponse: Codable {
    let intent:         String
    let target:         String?
    let confidence:     Double
    let spokenResponse: String
    let action:         String?

    var isValid: Bool {
        confidence >= 0.45 && !intent.isEmpty && !spokenResponse.isEmpty && spokenResponse.count < 500
    }
    var isHighConfidence: Bool { confidence >= 0.75 }
    var isLowConfidence:  Bool { confidence < 0.55 }

    private enum CodingKeys: String, CodingKey {
        case intent, target, confidence
        case spokenResponse  = "spoken_response"
        case action
    }
}

// MARK: - Shared enums

enum InteractionSource: String, Codable {
    case command      = "command"
    case learnedAlias = "learned"
    case localLLM     = "local_llm"
    case cloudLLM     = "cloud_llm"
    case manual       = "manual"
    case unknown      = "unknown"
}

enum ApprovalState: String, Codable, CaseIterable {
    case pending  = "pending"
    case approved = "approved"
    case rejected = "rejected"
}

enum ExampleSource: String, Codable, CaseIterable {
    case userCorrection = "user_correction"
    case llmOutput      = "llm_output"
    case interaction    = "interaction"
    case manual         = "manual"
}

// MARK: - Config

struct LocalLLMConfig {
    var enabled: Bool              = false
    var provider: LocalLLMProvider = .openAICompatible
    var baseURL: String            = "http://localhost:1234"
    var modelName: String          = ""
    var apiKey: String?            = nil
    var timeoutSeconds: Int        = 30
    var maxTokens: Int             = 256
    var temperature: Double        = 0.2
}

// MARK: - Alias source

enum AliasSource: String, Codable {
    case userCorrection = "user_correction"
    case voiceLearning  = "voice_learning"
    case llmLearned     = "llm_learned"
    case manual         = "manual"
}
