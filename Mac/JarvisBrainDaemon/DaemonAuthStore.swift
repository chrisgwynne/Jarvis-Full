import CryptoKit
import Foundation
import OSLog
import Security

/// A device that completed the pairing handshake.
/// Mirrors GatewayAuthStore.PairedDevice — reads the same JSON file.
struct PairedDevice: Codable {
    let id: String
    var name: String
    let createdAt: Date
    var lastSeenAt: Date
    var capabilities: [String]
    var isRevoked: Bool
    let tokenHash: String
    // SECURITY AUDITED Phase 2: platform defaults to "" for backward compat with existing JSON
    var platform: String

    // Explicit memberwise init (required when custom Decodable init is present)
    init(id: String, name: String, createdAt: Date, lastSeenAt: Date,
         capabilities: [String], isRevoked: Bool, tokenHash: String, platform: String = "") {
        self.id = id; self.name = name; self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt; self.capabilities = capabilities
        self.isRevoked = isRevoked; self.tokenHash = tokenHash; self.platform = platform
    }

    enum CodingKeys: String, CodingKey {
        case id, name, createdAt, lastSeenAt, capabilities, isRevoked, tokenHash, platform
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id           = try c.decode(String.self, forKey: .id)
        name         = try c.decode(String.self, forKey: .name)
        createdAt    = try c.decode(Date.self, forKey: .createdAt)
        lastSeenAt   = try c.decode(Date.self, forKey: .lastSeenAt)
        capabilities = try c.decode([String].self, forKey: .capabilities)
        isRevoked    = try c.decode(Bool.self, forKey: .isRevoked)
        tokenHash    = try c.decode(String.self, forKey: .tokenHash)
        platform     = (try? c.decodeIfPresent(String.self, forKey: .platform)) ?? ""
    }
}

struct ActivePairingCode {
    let code: String
    let expiresAt: Date
    var isExpired: Bool { Date() > expiresAt }
}

/// Standalone auth store for JarvisBrainDaemon.
/// Reads/writes the same persistence files as the main app's GatewayAuthStore.
/// Does NOT import the main app target.
final class DaemonAuthStore {
    static let shared = DaemonAuthStore()

    private let storeLock = NSLock()
    private let serverLog = Logger(subsystem: "com.jarvis.daemon", category: "auth")

    // All mutable state below is guarded by `storeLock`. Public getters take the
    // lock and return a copy so callers never observe a torn array.
    private var _pairedDevices: [PairedDevice] = []
    private var _activePairingCode: ActivePairingCode? = nil

    var pairedDevices: [PairedDevice] { storeLock.withLock { _pairedDevices } }
    var activePairingCode: ActivePairingCode? { storeLock.withLock { _activePairingCode } }

    // ── lastSeenAt debounce (#37) ─────────────────────────────────────────
    // recordSeen() fires on every inbound frame and ping (potentially many per
    // second per device). Persisting to disk on each call was hammering the SSD
    // and holding the cross-process flock for every message. Instead we mark the
    // store dirty and flush at most once every `flushInterval` seconds on a
    // dedicated timer. The flush also reloads when the file changed externally so
    // a Mac-app revocation takes effect without a daemon restart (#33).
    private var lastSeenDirty = false
    private let flushInterval: TimeInterval = 15
    private var flushTimer: DispatchSourceTimer?
    private let flushQueue = DispatchQueue(label: "com.jarvis.daemon.auth.flush")

    init() {
        load()  // SECURITY AUDITED Phase 2: loadFromDisk called in init — pairedDevices populated on start
        // Cache the gateway token once at init so isAuthorized() never calls
        // KeychainHelper.get() per-request. The daemon process outlives the
        // main app; call invalidateGatewayToken() when the main app rotates.
        _gatewayToken = KeychainHelper.get("gateway_token")
        startFlushTimer()
    }

    private func startFlushTimer() {
        let timer = DispatchSource.makeTimerSource(queue: flushQueue)
        timer.schedule(deadline: .now() + flushInterval, repeating: flushInterval)
        timer.setEventHandler { [weak self] in self?.flushIfDirty() }
        timer.resume()
        flushTimer = timer
    }

    /// Persists pending lastSeenAt updates if any have accumulated, and pulls in
    /// any externally-written changes (e.g. a Mac-app revocation) so the daemon
    /// does not keep authorising a revoked device with stale in-memory state
    /// (#33). Safe to call from the timer or directly (e.g. on shutdown).
    func flushIfDirty() {
        let shouldFlush: Bool = storeLock.withLock {
            let dirty = lastSeenDirty
            lastSeenDirty = false
            return dirty
        }
        if shouldFlush {
            // save() already reloads + merges under the flock before writing,
            // so a flush both persists our changes and absorbs external ones.
            save()
        } else if fileChangedExternally() {
            // No pending writes but the file changed on disk — reload so a
            // revocation made by the Mac app takes effect promptly.
            reloadFromDisk()
        }
    }

    /// Tracks the data file's modification date to cheaply detect external writes.
    private var lastKnownModified: Date?
    private func fileChangedExternally() -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: storeURL.path),
              let modified = attrs[.modificationDate] as? Date else { return false }
        defer { lastKnownModified = modified }
        guard let last = lastKnownModified else { return false } // first observation
        return modified > last
    }

    // MARK: - Gateway token (Keychain, cached)

    /// Cached after init; re-read only when invalidateGatewayToken() is called.
    private var _gatewayToken: String?
    var gatewayToken: String? { _gatewayToken }

    /// Re-reads the gateway token from Keychain.
    /// Call after the main app writes a new token (e.g. on rotation).
    func invalidateGatewayToken() {
        _gatewayToken = KeychainHelper.get("gateway_token")
    }

    // MARK: - Pairing

    @discardableResult
    func generatePairingCode() -> ActivePairingCode {
        let code = String(format: "%06d", Int.random(in: 100_000...999_999))
        let p = ActivePairingCode(code: code, expiresAt: Date().addingTimeInterval(300))
        storeLock.withLock { _activePairingCode = p }
        return p
    }

    func completePairing(code: String, deviceId: String, deviceName: String, platform: String = "") -> String? {
        let raw = UUID().uuidString + UUID().uuidString
        var dev = PairedDevice(
            id: deviceId,
            name: deviceName.isEmpty ? (platform == "windows" ? "Windows Device" : "Android Device") : deviceName,
            createdAt: Date(), lastSeenAt: Date(),
            capabilities: ["android_bridge", "chat", "context"],
            isRevoked: false,
            tokenHash: sha256Hex(raw)
        )
        dev.platform = platform

        let accepted: Bool = storeLock.withLock {
            // SECURITY AUDITED Phase 2: expiresAt checked via isExpired before accepting code
            guard let active = _activePairingCode, !active.isExpired, active.code == code else { return false }
            _pairedDevices.removeAll { $0.id == deviceId }
            _pairedDevices.append(dev)
            _activePairingCode = nil
            return true
        }
        guard accepted else { return nil }
        save()
        return raw
    }

    // MARK: - Validation

    // SECURITY AUDITED Phase 2:
    // - No token logged (verified: no print/Logger calls with raw bearer)
    // - Gateway token compared directly (it is Keychain-only, never on disk, never logged)
    // - Device tokens compared via SHA-256 hash only (tokenHash field)
    // - Revoked devices filtered before hash compare
    // - completePairing checks expiresAt via ActivePairingCode.isExpired
    func isAuthorized(_ bearer: String) -> Bool {
        if bearer.isEmpty { return false }
        // Gateway token: Keychain-only, raw compare is acceptable (never persisted to disk)
        if let gt = gatewayToken, !gt.isEmpty, bearer == gt { return true }
        // Device tokens: always compared via SHA-256 hash; isRevoked guard is explicit
        let h = sha256Hex(bearer)
        return storeLock.withLock {
            _pairedDevices.first { !$0.isRevoked && $0.tokenHash == h } != nil
        }
    }

    // MARK: - Device management

    func revokeDevice(id: String) {
        let changed: Bool = storeLock.withLock {
            guard let i = _pairedDevices.firstIndex(where: { $0.id == id }) else { return false }
            _pairedDevices[i].isRevoked = true
            return true
        }
        if changed { save() }
    }

    func removeDevice(id: String) {
        storeLock.withLock { _pairedDevices.removeAll { $0.id == id } }
        save()
    }

    func recordSeen(deviceId: String) {
        // SECURITY AUDITED Phase 2: persist lastSeenAt so reconnection diagnostics
        // survive restarts — but debounced via dirty flag (flushed every 15s) so a
        // chatty client does not hammer the disk on every frame/ping.
        storeLock.withLock {
            guard let i = _pairedDevices.firstIndex(where: { $0.id == deviceId }) else { return }
            _pairedDevices[i].lastSeenAt = Date()
            lastSeenDirty = true
        }
    }

    /// Marks the active pairing code expired/cleared. Lock-guarded.
    func clearActivePairingCode() {
        storeLock.withLock { _activePairingCode = nil }
    }

    // MARK: - Persistence

    private var storeURL: URL {
        let sup = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return sup.appendingPathComponent("JarvisMac/gateway_paired_devices.json")
    }

    private func save() {
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        // DUAL-WRITER RACE (#33): the Mac app's GatewayAuthStore writes this same
        // file. Take the cross-process flock, RELOAD the latest on-disk state,
        // MERGE with our in-memory change (revocation sticky / newest lastSeen),
        // then write — all under the flock. The in-process `storeLock` snapshots
        // and re-applies `_pairedDevices` so auth checks are never blocked on disk
        // I/O. flock is taken OUTSIDE storeLock to avoid holding the in-process
        // lock across disk operations.
        GatewayAuthFileLock.withExclusiveLock(at: storeURL) {
            let snapshot: [PairedDevice] = storeLock.withLock { _pairedDevices }
            let onDisk = GatewayAuthFileLock.readDevices(at: storeURL)
            let merged = GatewayAuthFileLock.merge(local: snapshot, disk: onDisk)
            storeLock.withLock { _pairedDevices = merged }
            GatewayAuthFileLock.writeDevices(merged, to: storeURL)
        }
    }

    private func load() {
        GatewayAuthFileLock.withExclusiveLock(at: storeURL) {
            // Read the raw bytes so we can detect/back up corrupt JSON.
            guard let data = try? Data(contentsOf: storeURL) else { return }
            if let decoded = try? JSONDecoder().decode([PairedDevice].self, from: data) {
                storeLock.withLock { _pairedDevices = decoded }
            } else {
                // Corrupt JSON — backup and start fresh
                let backupURL = storeURL.deletingPathExtension().appendingPathExtension("json.bak")
                try? data.write(to: backupURL, options: .atomic)
                serverLog.error("DaemonAuthStore: corrupt JSON — backed up to .bak, starting with empty registry")
                storeLock.withLock { _pairedDevices = [] }
            }
        }
    }

    /// Re-reads the file under the cross-process lock and merges externally-written
    /// changes (e.g. a Mac-app revocation) into the in-memory list. Call on a poll
    /// or before an auth-sensitive read to pick up the other writer's changes.
    func reloadFromDisk() {
        GatewayAuthFileLock.withExclusiveLock(at: storeURL) {
            let snapshot: [PairedDevice] = storeLock.withLock { _pairedDevices }
            let onDisk = GatewayAuthFileLock.readDevices(at: storeURL)
            let merged = GatewayAuthFileLock.merge(local: snapshot, disk: onDisk)
            storeLock.withLock { _pairedDevices = merged }
        }
    }

    // MARK: - Crypto

    func sha256Hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Minimal Keychain helper (no main-app import)

enum KeychainHelper {
    static func get(_ key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "com.jarvis.mac.JarvisMac",
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    static func set(_ key: String, value: String) {
        let data = Data(value.utf8)
        // Try update first
        let updateQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "com.jarvis.mac.JarvisMac",
            kSecAttrAccount: key
        ]
        let attributes: [CFString: Any] = [kSecValueData: data]
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            // Insert
            var addQuery = updateQuery
            addQuery[kSecValueData] = data
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }
}
