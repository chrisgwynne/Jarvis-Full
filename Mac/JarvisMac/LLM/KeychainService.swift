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

    // MARK: - Startup phase guard

    /// True from process start until `endStartupPhase()` is called.
    /// While true, any read of a key that is not in `coreStartupKeys` is
    /// blocked: the call returns nil immediately and is counted as a
    /// blocked optional read.  This prevents background service inits from
    /// triggering OS "use your confidential information" prompts at launch.
    private(set) var startupPhaseActive: Bool = true

    /// Keys that are always permitted during the startup phase.
    private static let coreKeys: Set<String> = Set(["home_assistant_token",
                                                     "gateway_token",
                                                     "websocket_auth_token"])

    /// Mark the startup phase as complete.  Call this once all
    /// bootstrap-critical services have initialised (typically right after
    /// the JarvisController startup log is emitted).  After this point,
    /// feature keys may be read lazily without restriction.
    func endStartupPhase() {
        lock.lock()
        startupPhaseActive = false
        lock.unlock()
        log.info("[Keychain] startup phase ended — optional reads now permitted")
    }

    /// Read the cached entry for `key` without triggering a physical read.
    /// Returns nil if the key has not yet been read or written this session.
    func cachedEntry(for key: String) -> CacheEntry? {
        lock.lock()
        defer { lock.unlock() }
        return cache[key]
    }

    // MARK: - Diagnostics (thread-safe via lock)

    private(set) var physicalReads         = 0
    private(set) var physicalWrites        = 0
    private(set) var cacheHits             = 0
    private(set) var perKeyReads : [String: Int] = [:]
    private(set) var absentResults         = 0  // physical reads that found no item
    private(set) var aclKeyReads           = 0  // physical reads of ACL-scoped keys (potential prompts)
    private(set) var blockedOptionalReads  = 0  // reads blocked during startup phase

    // MARK: - Service identifier (matches existing entries)

    let service = "com.jarvis.mac.JarvisMac"

    // MARK: - Read

    /// Returns the cached value (if already read/written this session) or reads
    /// once from Keychain and caches the result. Never calls SecItemCopyMatching
    /// more than once per key per process lifetime.
    ///
    /// During the startup phase, reads of optional (non-core) keys are blocked:
    /// nil is returned immediately without touching the OS Keychain, preventing
    /// repeated password prompts at launch from background service initialisation.
    func get(_ key: String) -> String? {
        // Startup guard: block optional key reads before bootstrap completes.
        // Core keys (gateway_token, home_assistant_token, websocket_auth_token)
        // are always permitted; all other keys return nil during this phase.
        lock.lock()
        if startupPhaseActive && !Self.coreKeys.contains(key) {
            blockedOptionalReads += 1
            lock.unlock()
            log.warning("[Keychain] blocked optional startup read key=\(key, privacy: .public)")
            return nil
        }

        if let entry = cache[key] {
            cacheHits += 1
            lock.unlock()
            switch entry {
            case .present(let v):
                log.debug("[Keychain] cache hit key=\(key, privacy: .public)")
                return v
            case .absent:
                log.debug("[Keychain] optional key absent key=\(key, privacy: .public)")
                return nil
            }
        }
        physicalReads += 1
        perKeyReads[key, default: 0] += 1
        let readsSoFar = perKeyReads[key]!
        lock.unlock()

        if readsSoFar > 1 {
            log.warning("[Keychain] '\(key, privacy: .public)' read \(readsSoFar, privacy: .public)× — duplicate physical read, cache miss")
        }

        log.info("[Keychain] physical read key=\(key, privacy: .public)")
        let value = rawGet(key)

        lock.lock()
        cache[key] = value.map { .present($0) } ?? .absent
        if value == nil { absentResults += 1 }
        if Self.aclScopedKeys.contains(key), value != nil { aclKeyReads += 1 }
        lock.unlock()

        if value == nil {
            log.info("[Keychain] optional key absent key=\(key, privacy: .public)")
        }
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
        log.info("[Keychain] preload start keys=\(keys.count, privacy: .public)")
        let beforeReads = physicalReads
        let beforeHits  = cacheHits
        for key in keys { _ = get(key) }
        let physDelta = physicalReads - beforeReads
        let hitDelta  = cacheHits    - beforeHits
        log.info("[Keychain] preload complete physicalReads=\(physDelta, privacy: .public) cacheHits=\(hitDelta, privacy: .public)")
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
        let reads    = physicalReads
        let hits     = cacheHits
        let absent   = absentResults
        let aclReads = aclKeyReads
        let blocked  = blockedOptionalReads
        let perKey   = perKeyReads
        let uniqueRead = perKey.count
        lock.unlock()

        // promptCountEstimate: ACL-scoped keys that exist and were physically read.
        // On first install or after code-sign change, macOS prompts once per such key.
        // After the user grants "Always Allow", subsequent launches prompt 0 times
        // even though promptCountEstimate stays > 0 (ACL entry cached by the OS).
        var summary = "[Keychain] startup summary physicalReads=\(reads) blockedOptionalReads=\(blocked) promptCountEstimate=\(aclReads) cacheHits=\(hits) uniqueKeysRead=\(uniqueRead) optionalAbsent=\(absent)"
        if blocked > 0 {
            summary += " ⚠ \(blocked) optional reads were blocked during startup — services are reading tokens too early"
        }
        var dupeLines: [String] = []
        for (key, n) in perKey.sorted(by: { $0.key < $1.key }) where n > 1 {
            dupeLines.append("  ⚠ '\(key)' read \(n)× — duplicate physical read")
        }
        if !dupeLines.isEmpty {
            summary += "\n" + dupeLines.joined(separator: "\n")
        }
        return summary
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

    /// Reads only the core startup keys (homeAssistant, gateway, websocket) into
    /// the cache. Feature-specific keys (LLM API keys, Todoist, GitHub, etc.) are
    /// NOT read here — they are loaded lazily on first use and cached thereafter.
    ///
    /// This keeps the startup physical-read count to ≤3 and prevents optional
    /// missing keys from triggering OS password prompts during bootstrap.
    @MainActor
    static func load() -> SecretsSnapshot {
        let ks = KeychainService.shared
        // Warm only the 3 keys always needed at startup.
        ks.preload(keys: KeychainAccount.coreStartupKeys)
        // Core keys: always needed at bootstrap — already warmed by preload above.
        // Feature keys: nil here; providers read them lazily on first use via Keychain.get().
        // This keeps startup physical reads ≤ 3 and prevents optional-key OS prompts at launch.
        return SecretsSnapshot(
            xaiAPIKey:                     nil,
            miniMaxAPIKey:                 nil,
            geminiAPIKey:                  nil,
            homeAssistantToken:            ks.get(KeychainAccount.homeAssistantToken),
            todoistAPIToken:               nil,
            githubPersonalAccessToken:     nil,
            shopifyAccessToken:            nil,
            spotifyPersonalToken:          nil,
            webSocketAuthToken:            ks.get(KeychainAccount.webSocketAuthToken),
            githubIssuesToken:             nil,
            gatewayToken:                  ks.get(KeychainAccount.gatewayToken),
            brainServerToken:              nil
        )
    }
}
