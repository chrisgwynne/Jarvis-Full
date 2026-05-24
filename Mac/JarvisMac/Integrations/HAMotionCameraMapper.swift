import Foundation

// MARK: - HAMotionCameraMapping

/// A user-configured link between a motion / doorbell sensor and a camera entity.
///
/// When the motion sensor fires, Jarvis speaks `alertPhrase` and opens the
/// linked camera's overlay — subject to per-entity and global cooldowns.
struct HAMotionCameraMapping: Codable, Identifiable, Equatable {
    var id: UUID = UUID()

    /// HA entity ID of the triggering sensor
    /// (e.g. `binary_sensor.front_door_motion`, `binary_sensor.ring_doorbell`).
    var motionSensorID: String

    /// HA entity ID of the camera to open
    /// (e.g. `camera.front_door`, `camera.ring_doorbell`).
    var cameraEntityID: String

    /// Spoken alert phrase when this mapping fires.
    /// Default: "Someone's at the door." for doorbells; "Motion detected." otherwise.
    var alertPhrase: String

    /// Raw `SignalPriority` integer value. Urgent (4) for doorbells; High (3) for motion.
    var priorityRaw: Int = SignalPriority.urgent.rawValue

    /// Seconds before this sensor can fire another alert (default 120 = 2 min).
    var cooldownSeconds: Double = 120

    /// Whether this mapping is active.
    var enabled: Bool = true

    /// Whether this represents a doorbell press (versus generic motion).
    /// Doorbell mappings fire immediately and say a distinct phrase.
    var isDoorbellMapping: Bool = false

    var priority: SignalPriority {
        SignalPriority(rawValue: priorityRaw) ?? .urgent
    }

    // MARK: - Presets

    /// A sensible front-door / Ring doorbell default.
    static var frontDoorDefault: HAMotionCameraMapping {
        HAMotionCameraMapping(
            motionSensorID:  "binary_sensor.front_door_motion",
            cameraEntityID:  "camera.front_door",
            alertPhrase:     "Someone's at the door.",
            priorityRaw:     SignalPriority.urgent.rawValue,
            cooldownSeconds: 120,
            enabled:         true,
            isDoorbellMapping: true
        )
    }
}

// MARK: - HAMotionCameraMapper

/// Owns all motion → camera mappings and enforces per-entity and global cooldowns.
///
/// All state is @MainActor because it's exclusively accessed from HA WebSocket
/// callbacks (already on main) and JarvisController (main actor).
@MainActor
final class HAMotionCameraMapper {

    // MARK: - Config

    var mappings: [HAMotionCameraMapping] = []

    /// Minimum seconds between any two HA camera alerts, regardless of entity.
    var globalCooldownSeconds: Double = 20

    // MARK: - Cooldown tracking

    /// Last time an alert fired for each sensor entity ID.
    private var lastAlertTime: [String: Date] = [:]

    /// Explicit suppression expiry per entity (e.g. "ignore for 1 hour").
    private var suppressUntil: [String: Date] = [:]

    /// Timestamp of the most recent HA camera alert (any entity).
    private(set) var lastGlobalAlertAt: Date?

    /// Last entity that fired an alert (for diagnostics).
    private(set) var lastAlertEntityID: String?

    // MARK: - Lookup

    /// Returns the enabled mapping for a given sensor ID, if one exists.
    func mapping(for sensorID: String) -> HAMotionCameraMapping? {
        mappings.first { $0.motionSensorID == sensorID && $0.enabled }
    }

    /// All enabled doorbell mappings.
    var doorbellMappings: [HAMotionCameraMapping] {
        mappings.filter { $0.isDoorbellMapping && $0.enabled }
    }

    // MARK: - Cooldown gate

    /// `true` if an alert can fire right now for `entityID` with the given cooldown.
    func canAlert(entityID: String, cooldownSeconds: Double) -> Bool {
        // Explicit suppression window (e.g. "ignore for 1 hour").
        if let until = suppressUntil[entityID], Date() < until {
            return false
        }
        // Global cooldown — any HA camera alert within the global window blocks this.
        if let last = lastGlobalAlertAt,
           Date().timeIntervalSince(last) < globalCooldownSeconds {
            return false
        }
        // Per-entity cooldown.
        if let last = lastAlertTime[entityID],
           Date().timeIntervalSince(last) < cooldownSeconds {
            return false
        }
        return true
    }

    /// `true` if no HA camera alert has fired within the global cooldown window.
    /// Checked independently of per-entity cooldown (allows separate diagnostics).
    func canGlobalAlert(cooldownSeconds: Double) -> Bool {
        guard let last = lastGlobalAlertAt else { return true }
        return Date().timeIntervalSince(last) >= cooldownSeconds
    }

    /// Record that an alert fired. Updates both per-entity and global timestamps.
    func recordAlert(entityID: String) {
        let now             = Date()
        lastAlertTime[entityID] = now
        lastGlobalAlertAt   = now
        lastAlertEntityID   = entityID
    }

    /// Suppress alerts for `entityID` for `seconds` seconds.
    func suppressEntity(_ entityID: String, for seconds: Double) {
        suppressUntil[entityID] = Date(timeIntervalSinceNow: seconds)
    }

    /// Clear an explicit suppression for `entityID`.
    func clearSuppression(for entityID: String) {
        suppressUntil.removeValue(forKey: entityID)
    }

    // MARK: - Diagnostics

    struct CooldownDiagnostics: Identifiable {
        let id: String          // entityID
        let lastAlertAt: Date?
        let cooldownSeconds: Double
        var remainingSeconds: Double {
            guard let last = lastAlertAt else { return 0 }
            return max(0, cooldownSeconds - Date().timeIntervalSince(last))
        }
        var isInCooldown: Bool { remainingSeconds > 0 }
    }

    func diagnostics(for entityID: String, cooldown: Double) -> CooldownDiagnostics {
        CooldownDiagnostics(
            id:              entityID,
            lastAlertAt:     lastAlertTime[entityID],
            cooldownSeconds: cooldown
        )
    }

    var globalDiagnostics: CooldownDiagnostics {
        CooldownDiagnostics(
            id:              "_global_",
            lastAlertAt:     lastGlobalAlertAt,
            cooldownSeconds: globalCooldownSeconds
        )
    }

    /// All per-entity diagnostics for display in the HA diagnostics overlay.
    var allEntityDiagnostics: [CooldownDiagnostics] {
        mappings.map { mapping in
            CooldownDiagnostics(
                id:              mapping.motionSensorID,
                lastAlertAt:     lastAlertTime[mapping.motionSensorID],
                cooldownSeconds: mapping.cooldownSeconds
            )
        }
    }
}
