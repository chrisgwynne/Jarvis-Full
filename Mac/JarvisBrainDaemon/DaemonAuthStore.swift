import CryptoKit
import Foundation
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

    private(set) var pairedDevices: [PairedDevice] = []
    private(set) var activePairingCode: ActivePairingCode? = nil

    init() {
        load()  // SECURITY AUDITED Phase 2: loadFromDisk called in init — pairedDevices populated on start
    }

    // MARK: - Gateway token (Keychain)

    var gatewayToken: String? { KeychainHelper.get("gateway_token") }

    // MARK: - Pairing

    @discardableResult
    func generatePairingCode() -> ActivePairingCode {
        let code = String(format: "%06d", Int.random(in: 100_000...999_999))
        let p = ActivePairingCode(code: code, expiresAt: Date().addingTimeInterval(300))
        activePairingCode = p
        return p
    }

    func completePairing(code: String, deviceId: String, deviceName: String, platform: String = "") -> String? {
        // SECURITY AUDITED Phase 2: expiresAt checked via isExpired before accepting code
        guard let active = activePairingCode, !active.isExpired, active.code == code else { return nil }
        pairedDevices.removeAll { $0.id == deviceId }
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
        pairedDevices.append(dev)
        activePairingCode = nil
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
        return pairedDevices.first { !$0.isRevoked && $0.tokenHash == h } != nil
    }

    // MARK: - Device management

    func revokeDevice(id: String) {
        guard let i = pairedDevices.firstIndex(where: { $0.id == id }) else { return }
        pairedDevices[i].isRevoked = true
        save()
    }

    func removeDevice(id: String) {
        pairedDevices.removeAll { $0.id == id }
        save()
    }

    func recordSeen(deviceId: String) {
        guard let i = pairedDevices.firstIndex(where: { $0.id == deviceId }) else { return }
        pairedDevices[i].lastSeenAt = Date()
        // SECURITY AUDITED Phase 2: persist lastSeenAt so reconnection diagnostics survive restarts
        save()
    }

    // MARK: - Persistence

    private var storeURL: URL {
        let sup = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return sup.appendingPathComponent("JarvisMac/daemon_paired_devices.json")
    }

    private func save() {
        guard let d = try? JSONEncoder().encode(pairedDevices) else { return }
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? d.write(to: storeURL, options: .atomic)
    }

    private func load() {
        guard let d = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([PairedDevice].self, from: d) else { return }
        pairedDevices = decoded
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
            kSecAttrService: "com.jarvis.mac",
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
            kSecAttrService: "com.jarvis.mac",
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
