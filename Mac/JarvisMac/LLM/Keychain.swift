import Foundation
import Security

/// Tiny generic-password keychain wrapper. API keys live here rather
/// than in `preferences.json` so they survive a `git diff` accidentally
/// committing the prefs file and aren't readable as plain text on disk.
enum Keychain {
    static let service = "com.jarvis.mac.JarvisMac"

    static func set(_ value: String, for account: String) {
        let data = Data(value.utf8)
        // Replace any existing entry first.
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(q as CFDictionary)
        guard !value.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func remove(_ account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(q as CFDictionary)
    }
}

/// Keychain accounts used by the LLM stack and integration API tokens.
///
/// Integration tokens migrated from `preferences.json` plaintext storage.
/// See `PreferencesStore.migratePlaintextTokensToKeychain()` for the migration
/// path that runs once per existing install.
enum KeychainAccount {
    static let miniMaxAPIKey            = "minimax_api_key"
    static let geminiAPIKey             = "gemini_api_key"
    static let xaiAPIKey                = "xai_api_key"
    static let homeAssistantToken       = "home_assistant_token"
    static let todoistAPIToken          = "todoist_api_token"
    static let githubPersonalAccessToken = "github_pat"
    static let shopifyAccessToken       = "shopify_access_token"
    static let spotifyPersonalToken     = "spotify_personal_token"
    /// Token used by `GitHubIssueService` to file Jarvis unknown-command
    /// issues against the user's configured repo.  Distinct from the
    /// `githubPersonalAccessToken` used by the GitHub-notifications
    /// proactivity provider so the user can scope them differently —
    /// notifications-read for one, issues-write for the other.
    static let githubIssuesToken        = "github_issues_token"
    /// Home Assistant WebSocket authentication token.  Displayed in Settings
    /// as a QR code for the Android companion app.  Kept in Keychain to avoid
    /// landing in `preferences.json` or version-control diffs.
    static let webSocketAuthToken       = "websocket_auth_token"
    /// Bearer token for the Mac Brain HTTP server (GET /brain/health,
    /// POST /brain/context, POST /brain/interactions).
    static let brainServerToken         = "brain_server_token"
    /// Unified gateway token — replaces the separate Brain bearer + Android WebSocket tokens.
    /// Set by GatewayMigration on first upgrade from the legacy split-auth model.
    static let gatewayToken             = "gateway_token"

    /// All integration tokens that participate in the plaintext→Keychain migration.
    /// Order matters for the migration log only; semantics are independent.
    static let migratableIntegrationTokens: [String] = [
        homeAssistantToken,
        todoistAPIToken,
        githubPersonalAccessToken,
        shopifyAccessToken,
        spotifyPersonalToken,
        webSocketAuthToken,
    ]
}
