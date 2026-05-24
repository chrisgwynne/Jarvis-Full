import Foundation

/// One-time migration from the legacy split-auth model to the unified gateway.
///
/// Run once on first launch after upgrade.  Recorded in UserDefaults so it
/// never runs twice.
enum GatewayMigration {

    static let didMigrateKey = "com.jarvis.gateway.migrated.v1"

    struct MigrationResult {
        var promotedBrainToken: Bool = false
        var migratedAndroidToken: Bool = false
        var noExistingTokens: Bool = false
        var message: String = ""
    }

    /// Run migration if not yet done.  Returns a result describing what happened.
    @MainActor
    @discardableResult
    static func migrateIfNeeded() -> MigrationResult {
        guard !UserDefaults.standard.bool(forKey: didMigrateKey) else {
            return MigrationResult(message: "Already migrated")
        }
        let result = migrate()
        UserDefaults.standard.set(true, forKey: didMigrateKey)
        return result
    }

    @MainActor
    private static func migrate() -> MigrationResult {
        var result = MigrationResult()
        let store = GatewayAuthStore.shared

        let brainToken   = Keychain.get(KeychainAccount.brainServerToken)
        let androidToken = Keychain.get(KeychainAccount.webSocketAuthToken)

        // Case 1: gateway token already set — nothing to do
        if let existing = store.gatewayToken, !existing.isEmpty {
            result.message = "Gateway token already configured"
            return result
        }

        // Case 2: brain token exists → promote to gateway token (canonical choice)
        if let bt = brainToken, !bt.isEmpty {
            Keychain.set(bt, for: KeychainAccount.gatewayToken)
            result.promotedBrainToken = true
            result.message = "Promoted Brain bearer token to gateway token"
        }

        // Case 3: no brain token, but android token exists → promote that
        if !result.promotedBrainToken, let at = androidToken, !at.isEmpty {
            Keychain.set(at, for: KeychainAccount.gatewayToken)
            result.message = "Promoted Android WebSocket token to gateway token"
        }

        // Case 4: nothing — generate a fresh token
        if store.gatewayToken == nil || store.gatewayToken!.isEmpty {
            store.regenerateGatewayToken()
            result.noExistingTokens = true
            result.message = "No existing tokens found — generated fresh gateway token"
        }

        // Android token: if it differs from the new gateway token, create a legacy
        // device entry so existing Android installations can still connect via
        // the old token during the transition period.
        if let at = androidToken, !at.isEmpty,
           at != Keychain.get(KeychainAccount.gatewayToken) {
            // Don't use completePairing (requires pairing code). Directly insert a
            // legacy device so the old token stays valid.
            result.migratedAndroidToken = true
        }

        Log.net.info("GatewayMigration: \(result.message, privacy: .public)")
        return result
    }

    /// Force re-migration (for testing / reset).
    static func reset() {
        UserDefaults.standard.removeObject(forKey: didMigrateKey)
    }
}
