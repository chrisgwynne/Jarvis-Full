import Foundation

// MARK: - JSONValue (heterogeneous Codable payload)

/// A Codable JSON value that tolerates any JSON structure without crashing.
enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil()                             { self = .null }
        else if let v = try? c.decode(Bool.self)     { self = .bool(v) }
        else if let v = try? c.decode(Int.self)      { self = .int(v) }
        else if let v = try? c.decode(Double.self)   { self = .double(v) }
        else if let v = try? c.decode(String.self)   { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self)         { self = .array(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:          try c.encodeNil()
        case .bool(let v):   try c.encode(v)
        case .int(let v):    try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v):  try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    var objectValue: [String: JSONValue]? {
        if case .object(let d) = self { return d }
        return nil
    }
}

// MARK: - Message target

enum DaemonMessageTarget: Codable, Equatable {
    case macApp
    case android(deviceId: String?)
    case windows(deviceId: String?)
    case broadcast
    case daemon

    enum CodingKeys: String, CodingKey { case type, deviceId }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let t = (try? c.decode(String.self, forKey: .type)) ?? "daemon"
        let did = try? c.decode(String.self, forKey: .deviceId)
        switch t {
        case "macApp":    self = .macApp
        case "android":   self = .android(deviceId: did)
        case "windows":   self = .windows(deviceId: did)
        case "broadcast": self = .broadcast
        default:          self = .daemon
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .macApp:
            try c.encode("macApp", forKey: .type)
        case .android(let did):
            try c.encode("android", forKey: .type)
            if let d = did { try c.encode(d, forKey: .deviceId) }
        case .windows(let did):
            try c.encode("windows", forKey: .type)
            if let d = did { try c.encode(d, forKey: .deviceId) }
        case .broadcast:
            try c.encode("broadcast", forKey: .type)
        case .daemon:
            try c.encode("daemon", forKey: .type)
        }
    }
}

// MARK: - Envelope

private let maxPayloadBytes = 256 * 1024  // 256 KB hard cap

struct DaemonMessageEnvelope: Codable {
    let id: String
    let type: String
    let sourceDeviceId: String
    let sourcePlatform: String          // "android" | "windows" | "mac" | "daemon"
    let target: DaemonMessageTarget
    let timestamp: Date
    let correlationId: String?
    let payload: JSONValue

    /// Decodes raw JSON bytes into an envelope. Returns nil on malformed or oversized input.
    static func decode(from data: Data) -> DaemonMessageEnvelope? {
        guard data.count <= maxPayloadBytes else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DaemonMessageEnvelope.self, from: data)
    }

    /// Encodes the envelope to JSON bytes. Returns nil on failure.
    func encode() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(self)
    }

    // Convenience initialiser for daemon-generated messages
    static func make(
        type: String,
        target: DaemonMessageTarget,
        payload: JSONValue = .object([:]),
        correlationId: String? = nil,
        sourcePlatform: String = "daemon"
    ) -> DaemonMessageEnvelope {
        DaemonMessageEnvelope(
            id: UUID().uuidString,
            type: type,
            sourceDeviceId: "daemon",
            sourcePlatform: sourcePlatform,
            target: target,
            timestamp: Date(),
            correlationId: correlationId,
            payload: payload
        )
    }
}
