import CryptoKit
import Foundation

/// A device that completed the pairing handshake.
struct PairedDevice: Codable, Identifiable, Equatable {
    let id: String           // stable device UUID from Android
    var name: String         // user-visible name e.g. "Chris's Pixel"
    let createdAt: Date
    var lastSeenAt: Date
    var capabilities: [String]  // ["android_bridge", "chat", "context"]
    var isRevoked: Bool
    let tokenHash: String    // SHA-256 hex of raw device token — never stored in clear
    static func == (l: PairedDevice, r: PairedDevice) -> Bool { l.id == r.id }
}

struct ActivePairingCode {
    let code: String
    let expiresAt: Date
    var isExpired: Bool { Date() > expiresAt }
}

/// Single auth authority for the Mac Brain Gateway (port 8765).
///
/// Token hierarchy:
///   Gateway token  — full-access, stored in Keychain (KeychainAccount.gatewayToken)
///   Device token   — scoped, issued after pairing; only its SHA-256 hash is persisted
///
/// Migration: on first launch, reads existing brain + WebSocket tokens and
/// promotes the brain token to gateway token (via GatewayMigration).
@Observable @MainActor
final class GatewayAuthStore {
    static let shared = GatewayAuthStore()

    private(set) var pairedDevices: [PairedDevice] = []
    private(set) var activePairingCode: ActivePairingCode? = nil
    private(set) var tokenRotationCount: Int = 0

    init() {
        load()
        // Read once from KeychainService (served from cache if already preloaded).
        // Never use a computed property for gatewayToken — each call would
        // be a fresh SecItemCopyMatching, triggering repeated OS prompts.
        _gatewayToken = KeychainService.shared.get(KeychainAccount.gatewayToken)
    }

    // MARK: - Gateway token

    /// Cached in memory after first read. Updated by regenerateGatewayToken().
    private var _gatewayToken: String?
    var gatewayToken: String? { _gatewayToken }

    @discardableResult
    func regenerateGatewayToken() -> String {
        let t = UUID().uuidString + UUID().uuidString // 72-char entropy
        KeychainService.shared.set(t, for: KeychainAccount.gatewayToken)
        _gatewayToken = t
        tokenRotationCount += 1
        return t
    }

    // MARK: - Pairing (6-digit code, 5-min expiry)
    @discardableResult
    func generatePairingCode() -> ActivePairingCode {
        let code = String(format: "%06d", Int.random(in: 100_000...999_999))
        let p = ActivePairingCode(code: code, expiresAt: Date().addingTimeInterval(300))
        activePairingCode = p
        return p
    }

    func setActivePairingCode(_ code: ActivePairingCode) {
        activePairingCode = code
    }

    /// Validates code and registers device. Returns raw device token on success (shown once).
    func completePairing(code: String, deviceId: String, deviceName: String) -> String? {
        guard let active = activePairingCode, !active.isExpired, active.code == code else { return nil }
        pairedDevices.removeAll { $0.id == deviceId }
        let raw = UUID().uuidString + UUID().uuidString
        let dev = PairedDevice(
            id: deviceId,
            name: deviceName.isEmpty ? "Android Device" : deviceName,
            createdAt: Date(), lastSeenAt: Date(),
            capabilities: ["android_bridge", "chat", "context"],
            isRevoked: false,
            tokenHash: sha256Hex(raw)
        )
        pairedDevices.append(dev)
        activePairingCode = nil
        save()
        return raw
    }

    // MARK: - Validation
    func isAuthorized(_ bearer: String) -> Bool {
        if let gt = gatewayToken, !gt.isEmpty, bearer == gt { return true }
        return validateDeviceToken(bearer) != nil
    }

    func validateDeviceToken(_ token: String) -> PairedDevice? {
        let h = sha256Hex(token)
        return pairedDevices.first { !$0.isRevoked && $0.tokenHash == h }
    }

    // MARK: - Device management
    func revokeDevice(id: String) {
        guard let i = pairedDevices.firstIndex(where: { $0.id == id }) else { return }
        pairedDevices[i].isRevoked = true; save()
    }
    func removeDevice(id: String) { pairedDevices.removeAll { $0.id == id }; save() }
    func recordSeen(deviceId: String) {
        guard let i = pairedDevices.firstIndex(where: { $0.id == deviceId }) else { return }
        pairedDevices[i].lastSeenAt = Date()
        // No save on every heartbeat — caller can batch-save if needed
    }
    func saveIfNeeded() { save() }

    // MARK: - Persistence
    //
    // DUAL-WRITER RACE (#33): this file is also written by JarvisBrainDaemon's
    // DaemonAuthStore (a separate process). Without coordination, a daemon write
    // (e.g. lastSeenAt heartbeat) can clobber a Mac-app write (e.g. a device
    // revocation) and silently lose it. Mitigation: every save() takes an
    // exclusive advisory file lock (flock), RELOADS the latest on-disk state,
    // MERGES it with our in-memory change (revocation is sticky / wins), then
    // writes — all under the lock. This makes concurrent writers safe.
    //
    // NOTE: the fully robust fix is to make only the daemon own the file and
    // route Mac-side revoke/remove through a daemon endpoint. That is a larger
    // change; this flock+reload+merge is the conservative interim mitigation.
    private var storeURL: URL {
        let sup = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return sup.appendingPathComponent("JarvisMac/gateway_paired_devices.json")
    }

    private func save() {
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        GatewayAuthFileLock.withExclusiveLock(at: storeURL) {
            // Reload the latest on-disk state and merge so we never clobber a
            // concurrent writer (the daemon).
            let onDisk = GatewayAuthFileLock.readDevices(at: storeURL)
            let merged = GatewayAuthFileLock.merge(local: pairedDevices, disk: onDisk)
            pairedDevices = merged
            GatewayAuthFileLock.writeDevices(merged, to: storeURL)
        }
    }

    private func load() {
        GatewayAuthFileLock.withExclusiveLock(at: storeURL) {
            pairedDevices = GatewayAuthFileLock.readDevices(at: storeURL)
        }
    }

    /// Re-reads the file under lock and merges any externally-written changes
    /// (e.g. daemon lastSeenAt / pairings) into the in-memory list. Safe to call
    /// before reading `pairedDevices` for display.
    func reloadFromDiskIfChanged() {
        GatewayAuthFileLock.withExclusiveLock(at: storeURL) {
            let onDisk = GatewayAuthFileLock.readDevices(at: storeURL)
            pairedDevices = GatewayAuthFileLock.merge(local: pairedDevices, disk: onDisk)
        }
    }
    func sha256Hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
