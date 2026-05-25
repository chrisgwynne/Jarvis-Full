import Foundation
import OSLog

private let registryLogger = Logger(subsystem: "com.jarvis.brain", category: "registry")

// MARK: - DeviceRecord

struct DeviceRecord: Codable {
    let deviceId: String
    var deviceName: String
    let platform: String          // "android" | "windows" | "mac"
    var role: String              // "client" | "sidecar"
    var capabilities: [String]
    var appVersion: String
    var protocolVersion: String
    var isConnected: Bool
    var lastSeenAt: Date
    var lastError: String
}

// MARK: - DeviceRegistry

/// Thread-safe singleton that tracks live and recently-seen devices.
/// Not persisted to disk — rebuilt from WebSocket connections on each restart.
/// Capped at 50 records; oldest disconnected entries are evicted when cap is hit.
final class DeviceRegistry {
    static let shared = DeviceRegistry()
    private init() {}

    private var records: [String: DeviceRecord] = [:]
    private let lock = NSLock()

    private let maxRecords = 50

    // MARK: - Upsert

    func upsert(deviceId: String,
                deviceName: String,
                platform: String,
                capabilities: [String],
                appVersion: String,
                protocolVersion: String) {
        lock.withLock {
            if var existing = records[deviceId] {
                existing.deviceName      = deviceName
                existing.capabilities    = capabilities
                existing.appVersion      = appVersion
                existing.protocolVersion = protocolVersion
                existing.lastSeenAt      = Date()
                records[deviceId]        = existing
            } else {
                // Evict oldest disconnected entry if at cap
                if records.count >= maxRecords {
                    evictOldestDisconnected()
                }
                let record = DeviceRecord(
                    deviceId:        deviceId,
                    deviceName:      deviceName,
                    platform:        platform,
                    role:            "client",
                    capabilities:    capabilities,
                    appVersion:      appVersion,
                    protocolVersion: protocolVersion,
                    isConnected:     false,
                    lastSeenAt:      Date(),
                    lastError:       ""
                )
                records[deviceId] = record
            }
            registryLogger.info("registry: upserted deviceId=\(deviceId) platform=\(platform)")
        }
    }

    // MARK: - Connection state

    func markConnected(_ deviceId: String) {
        lock.withLock {
            if records[deviceId] != nil {
                records[deviceId]!.isConnected = true
                records[deviceId]!.lastSeenAt  = Date()
                records[deviceId]!.lastError   = ""
            } else {
                // Device connected before upsert — create minimal record
                let record = DeviceRecord(
                    deviceId:        deviceId,
                    deviceName:      deviceId,
                    platform:        "unknown",
                    role:            "client",
                    capabilities:    [],
                    appVersion:      "",
                    protocolVersion: "",
                    isConnected:     true,
                    lastSeenAt:      Date(),
                    lastError:       ""
                )
                records[deviceId] = record
            }
            registryLogger.info("registry: markConnected deviceId=\(deviceId)")
        }
    }

    func markDisconnected(_ deviceId: String, error: String?) {
        lock.withLock {
            guard records[deviceId] != nil else { return }
            records[deviceId]!.isConnected = false
            records[deviceId]!.lastSeenAt  = Date()
            if let err = error, !err.isEmpty {
                records[deviceId]!.lastError = err
            }
            registryLogger.info("registry: markDisconnected deviceId=\(deviceId)")
        }
    }

    // MARK: - Queries

    func record(for deviceId: String) -> DeviceRecord? {
        lock.withLock { records[deviceId] }
    }

    var connectedDevices: [DeviceRecord] {
        lock.withLock { records.values.filter { $0.isConnected } }
    }

    var allDevices: [DeviceRecord] {
        lock.withLock { Array(records.values) }
    }

    var connectedAndroid: [DeviceRecord] {
        lock.withLock { records.values.filter { $0.isConnected && $0.platform == "android" } }
    }

    var connectedWindows: [DeviceRecord] {
        lock.withLock { records.values.filter { $0.isConnected && $0.platform == "windows" } }
    }

    var isMacConnected: Bool {
        lock.withLock { records.values.contains { $0.isConnected && $0.platform == "mac" } }
    }

    // MARK: - Diagnostics

    var diagnosticsSummary: String {
        lock.withLock {
            let total     = records.count
            let connected = records.values.filter { $0.isConnected }.count
            let android   = records.values.filter { $0.isConnected && $0.platform == "android" }.count
            let windows   = records.values.filter { $0.isConnected && $0.platform == "windows" }.count
            let mac       = records.values.filter { $0.isConnected && $0.platform == "mac" }.count
            return "total=\(total) connected=\(connected) android=\(android) windows=\(windows) mac=\(mac)"
        }
    }

    // MARK: - Private helpers

    /// Must be called while `lock` is held.
    private func evictOldestDisconnected() {
        let disconnected = records.values
            .filter { !$0.isConnected }
            .sorted { $0.lastSeenAt < $1.lastSeenAt }
        if let oldest = disconnected.first {
            records.removeValue(forKey: oldest.deviceId)
            registryLogger.debug("registry: evicted oldest disconnected deviceId=\(oldest.deviceId)")
        }
    }
}
