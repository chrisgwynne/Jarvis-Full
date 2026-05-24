import Foundation

/// State of one entity, kept narrow on purpose. Domain-specific structs
/// (climate, media_player, etc.) can wrap this later.
struct HomeEntity: Codable, Identifiable, Equatable {
    let entityID: String
    let state: String
    let friendlyName: String?
    let lastChanged: Date?

    var id: String { entityID }

    var displayName: String {
        friendlyName ?? entityID
    }
}

protocol SmartHomeClient: AnyObject {
    var isConfigured: Bool { get }
    func getStatus() async throws -> [HomeEntity]
    func turnOn(_ entity: String) async throws
    func turnOff(_ entity: String) async throws
    func callService(domain: String, service: String, data: [String: String]) async throws
    func callServiceRaw(domain: String, service: String, body: [String: Any]) async throws
    /// Set light brightness 0-255 (HA native scale)
    func setBrightness(entity: String, level: Int) async throws
    /// Set light RGB color by name ("red", "blue", "warm white", etc.)
    func setColor(entity: String, color: String) async throws
    /// Activate a named scene
    func activateScene(name: String) async throws
    /// Return a snapshot JPEG URL for a camera entity (relative path from HA base URL)
    func getCameraSnapshotURL(entity: String) -> URL?
    /// Resolve a fuzzy user phrase ("the desk lamp") to a concrete entity_id.
    func resolveEntity(matching phrase: String) async -> String?
    /// Friendly name for a resolved entity_id, or the entity_id itself.
    func friendlyName(for entityID: String) async -> String
    /// Fetch a single entity's live state directly from HA (bypasses local cache).
    func getEntityState(_ entityID: String) async throws -> HomeEntity
}

/// Fallback used when no base URL / token is configured.
final class DisabledSmartHomeClient: SmartHomeClient {
    var isConfigured: Bool { false }
    func getStatus() async throws -> [HomeEntity] {
        throw JarvisError.notConfigured("Smart home base URL not set")
    }
    func turnOn(_ entity: String) async throws {
        throw JarvisError.notConfigured("Smart home base URL not set")
    }
    func turnOff(_ entity: String) async throws {
        throw JarvisError.notConfigured("Smart home base URL not set")
    }
    func callService(domain: String, service: String, data: [String: String]) async throws {
        throw JarvisError.notConfigured("Smart home base URL not set")
    }
    func callServiceRaw(domain: String, service: String, body: [String: Any]) async throws {
        throw JarvisError.notConfigured("Smart home base URL not set")
    }
    func setBrightness(entity: String, level: Int) async throws {
        throw JarvisError.notConfigured("Smart home base URL not set")
    }
    func setColor(entity: String, color: String) async throws {
        throw JarvisError.notConfigured("Smart home base URL not set")
    }
    func activateScene(name: String) async throws {
        throw JarvisError.notConfigured("Smart home base URL not set")
    }
    func getCameraSnapshotURL(entity: String) -> URL? { nil }
    func resolveEntity(matching phrase: String) async -> String? { nil }
    func friendlyName(for entityID: String) async -> String { entityID }
    func getEntityState(_ entityID: String) async throws -> HomeEntity {
        throw JarvisError.notConfigured("Smart home base URL not set")
    }
}
