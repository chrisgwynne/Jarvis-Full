import Foundation
import Observation

/// Extended diagnostics for the unified Mac Brain Gateway.
/// Replaces BrainDiagnostics — JarvisController now holds `let gatewayDiagnostics = GatewayDiagnostics()`
/// and a `var brainDiagnostics: GatewayDiagnostics { gatewayDiagnostics }` alias for compat.
@Observable @MainActor
final class GatewayDiagnostics {

    // MARK: - Lifecycle
    var isRunning = false
    var listeningPort: UInt16 = 0
    var lastError: String? = nil
    private(set) var startedAt: Date? = nil

    // MARK: - Request counters (legacy compat names)
    var requestsServed = 0
    var unauthorizedAttempts = 0
    var lastContextAt: Date? = nil

    // MARK: - 13 required gateway diagnostics fields
    var gatewayPort: UInt16 { listeningPort }
    var gatewayBindAddress: String = "0.0.0.0"
    var gatewayHttpsEnabled: Bool = false      // future TLS support
    var gatewayAuthEnabled: Bool = true
    var connectedAndroidDevices: Int = 0
    var activeWebSocketClients: Int = 0
    var lastAndroidSeenAt: Date? = nil
    var pairingCodeActive: Bool = false
    var deprecatedAndroidPortEnabled: Bool = false
    var rejectedUnauthenticatedRequests: Int = 0
    var rejectedUnauthenticatedWebSockets: Int = 0
    var tokenRotationCount: Int = 0   // NOTE: also tracked in GatewayAuthStore

    // MARK: - Auth (delegates to GatewayAuthStore)
    var authToken: String? { GatewayAuthStore.shared.gatewayToken }
    func regenerateToken() { GatewayAuthStore.shared.regenerateGatewayToken(); tokenRotationCount += 1 }

    // MARK: - Lifecycle events
    func markRunning(port: UInt16, bindLocal: Bool = false) {
        isRunning = true; listeningPort = port; lastError = nil
        startedAt = Date()
        gatewayBindAddress = bindLocal ? "127.0.0.1" : "0.0.0.0"
    }
    // Legacy signature used in MacBrainServer
    func markRunning(port: UInt16) { markRunning(port: port, bindLocal: false) }
    func markStopped() { isRunning = false; startedAt = nil }
    func markError(_ m: String) { isRunning = false; lastError = m }

    // MARK: - Request accounting
    func recordRequest(path: String, statusCode: Int) {
        requestsServed += 1
        if path.contains("/context") { lastContextAt = Date() }
    }
    func recordUnauthorized(isWebSocket: Bool = false) {
        unauthorizedAttempts += 1
        if isWebSocket { rejectedUnauthenticatedWebSockets += 1 }
        else { rejectedUnauthenticatedRequests += 1 }
    }
    func recordAndroidSeen() { lastAndroidSeenAt = Date() }

    // MARK: - Computed
    var uptimeSeconds: Double { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }
    var statusLine: String {
        if isRunning { return "Running on :\(listeningPort) · \(connectedAndroidDevices) Android" }
        if let e = lastError { return "Error: \(e)" }
        return "Stopped"
    }
}

/// Backward-compat typealias so existing callers that reference BrainDiagnostics continue to compile.
typealias BrainDiagnostics = GatewayDiagnostics
