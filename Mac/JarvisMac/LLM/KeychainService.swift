import Foundation
import OSLog
import Security

// MARK: - KeychainService

/// Single point of truth for all macOS Keychain access.
///
/// Rules:
///   • Every feature/service reads through here — no direct SecItem* calls.
///   • First successful read is cached in memory; subsequent calls return the
///     cached value without touching the keychain, eliminating repeated prompts.
///   • Every write updates the cache so the next read is instant.
///   • Items are stored with kSecAttrAccessibleAfterFirstUnlock and an open
///     SecAccess so any binary signed by the same developer (Debug, Release,
///     Xcode, notarised) can read without triggering a new OS prompt.
///
/// Thread safety: NSLock guards the cache and diagnostic counters.
final class KeychainService {

    // MARK: - Singleton

    static let shared = KeychainService()

    // MARK: - Types

    enum CacheEntry {
        case present(String)
        case absent           // confirmed absent — don't retry

        var value: String? {
            switch self {
            case .present(let v): return v
            case .absent:         return nil
            }
        }
    }

    // MARK: - State

    private let lock  = NSLock()
    private let log   = Logger(subsystem: "com.jarvis.mac", category: "keychain")
    private var cache : [String: CacheEntry] = [:]

    // MARK: - Diagnostics (thread-safe via lock)

    private(set) var physicalReads  = 0
    private(set) var physicalWrites = 0
    private(set) var cacheHits      = 0
    private(set) var perKeyReads : [String: Int] = [:]

    // MARK: - Service identifier (matches existing entries)

    let service = "com.jarvis.mac.JarvisMac"

    // MARK: - Read

    /// Returns the cached value (if already read/written this session) or reads
    /// once from Keychain and caches the result. Never calls SecItemCopyMatching
    /// more than once per key per process lifetime.
    func get(_ key: String) -> String? {
        lock.lock()
        if let entry = cache[key] {
            cacheHits += 1
            lock.unlock()
            return entry.value
        }
        physicalReads += 1
        perKeyReads[key, default: 0] += 1
        let readsSoFar = perKeyReads[key]!
        lock.unlock()

        if readsSoFar > 1 {
            log.warning("[Keychain] '\(key, privacy: .public)' read \(readsSoFar, privacy: .public)× — duplicate not served from cache yet")
        }

        let value = rawGet(key)
        log.debug("[Keychain] read '\(key, privacy: .public)' → \(value != nil ? "present" : "absent", privacy: .public)")

        lock.lock()
        cache[key] = value.map { .present($0) } ?? .absent
        lock.unlock()

        return value
    }

    // MARK: - Write

    /// Stores `value` in Keychain and updates the cache.
    /// Pass `nil` or empty string to delete the entry.
    func set(_ value: String?, for key: String) {
        lock.lock()
        physicalWrites += 1
        lock.unlock()

        if let v = value, !v.isEmpty {
            rawSet(key, value: v)
            lock.lock()
            cache[key] = .present(v)
            lock.unlock()
            log.debug("[Keychain] write '\(key, privacy: .public)'")
        } else {
            rawDelete(key)
            lock.lock()
            cache[key] = .absent
            lock.unlock()
            log.debug("[Keychain] delete '\(key, privacy: .public)'")
        }
    }

    // MARK: - Delete

    func remove(_ key: String) { set(nil, for: key) }

    // MARK: - Bulk preload

    /// Reads a set of keys from Keychain in one pass and populates the cache.
    /// Call this at app startup (before any service initialises) so the first
    /// service access is always a cache hit — no repeated prompts.
    func preload(keys: [String]) {
        log.info("[Keychain] preloading \(keys.count, privacy: .public) keys")
        for key in keys { _ = get(key) }
        log.info("[Keychain] preload complete — \(self.physicalReads, privacy: .public) physical reads")
    }

    // MARK: - Cache invalidation

    /// Drops the cached entry for `key` so the next `get()` re-reads Keychain.
    /// Only needed when a separate process (e.g. JarvisBrainDaemon) may have
    /// written the item since this process last read it.
    func invalidate(_ key: String) {
        lock.lock()
        cache.removeValue(forKey: key)
        lock.unlock()
    }

    // MARK: - Diagnostics

    /// Human-readable startup summary. Call after the startup sequence is
    /// complete and log the result.
    func startupReport() -> String {
        lock.lock()
        let reads  = physicalReads
        let writes = physicalWrites
        let hits   = cacheHits
        let perKey = perKeyReads
        lock.unlock()

        var lines: [String] = ["[Keychain] startup: \(reads) physical reads, \(writes) writes, \(hits) cache hits"]
        for (key, n) in perKey.sorted(by: { $0.key < $1.key }) where n > 1 {
            lines.append("  ⚠ '\(key)' read \(n)× — check for missing cache use")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - SecItem internals (private — only call from get/set/remove)

    private func rawGet(_ key: String) -> String? {
        var q = baseQuery(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// High-value auth credentials that must NOT use the world-open ACL. These
    /// gate access to the Brain Gateway / Mac↔device bridge; a world-open ACL
    /// would let ANY process on the machine read them (#14). They use the default
    /// keychain ACL instead, which still permits the daemon (same code-signing
    /// identity) to read without a world-open policy.
    private static let aclScopedKeys: Set<String> = [
        "gateway_token",
        "brain_server_token",
        "websocket_auth_token",
    ]

    private func rawSet(_ key: String, value: String) {
        let data  = Data(value.utf8)
        let searchQ = baseQuery(key) as CFDictionary
        // Try update first (preserves existing ACL on already-migrated items)
        let updateAttrs: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(searchQ, updateAttrs as CFDictionary) == errSecItemNotFound {
            // Item doesn't exist — create it.
            var addQ = baseQuery(key)
            addQ[kSecValueData as String]     = data
            addQ[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            if Self.aclScopedKeys.contains(key) {
                // Sensitive credential: use the DEFAULT keychain ACL (app/team
                // scoped). Do NOT attach the world-open SecAccess. The daemon,
                // signed by the same identity, can still read it.
                log.debug("[Keychain] creating '\(key, privacy: .public)' with scoped (default) ACL")
            } else if let openAccess = makeOpenAccess() {
                // Low-sensitivity user-entered API tokens: open ACL avoids
                // repeated OS prompts across Debug/Release/Xcode builds.
                addQ[kSecAttrAccess as String] = openAccess
            }
            SecItemAdd(addQ as CFDictionary, nil)
        }
    }

    private func rawDelete(_ key: String) {
        SecItemDelete(baseQuery(key) as CFDictionary)
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [kSecClass      as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    /// Creates a SecAccess object that permits any application to read this
    /// Keychain item without triggering an OS password prompt. This eliminates
    /// repeated "wants to use your confidential information" dialogs when the
    /// same secret is accessed by different builds (Debug vs Release vs Xcode).
    ///
    /// Security note: this open ACL is used ONLY for low-sensitivity user-entered
    /// API tokens (Spotify, GitHub, etc.). High-value bridge credentials in
    /// `aclScopedKeys` (gateway/brain/websocket tokens) deliberately bypass this
    /// and use the default team-scoped ACL — see `rawSet` (#14).
    private func makeOpenAccess() -> SecAccess? {
        // Passing an empty CFArray for trustedList means: no application
        // restrictions — any application on this system can use the item
        // without a confirmation dialog.
        var access: SecAccess?
        let status = SecAccessCreate("JarvisMac" as CFString,
                                     [] as CFArray,
                                     &access)
        if status != errSecSuccess {
            log.warning("[Keychain] SecAccessCreate failed (\(status, privacy: .public)) — falling back to default ACL")
            return nil
        }
        return access
    }
}

// MARK: - SecretsSnapshot

/// Immutable snapshot of every known secret, loaded once during startup.
/// Pass this value into services instead of letting each service query
/// KeychainService independently.
struct SecretsSnapshot {

    // LLM providers
    let xaiAPIKey:     String?
    let miniMaxAPIKey: String?
    let geminiAPIKey:  String?

    // Integrations
    let homeAssistantToken:        String?
    let todoistAPIToken:           String?
    let githubPersonalAccessToken: String?
    let shopifyAccessToken:        String?
    let spotifyPersonalToken:      String?
    let webSocketAuthToken:        String?
    let githubIssuesToken:         String?

    // Gateway
    let gatewayToken:              String?
    let brainServerToken:          String?

    // MARK: - Factory

    /// Reads all known keys in a single batch, populating KeychainService's
    /// cache. Subsequent reads by any service return cached values.
    @MainActor
    static func load() -> SecretsSnapshot {
        let ks = KeychainService.shared
        // Pre-warm everything in one pass
        ks.preload(keys: KeychainAccount.allKnownKeys)
        return SecretsSnapshot(
            xaiAPIKey:                     ks.get(KeychainAccount.xaiAPIKey),
            miniMaxAPIKey:                 ks.get(KeychainAccount.miniMaxAPIKey),
            geminiAPIKey:                  ks.get(KeychainAccount.geminiAPIKey),
            homeAssistantToken:            ks.get(KeychainAccount.homeAssistantToken),
            todoistAPIToken:               ks.get(KeychainAccount.todoistAPIToken),
            githubPersonalAccessToken:     ks.get(KeychainAccount.githubPersonalAccessToken),
            shopifyAccessToken:            ks.get(KeychainAccount.shopifyAccessToken),
            spotifyPersonalToken:          ks.get(KeychainAccount.spotifyPersonalToken),
            webSocketAuthToken:            ks.get(KeychainAccount.webSocketAuthToken),
            githubIssuesToken:             ks.get(KeychainAccount.githubIssuesToken),
            gatewayToken:                  ks.get(KeychainAccount.gatewayToken),
            brainServerToken:              ks.get(KeychainAccount.brainServerToken)
        )
    }
}
