import Foundation

// MARK: - HAEntityType

/// Semantic category of a Home Assistant entity, resolved at sync time.
enum HAEntityType: String, Codable, CaseIterable {
    case camera    = "camera"
    case motion    = "motion"
    case doorbell  = "doorbell"
    case light     = "light"
    case lock      = "lock"
    case climate   = "climate"
    case vacuum    = "vacuum"
    case sensor    = "sensor"
    case binary    = "binary_sensor"
    case other     = "other"

    var displayName: String {
        switch self {
        case .camera:   return "Camera"
        case .motion:   return "Motion Sensor"
        case .doorbell: return "Doorbell"
        case .light:    return "Light"
        case .lock:     return "Lock"
        case .climate:  return "Climate"
        case .vacuum:   return "Vacuum"
        case .sensor:   return "Sensor"
        case .binary:   return "Binary Sensor"
        case .other:    return "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .camera:   return "camera.fill"
        case .motion:   return "figure.walk"
        case .doorbell: return "bell.fill"
        case .light:    return "lightbulb.fill"
        case .lock:     return "lock.fill"
        case .climate:  return "thermometer"
        case .vacuum:   return "bubbles.and.sparkles"
        case .sensor:   return "antenna.radiowaves.left.and.right"
        case .binary:   return "circle.lefthalf.filled"
        case .other:    return "questionmark.circle"
        }
    }
}

// MARK: - HAEntity

/// A resolved Home Assistant entity with type, area, and alias information.
struct HAEntity: Identifiable, Equatable {
    let entityID: String
    let friendlyName: String
    let domain: String
    let deviceClass: String?
    let area: String?
    let type: HAEntityType
    var aliases: [String]
    var state: String

    var id: String { entityID }
    var displayName: String { friendlyName.isEmpty ? entityID : friendlyName }

    /// True for motion / occupancy / presence binary sensors that are NOT doorbells.
    var isMotionSensor: Bool {
        guard domain == "binary_sensor", !isDoorbellSensor else { return false }
        let dc = (deviceClass ?? "").lowercased()
        return dc == "motion" || dc == "occupancy" || dc == "presence"
    }

    /// True for doorbell-type sensors (device_class == "doorbell" or name hints).
    var isDoorbellSensor: Bool {
        guard domain == "binary_sensor" else { return false }
        if (deviceClass ?? "").lowercased() == "doorbell" { return true }
        let combined = entityID.lowercased() + " " + friendlyName.lowercased()
        return combined.contains("doorbell") || combined.contains("_ding") || combined.contains("front_door_ding")
    }

    /// True for entities in the `camera` domain.
    var isCamera: Bool { domain == "camera" }
}

// MARK: - HAEntityRegistry

/// Lightweight, in-memory registry of Home Assistant entities.
///
/// Populated by calling `sync(from:)` with the result of a `/api/states` call.
/// Provides typed access to cameras, motion sensors, and doorbell sensors,
/// plus fuzzy name resolution for voice commands.
@MainActor
final class HAEntityRegistry {

    // MARK: - State

    private(set) var entities: [HAEntity] = []
    private(set) var lastSyncDate: Date?

    // MARK: - Typed subsets

    var cameras: [HAEntity]         { entities.filter(\.isCamera) }
    var motionSensors: [HAEntity]   { entities.filter { $0.isMotionSensor } }
    var doorbellSensors: [HAEntity] { entities.filter(\.isDoorbellSensor) }

    var cameraCount: Int  { cameras.count }
    var motionCount: Int  { motionSensors.count + doorbellSensors.count }

    // MARK: - Sync

    /// Repopulate the registry from a flat `[HomeEntity]` array.
    /// The caller is responsible for also passing the attributes map when
    /// available (needed for `device_class` and area assignment).
    func sync(from homeEntities: [HomeEntity],
              attributes: [String: [String: Any]] = [:]) {
        entities = homeEntities.map { raw in
            let domain = raw.entityID.split(separator: ".").first
                .map(String.init) ?? "unknown"
            let attrs        = attributes[raw.entityID] ?? [:]
            let deviceClass  = attrs["device_class"] as? String
            let area         = attrs["area_id"] as? String
            let type         = Self.classify(
                domain: domain,
                deviceClass: deviceClass,
                entityID: raw.entityID,
                friendlyName: raw.friendlyName ?? ""
            )
            return HAEntity(
                entityID:     raw.entityID,
                friendlyName: raw.friendlyName ?? raw.entityID,
                domain:       domain,
                deviceClass:  deviceClass,
                area:         area,
                type:         type,
                aliases:      [],
                state:        raw.state
            )
        }
        lastSyncDate = Date()
        Log.app.info("[ha-registry] Synced \(self.entities.count) entities (\(self.cameraCount) cameras, \(self.motionCount) motion/doorbell)")
    }

    // MARK: - Fuzzy resolution

    /// Find the camera entity whose name or aliases best match a spoken phrase.
    func resolveCamera(matching phrase: String) -> HAEntity? {
        let needle = phrase.lowercased()
        let scored: [(HAEntity, Int)] = cameras.compactMap { entity in
            let fn = entity.friendlyName.lowercased()
            let id = entity.entityID.lowercased()

            for alias in entity.aliases {
                if alias.lowercased() == needle          { return (entity, 2000) }
                if alias.lowercased().contains(needle)   { return (entity, 400) }
            }
            if fn == needle                              { return (entity, 1000) }
            if fn.contains(needle)                       { return (entity, 100 + needle.count) }
            if needle.contains(fn), !fn.isEmpty          { return (entity, 50 + fn.count) }

            let tokens   = needle.split(separator: " ").map(String.init)
            let fnHits   = tokens.filter { fn.contains($0) }.count
            if fnHits >= max(1, tokens.count - 1)        { return (entity, 20 + fnHits * 10) }
            if id.contains(needle)                       { return (entity, needle.count) }
            let idHits   = tokens.filter { id.contains($0) }.count
            if idHits >= max(1, tokens.count - 1)        { return (entity, idHits) }
            return nil
        }
        return scored.sorted { $0.1 > $1.1 }.first?.0
    }

    /// Find a motion sensor matching a spoken phrase.
    func resolveMotionSensor(matching phrase: String) -> HAEntity? {
        let needle = phrase.lowercased()
        return (motionSensors + doorbellSensors).first {
            $0.friendlyName.lowercased().contains(needle) ||
            $0.entityID.lowercased().contains(needle)
        }
    }

    // MARK: - Camera inference

    /// Tries to find a camera entity whose name/area matches the sensor's name/area.
    /// Used as a fallback when no explicit HAMotionCameraMapping exists for the sensor.
    /// Returns the camera's entity ID, or nil if no good match is found.
    func inferredCamera(forSensor sensorID: String) -> String? {
        guard let sensor = entities.first(where: { $0.entityID == sensorID }) else { return nil }
        let sensorName = sensor.friendlyName.lowercased()
        let sensorArea = (sensor.area ?? "").lowercased()

        // 1. Same area match (strongest signal)
        if !sensorArea.isEmpty,
           let areaMatch = cameras.first(where: {
               ($0.area ?? "").lowercased() == sensorArea
           }) {
            return areaMatch.entityID
        }

        // 2. Shared keyword in friendly name (e.g. "front door motion" → "front door camera")
        let keywords = sensorName
            .components(separatedBy: .whitespaces)
            .filter { $0.count > 3 }   // skip short words ("the", "at")
        for camera in cameras {
            let cameraName = camera.friendlyName.lowercased()
            if keywords.contains(where: { cameraName.contains($0) }) {
                return camera.entityID
            }
        }

        // 3. Entity ID prefix match (e.g. "binary_sensor.front_door_motion" → "camera.front_door")
        let sensorBase = sensorID
            .components(separatedBy: ".").dropFirst().joined(separator: ".")
            .replacingOccurrences(of: "_motion", with: "")
            .replacingOccurrences(of: "_doorbell", with: "")
            .replacingOccurrences(of: "_ding", with: "")
        if let idMatch = cameras.first(where: { $0.entityID.contains(sensorBase) }) {
            return idMatch.entityID
        }

        return nil
    }

    // MARK: - Alias management

    func addAlias(_ alias: String, for entityID: String) {
        guard let i = entities.firstIndex(where: { $0.entityID == entityID }) else { return }
        if !entities[i].aliases.contains(where: { $0.lowercased() == alias.lowercased() }) {
            entities[i].aliases.append(alias)
        }
    }

    // MARK: - Classification helper

    private static func classify(domain: String,
                                  deviceClass: String?,
                                  entityID: String,
                                  friendlyName: String) -> HAEntityType {
        switch domain {
        case "camera":         return .camera
        case "light":          return .light
        case "lock":           return .lock
        case "climate":        return .climate
        case "vacuum":         return .vacuum
        case "sensor":         return .sensor
        case "binary_sensor":
            let dc       = (deviceClass ?? "").lowercased()
            let combined = entityID.lowercased() + " " + friendlyName.lowercased()
            if dc == "doorbell"
                || combined.contains("doorbell")
                || combined.contains("_ding") {
                return .doorbell
            }
            if dc == "motion" || dc == "occupancy" || dc == "presence" { return .motion }
            return .binary
        default: return .other
        }
    }
}
