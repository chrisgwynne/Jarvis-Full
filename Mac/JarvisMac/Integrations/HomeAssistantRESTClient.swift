import Foundation

/// Talks to a Home Assistant instance over its REST API.
///
/// Configuration (no cloud, no account beyond your HA instance):
///   - `baseURL` — e.g. `http://192.168.1.20:8123` or `https://ha.example.com`
///   - `token`   — long-lived access token from HA Profile → Security
///
/// Both come from `Preferences.smartHomeBaseURL` / `.smartHomeToken`. When
/// either is missing, the controller wires up `DisabledSmartHomeClient`
/// instead so call sites can't accidentally hit a misconfigured server.
final class HomeAssistantRESTClient: SmartHomeClient {

    var isConfigured: Bool { true }

    /// User-defined alias store — set from JarvisController after init.
    /// Weak to avoid a retain cycle (JarvisController owns both).
    weak var aliasStore: HomeEntityAliasStore?

    private let baseURL: URL
    private let token: String
    private let session: URLSession
    private var cachedEntities: [HomeEntity] = []
    private var cachedAt: Date?

    init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    func getStatus() async throws -> [HomeEntity] {
        let entities: [RawState] = try await get("/api/states")
        let mapped = entities.map { raw in
            HomeEntity(entityID: raw.entity_id,
                       state: raw.state,
                       friendlyName: raw.attributes?["friendly_name"]?.value as? String,
                       lastChanged: ISO8601DateFormatter().date(from: raw.last_changed ?? ""))
        }
        cachedEntities = mapped
        cachedAt = Date()
        return mapped
    }

    func getEntityState(_ entityID: String) async throws -> HomeEntity {
        let raw: RawState = try await get("/api/states/\(entityID)")
        return HomeEntity(entityID: raw.entity_id,
                          state: raw.state,
                          friendlyName: raw.attributes?["friendly_name"]?.value as? String,
                          lastChanged: ISO8601DateFormatter().date(from: raw.last_changed ?? ""))
    }

    func turnOn(_ entity: String) async throws {
        try await callService(domain: domain(of: entity),
                              service: "turn_on",
                              data: ["entity_id": entity])
    }

    func turnOff(_ entity: String) async throws {
        try await callService(domain: domain(of: entity),
                              service: "turn_off",
                              data: ["entity_id": entity])
    }

    func callService(domain: String,
                     service: String,
                     data: [String: String]) async throws {
        try await post("/api/services/\(domain)/\(service)", body: data)
    }

    func callServiceRaw(domain: String,
                        service: String,
                        body: [String: Any]) async throws {
        try await postRaw("/api/services/\(domain)/\(service)", body: body)
    }

    func setBrightness(entity: String, level: Int) async throws {
        // HA brightness is 0-255; level comes in as 0-100 percent
        let brightness = min(255, max(0, Int(Double(level) / 100.0 * 255)))
        try await callServiceRaw(domain: "light", service: "turn_on",
                                  body: ["entity_id": entity,
                                         "brightness": brightness])
    }

    func setColor(entity: String, color: String) async throws {
        let hs = Self.colorNameToHS(color)
        try await callServiceRaw(domain: "light", service: "turn_on",
                                  body: ["entity_id": entity,
                                         "hs_color": hs])
    }

    func activateScene(name: String) async throws {
        // Scenes can be addressed by entity_id (scene.name) or friendly name.
        // Try direct entity_id first, then resolve via cache.
        if cachedAt == nil || Date().timeIntervalSince(cachedAt!) > 60 {
            _ = try? await getStatus()
        }
        let needle = name.lowercased()
        let sceneEntity = cachedEntities.first { entity in
            guard entity.entityID.hasPrefix("scene.") else { return false }
            let fn = (entity.friendlyName ?? entity.entityID).lowercased()
            return fn.contains(needle) || entity.entityID.contains(needle)
        }
        let entityID = sceneEntity?.entityID ?? "scene.\(name.lowercased().replacingOccurrences(of: " ", with: "_"))"
        try await callServiceRaw(domain: "scene", service: "turn_on",
                                  body: ["entity_id": entityID])
    }

    func getCameraSnapshotURL(entity: String) -> URL? {
        // HA snapshot API: /api/camera_proxy/<entity_id>
        return baseURL.appendingPathComponent("api/camera_proxy/\(entity)")
    }

    func resolveEntity(matching phrase: String) async -> String? {
        // Check user-defined aliases first (exact case-insensitive match).
        if let store = aliasStore {
            let aliasID: String? = await MainActor.run { store.entityID(for: phrase) }
            if let aliasID { return aliasID }
        }

        // Refresh cache if stale (> 60s). Failure is non-fatal.
        if cachedAt == nil || Date().timeIntervalSince(cachedAt!) > 60 {
            _ = try? await getStatus()
        }
        let needle = phrase.lowercased()
        // Priority: exact friendly name match > partial friendly name > entity_id
        let scored: [(HomeEntity, Int)] = cachedEntities.compactMap { entity in
            let friendlyLower = (entity.friendlyName ?? "").lowercased()
            let idLower = entity.entityID.lowercased()
            // Exact friendly name match — highest score
            if friendlyLower == needle { return (entity, 1000) }
            // Friendly name contains phrase
            if friendlyLower.contains(needle) { return (entity, 100 + needle.count) }
            // Phrase contains friendly name (e.g. user says "office lamp" for entity "lamp")
            if needle.contains(friendlyLower) && !friendlyLower.isEmpty {
                return (entity, 50 + friendlyLower.count)
            }
            // Token-level match on friendly name
            let tokens = needle.split(separator: " ").map(String.init)
            let fnHits = tokens.filter { friendlyLower.contains($0) }.count
            if fnHits >= max(1, tokens.count - 1) { return (entity, 20 + fnHits * 10) }
            // Fall back to entity_id matching
            if idLower.contains(needle) { return (entity, needle.count) }
            let idHits = tokens.filter { idLower.contains($0) }.count
            if idHits >= max(1, tokens.count - 1) { return (entity, idHits) }
            return nil
        }
        return scored.sorted { $0.1 > $1.1 }.first?.0.entityID
    }

    func friendlyName(for entityID: String) async -> String {
        if cachedAt == nil { _ = try? await getStatus() }
        return cachedEntities.first(where: { $0.entityID == entityID })?.displayName ?? entityID
    }

    // MARK: - HTTP

    private func get<T: Decodable>(_ path: String) async throws -> T {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        try ensureOK(resp, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func post(_ path: String, body: [String: String]) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        let (data, resp) = try await session.data(for: req)
        try ensureOK(resp, data: data)
    }

    private func postRaw(_ path: String, body: [String: Any]) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        try ensureOK(resp, data: data)
    }

    /// Maps common color names to HA hue-saturation pairs [hue(0-360), sat(0-100)].
    private static func colorNameToHS(_ name: String) -> [Double] {
        switch name.lowercased() {
        case "red":           return [0, 100]
        case "orange":        return [30, 100]
        case "yellow":        return [60, 100]
        case "green":         return [120, 100]
        case "cyan":          return [180, 100]
        case "blue":          return [240, 100]
        case "purple":        return [270, 100]
        case "pink":          return [300, 100]
        case "white":         return [0, 0]
        case "warm white":    return [36, 50]
        case "cool white":    return [220, 20]
        default:              return [0, 0]   // white fallback
        }
    }

    private func ensureOK(_ resp: URLResponse, data: Data) throws {
        guard let http = resp as? HTTPURLResponse else {
            throw JarvisError.http(-1, "No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data.prefix(512), encoding: .utf8) ?? ""
            throw JarvisError.http(http.statusCode, body)
        }
    }

    private func domain(of entityID: String) -> String {
        entityID.split(separator: ".").first.map(String.init) ?? "homeassistant"
    }

    // MARK: - Wire types

    private struct RawState: Decodable {
        let entity_id: String
        let state: String
        let last_changed: String?
        let attributes: [String: AnyCodable]?
    }

    /// Minimal type-erased JSON value for the attributes dictionary.
    private struct AnyCodable: Decodable {
        let value: Any?
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { value = s; return }
            if let i = try? c.decode(Int.self)    { value = i; return }
            if let d = try? c.decode(Double.self) { value = d; return }
            if let b = try? c.decode(Bool.self)   { value = b; return }
            value = nil
        }
    }
}
