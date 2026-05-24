import Foundation

/// Handles all Spotify-domain intents previously inline in JarvisController.execute().
/// Extracted following the ShopifyIntentHandler pilot pattern — Sprint P decomposition.
@MainActor final class SpotifyIntentHandler {

    private let prefs: PreferencesStore
    private let renderer: ResponseRenderer
    private lazy var client: SpotifyAPIClient = SpotifyAPIClient(prefsStore: prefs)

    var speak: (String) -> Void = { _ in }

    init(prefs: PreferencesStore, renderer: ResponseRenderer) {
        self.prefs = prefs
        self.renderer = renderer
    }

    /// Returns true if the intent was handled, false if it is not a Spotify intent.
    @discardableResult
    func handle(_ intent: Intent) -> Bool {
        guard !(prefs.spotifyPersonalToken?.isEmpty ?? true) else {
            switch intent {
            case .spotifyPlay, .spotifyPause, .spotifyResume, .spotifyNext,
                 .spotifyPrevious, .spotifyWhatIsPlaying, .spotifyVolume, .spotifyShuffle:
                speak(renderer.render(ResponseKey.spotifyNotConfig, [:]))
                return true
            default:
                return false
            }
        }
        switch intent {
        case .spotifyPlay(let query):
            Task {
                do {
                    try await client.play(query: query)
                    speak(renderer.render(ResponseKey.spotifyPlaying, ["query": query ?? "music"]))
                } catch {
                    speak(renderer.render(ResponseKey.spotifyError, [:]))
                }
            }
            return true

        case .spotifyPause:
            Task {
                do {
                    try await client.pause()
                    speak(renderer.render(ResponseKey.spotifyPaused, [:]))
                } catch {
                    speak(renderer.render(ResponseKey.spotifyError, [:]))
                }
            }
            return true

        case .spotifyResume:
            Task {
                do {
                    try await client.play()
                    speak(renderer.render(ResponseKey.spotifyResumed, [:]))
                } catch {
                    speak(renderer.render(ResponseKey.spotifyError, [:]))
                }
            }
            return true

        case .spotifyNext:
            Task {
                do {
                    try await client.next()
                    speak(renderer.render(ResponseKey.spotifySkipped, [:]))
                } catch {
                    speak(renderer.render(ResponseKey.spotifyError, [:]))
                }
            }
            return true

        case .spotifyPrevious:
            Task {
                do {
                    try await client.previous()
                    speak(renderer.render(ResponseKey.spotifyBack, [:]))
                } catch {
                    speak(renderer.render(ResponseKey.spotifyError, [:]))
                }
            }
            return true

        case .spotifyWhatIsPlaying:
            Task {
                do {
                    if let playback = try await client.getCurrentPlayback(),
                       let track = playback.track {
                        speak(renderer.render(ResponseKey.spotifyNowPlaying, ["track": track.displayName]))
                    } else {
                        speak(renderer.render(ResponseKey.spotifyNotPlaying, [:]))
                    }
                } catch {
                    speak(renderer.render(ResponseKey.spotifyError, [:]))
                }
            }
            return true

        case .spotifyVolume(let percent):
            Task {
                do {
                    try await client.setVolume(percent)
                    speak(renderer.render(ResponseKey.spotifyVolume, ["percent": "\(percent)"]))
                } catch {
                    speak(renderer.render(ResponseKey.spotifyError, [:]))
                }
            }
            return true

        case .spotifyShuffle(let on):
            Task {
                do {
                    try await client.setShuffle(on)
                    speak(renderer.render(on ? ResponseKey.spotifyShuffleOn : ResponseKey.spotifyShuffleOff, [:]))
                } catch {
                    speak(renderer.render(ResponseKey.spotifyError, [:]))
                }
            }
            return true

        default:
            return false
        }
    }
}
