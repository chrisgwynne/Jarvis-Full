import Foundation
import OSLog

private let presenceLogger = Logger(subsystem: "com.jarvis.brain", category: "presence")

// MARK: - DevicePresence

struct DevicePresence {
    let deviceId: String
    let platform: String
    var isListening: Bool
    var isSpeaking: Bool
    var isScreenLocked: Bool
    var isAppForeground: Bool
    var hasHeadset: Bool
    var batteryPercent: Int?      // nil if unknown
    var isCharging: Bool?
    var activityState: String     // "driving" | "walking" | "stationary" | "unknown"
    var focusMode: String         // "driving" | "sleep" | "meeting" | "quiet" | "normal"
    var updatedAt: Date
}

// MARK: - PresenceStore

/// Thread-safe singleton that tracks per-device presence state for routing decisions.
final class PresenceStore {
    static let shared = PresenceStore()
    private init() {}

    private var store: [String: DevicePresence] = [:]
    private let lock = NSLock()

    // MARK: - Update

    /// Applies a partial presence payload keyed by field name.
    func update(deviceId: String, platform: String, fields: [String: JSONValue]) {
        lock.withLock {
            var p = store[deviceId] ?? DevicePresence(
                deviceId:        deviceId,
                platform:        platform,
                isListening:     false,
                isSpeaking:      false,
                isScreenLocked:  false,
                isAppForeground: false,
                hasHeadset:      false,
                batteryPercent:  nil,
                isCharging:      nil,
                activityState:   "unknown",
                focusMode:       "normal",
                updatedAt:       Date()
            )

            if let v = fields["isListening"]?.boolValue     { p.isListening     = v }
            if let v = fields["isSpeaking"]?.boolValue      { p.isSpeaking      = v }
            if let v = fields["isScreenLocked"]?.boolValue  { p.isScreenLocked  = v }
            if let v = fields["isAppForeground"]?.boolValue { p.isAppForeground = v }
            if let v = fields["hasHeadset"]?.boolValue      { p.hasHeadset      = v }
            if let v = fields["activityState"]?.stringValue { p.activityState   = v }
            if let v = fields["focusMode"]?.stringValue     { p.focusMode       = v }

            if let v = fields["batteryPercent"] {
                switch v {
                case .int(let i):    p.batteryPercent = i
                case .double(let d): p.batteryPercent = Int(d)
                default: break
                }
            }
            if let v = fields["isCharging"]?.boolValue { p.isCharging = v }

            p.updatedAt = Date()
            store[deviceId] = p

            presenceLogger.debug("presence: updated deviceId=\(deviceId) platform=\(platform) focusMode=\(p.focusMode)")
        }
    }

    // MARK: - Query

    func presence(for deviceId: String) -> DevicePresence? {
        lock.withLock { store[deviceId] }
    }

    var allPresence: [DevicePresence] {
        lock.withLock { Array(store.values) }
    }

    // MARK: - Best output device

    /// Returns the deviceId of the best device to speak/show on.
    ///
    /// Priority:
    /// 1. Any Android device with headset
    /// 2. Mac, if connected and not screen-locked
    /// 3. First connected device
    var bestOutputDevice: String? {
        lock.withLock {
            // 1. Android with headset
            if let android = store.values.first(where: {
                $0.platform == "android" && $0.hasHeadset
            }) {
                return android.deviceId
            }

            // 2. Mac connected and not screen-locked
            if let mac = store.values.first(where: {
                $0.platform == "mac" && !$0.isScreenLocked
            }) {
                return mac.deviceId
            }

            // 3. First connected device (most recently updated)
            return store.values.sorted { $0.updatedAt > $1.updatedAt }.first?.deviceId
        }
    }

    // MARK: - Routing hints

    var anyDeviceHasHeadset: Bool {
        lock.withLock { store.values.contains { $0.hasHeadset } }
    }

    var anyDeviceDriving: Bool {
        lock.withLock {
            store.values.contains { $0.activityState == "driving" || $0.focusMode == "driving" }
        }
    }

    var anyDeviceInQuietMode: Bool {
        lock.withLock {
            store.values.contains { $0.focusMode == "quiet" || $0.focusMode == "sleep" }
        }
    }
}

// MARK: - JSONValue bool helper

private extension JSONValue {
    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
}
