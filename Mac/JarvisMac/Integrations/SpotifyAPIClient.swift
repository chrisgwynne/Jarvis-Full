import Foundation
import AppKit

// MARK: - Models

struct SpotifyTrack {
    let id: String
    let name: String
    let artist: String
    let album: String
    let durationMs: Int
    var displayName: String { "\(name) by \(artist)" }
}

struct SpotifyPlaybackState {
    let isPlaying: Bool
    let track: SpotifyTrack?
    let volumePercent: Int
    let progressMs: Int
    let deviceName: String
}

// MARK: - Errors

enum SpotifyError: Error, LocalizedError {
    case notAuthenticated
    case invalidURL
    case noActiveDevice

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "No Spotify token configured."
        case .invalidURL:       return "Invalid Spotify API URL."
        case .noActiveDevice:   return "No active Spotify device found."
        }
    }
}

// MARK: - Client

/// Thin Spotify Web API client that uses a personal access token (from the
/// Spotify Web API OAuth Playground). No OAuth server needed — just paste a
/// token with the right scopes into Settings.
///
/// Required scopes: `user-read-playback-state user-modify-playback-state`
@Observable
@MainActor
final class SpotifyAPIClient {

    private(set) var isAuthenticated = false
    private let prefsStore: PreferencesStore

    init(prefsStore: PreferencesStore) {
        self.prefsStore = prefsStore
        isAuthenticated = !(prefsStore.current.spotifyPersonalToken?.isEmpty ?? true)
    }

    // MARK: - Internal request helper

    @discardableResult
    private func apiRequest(
        _ path: String,
        method: String = "GET",
        body: Data? = nil
    ) async throws -> [String: Any]? {
        guard let token = prefsStore.current.spotifyPersonalToken, !token.isEmpty else {
            throw SpotifyError.notAuthenticated
        }
        guard let url = URL(string: "https://api.spotify.com/v1/\(path)") else {
            throw SpotifyError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: req)
        // 204 No Content — success with no body
        if let http = response as? HTTPURLResponse, http.statusCode == 204 { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - Playback state

    func getCurrentPlayback() async throws -> SpotifyPlaybackState? {
        guard let json = try await apiRequest("me/player") else { return nil }
        let isPlaying    = json["is_playing"] as? Bool ?? false
        let volumePercent = (json["device"] as? [String: Any])?["volume_percent"] as? Int ?? 50
        let deviceName   = (json["device"] as? [String: Any])?["name"] as? String ?? "Unknown"
        let progressMs   = json["progress_ms"] as? Int ?? 0
        var track: SpotifyTrack?
        if let item = json["item"] as? [String: Any] {
            let name   = item["name"] as? String ?? ""
            let artist = ((item["artists"] as? [[String: Any]])?.first?["name"] as? String) ?? ""
            let album  = (item["album"] as? [String: Any])?["name"] as? String ?? ""
            let id     = item["id"] as? String ?? ""
            let dur    = item["duration_ms"] as? Int ?? 0
            track = SpotifyTrack(id: id, name: name, artist: artist, album: album, durationMs: dur)
        }
        return SpotifyPlaybackState(
            isPlaying: isPlaying,
            track: track,
            volumePercent: volumePercent,
            progressMs: progressMs,
            deviceName: deviceName
        )
    }

    // MARK: - Playback control

    /// Play. If `query` is provided, searches for a track/playlist and plays the top result.
    /// If `query` is nil, resumes playback.
    func play(query: String? = nil) async throws {
        if let q = query, !q.isEmpty {
            let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
            if let results = try? await apiRequest("search?q=\(encoded)&type=track,playlist&limit=1"),
               let trackURI = ((results["tracks"] as? [String: Any])?["items"] as? [[String: Any]])?
                   .first?["uri"] as? String {
                let body = try? JSONSerialization.data(withJSONObject: ["uris": [trackURI]])
                try await apiRequest("me/player/play", method: "PUT", body: body)
                return
            }
            // Fallback: search playlists
            if let results = try? await apiRequest("search?q=\(encoded)&type=playlist&limit=1"),
               let contextURI = ((results["playlists"] as? [String: Any])?["items"] as? [[String: Any]])?
                   .first?["uri"] as? String {
                let body = try? JSONSerialization.data(withJSONObject: ["context_uri": contextURI])
                try await apiRequest("me/player/play", method: "PUT", body: body)
                return
            }
        }
        // Resume playback (no body)
        try await apiRequest("me/player/play", method: "PUT")
    }

    func pause() async throws {
        try await apiRequest("me/player/pause", method: "PUT")
    }

    func next() async throws {
        try await apiRequest("me/player/next", method: "POST")
    }

    func previous() async throws {
        try await apiRequest("me/player/previous", method: "POST")
    }

    func setVolume(_ percent: Int) async throws {
        let clamped = min(100, max(0, percent))
        try await apiRequest("me/player/volume?volume_percent=\(clamped)", method: "PUT")
    }

    func setShuffle(_ on: Bool) async throws {
        try await apiRequest("me/player/shuffle?state=\(on)", method: "PUT")
    }
}
