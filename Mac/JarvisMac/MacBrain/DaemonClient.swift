import Foundation

/// Lightweight HTTP client the main app uses to read state from the daemon.
/// Never writes to daemon files directly — always goes through the HTTP API.
@MainActor
final class DaemonClient {
    static let shared = DaemonClient()

    private let base = "http://127.0.0.1:8765"

    private var authToken: String? {
        // Uses the same Keychain key as GatewayAuthStore
        Keychain.get(KeychainAccount.gatewayToken)
    }

    // MARK: - Fetches

    func fetchHealth() async -> DaemonHealthResponse? {
        return await get("/health", authenticated: false, as: DaemonHealthResponse.self)
    }

    func fetchStatus() async -> DaemonStatusResponse? {
        return await get("/v1/status", authenticated: true, as: DaemonStatusResponse.self)
    }

    func fetchDiagnostics() async -> [String: Any]? {
        guard let data = await rawGet("/v1/diagnostics", authenticated: true) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func fetchRouterDiagnostics() async -> [String: Any]? {
        guard let data = await rawGet("/v1/router/diagnostics", authenticated: true) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func fetchDevices() async -> [DaemonDeviceInfo]? {
        return await get("/v1/devices", authenticated: true, as: [DaemonDeviceInfo].self)
    }

    // MARK: - Response models

    struct DaemonHealthResponse: Codable {
        let status: String
        let daemon: Bool?
        let version: String?
    }

    struct DaemonStatusResponse: Codable {
        let uptimeSeconds: Double?
        let port: Int?
        let connectedDevices: Int?
        let startedAt: String?
        let version: String?
    }

    struct DaemonDeviceInfo: Codable, Identifiable {
        let id: String
        let name: String
        let platform: String?
        let pairedAt: String?
        let lastSeenAt: String?
        let isRevoked: Bool?
    }

    // MARK: - Helpers

    private func get<T: Decodable>(_ path: String, authenticated: Bool, as type: T.Type) async -> T? {
        guard let data = await rawGet(path, authenticated: authenticated) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func rawGet(_ path: String, authenticated: Bool) async -> Data? {
        guard let url = URL(string: base + path) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.httpMethod = "GET"
        if authenticated, let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return try? await URLSession.shared.data(for: request).0
    }
}
