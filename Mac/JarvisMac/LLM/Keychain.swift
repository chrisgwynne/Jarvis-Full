import Foundation
import Security

// MARK: - Keychain (thin facade — all calls route through KeychainService)

/// Public API for Keychain access. All reads are served from the in-memory
/// cache after the first successful SecItemCopyMatching, so calling get()
/// repeatedly for the same key never triggers additional OS prompts.
///
/// No feature should call SecItem* directly — use Keychain.get/set/remove or
/// inject a SecretsSnapshot (preferred for startup-time values).
enum Keychain {

    static let service = KeychainService.shared.service

    static func set(_ value: String, for account: String) {
        KeychainService.shared.set(value, for: account)
    }

    static func get(_ account: String) -> String? {
        KeychainService.shared.get(account)
    }

    static func remove(_ account: String) {
        KeychainService.shared.remove(account)
    }
}

// MARK: - KeychainAccount

/// Stable account-key constants used across the app.
/// All reads/writes must use these constants — never inline the string.
enum KeychainAccount {
    static let miniMaxAPIKey             = "minimax_api_key"
    static let geminiAPIKey              = "gemini_api_key"
    static let xaiAPIKey                 = "xai_api_key"
    static let homeAssistantToken        = "home_assistant_token"
    static let todoistAPIToken           = "todoist_api_token"
    static let githubPersonalAccessToken = "github_pat"
    static let shopifyAccessToken        = "shopify_access_token"
    static let spotifyPersonalToken      = "spotify_personal_token"
    /// Issues-writer token — scoped separately from the notifications-reader PAT.
    static let githubIssuesToken         = "github_issues_token"
    /// Home Assistant WebSocket auth token (displayed as QR code in Settings).
    static let webSocketAuthToken        = "websocket_auth_token"
    /// Legacy Mac Brain HTTP bearer token — superseded by gatewayToken.
    static let brainServerToken          = "brain_server_token"
    /// Unified gateway token (replaces brainServerToken + Android WebSocket token).
    static let gatewayToken              = "gateway_token"

    /// All tokens that participate in the plaintext→Keychain migration.
    static let migratableIntegrationTokens: [String] = [
        homeAssistantToken,
        todoistAPIToken,
        githubPersonalAccessToken,
        shopifyAccessToken,
        spotifyPersonalToken,
        webSocketAuthToken,
    ]

    /// Keys read unconditionally at startup — small set, always needed.
    /// Only these trigger physical Keychain reads during bootstrap.
    static let coreStartupKeys: [String] = [
        homeAssistantToken,   // HA integration bootstraps immediately
        gatewayToken,         // daemon WebSocket auth
        webSocketAuthToken,   // pairing / QR code display
    ]

    /// Feature-specific keys — loaded lazily on first use via the cache.
    /// These do NOT trigger reads at startup; if the feature is never used
    /// in a session the physical read never happens.
    static let featureKeys: [String] = [
        xaiAPIKey,
        miniMaxAPIKey,
        geminiAPIKey,
        todoistAPIToken,
        githubPersonalAccessToken,
        shopifyAccessToken,
        spotifyPersonalToken,
        githubIssuesToken,
        brainServerToken,
    ]

    /// Every key the app may ever need. Used only for diagnostics and bulk
    /// invalidation — NOT for startup preload (use coreStartupKeys instead).
    static let allKnownKeys: [String] = coreStartupKeys + featureKeys
}
