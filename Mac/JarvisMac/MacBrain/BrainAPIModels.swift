import Foundation

// MARK: - Shared request metadata

struct BrainRequestMeta: Codable {
    var apiVersion: String
    var deviceId: String
    var requestId: String
    var timestamp: String?

    /// Fallback used when the caller omits the meta block entirely.
    static func anonymous() -> BrainRequestMeta {
        BrainRequestMeta(
            apiVersion: "1.0",
            deviceId: "unknown",
            requestId: UUID().uuidString,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
    }
}

// MARK: - GET /brain/health

struct BrainHealthResponse: Codable {
    var status: String       // "ok" | "degraded"
    var version: String
    var uptimeSeconds: Double
    var requestsServed: Int
    var lastContextAt: String?
}

// MARK: - POST /brain/context

struct BrainContextRequest: Codable {
    var meta: BrainRequestMeta?  // optional — defaults to anonymous() when omitted
    var query: String?
    var categories: [String]?   // "memory","project","preferences","ha_aliases","github"
    var maxItems: Int?

    var resolvedMeta: BrainRequestMeta { meta ?? .anonymous() }
}

struct BrainContextResponse: Codable {
    var requestId: String
    var generatedAt: String     // ISO-8601
    var blocks: [BrainContextBlock]
    var truncated: Bool
}

struct BrainContextBlock: Codable {
    var category: String
    var label: String
    var items: [BrainContextItem]
}

struct BrainContextItem: Codable {
    var key: String
    var value: String
    var confidence: Double?
    var source: String?
}

// MARK: - POST /brain/interactions

struct BrainInteractionsRequest: Codable {
    var meta: BrainRequestMeta?  // optional — defaults to anonymous() when omitted
    var events: [BrainInteractionEvent]

    var resolvedMeta: BrainRequestMeta { meta ?? .anonymous() }
}

struct BrainInteractionEvent: Codable {
    var eventId: String
    var eventType: String       // MEMORY_CANDIDATE, COMMAND_OUTCOME, ALIAS_CORRECTION,
                                // CONVERSATION_SUMMARY, HOME_ASSISTANT_CORRECTION
    var timestampIso: String
    var payload: [String: String]
}

struct BrainInteractionsResponse: Codable {
    var requestId: String
    var accepted: Int
    var rejected: Int
    var errors: [String]
}

// MARK: - Error envelope

struct BrainErrorResponse: Codable {
    var error: String
    var requestId: String?
}
