import Foundation

/// Handles Weather-domain intents previously inline in JarvisController.execute().
/// Extracted following the per-domain handler pattern — Sprint P decomposition.
@MainActor final class WeatherIntentHandler {

    private let weatherService: WeatherService
    private let renderer: ResponseRenderer

    var speak: (String) -> Void = { _ in }

    init(weatherService: WeatherService, renderer: ResponseRenderer) {
        self.weatherService = weatherService
        self.renderer = renderer
    }

    /// Returns true if the intent was handled, false if it is not a Weather intent.
    func handle(_ intent: Intent) async -> Bool {
        switch intent {
        case .currentWeather:
            if !weatherService.isAuthorized {
                speak(renderer.render(ResponseKey.weatherLocationDenied))
                return true
            }
            let summary = await weatherService.spokenCurrentWeather()
            speak(renderer.render(ResponseKey.weatherCurrent, ["summary": summary]))
            return true

        case .weatherForecast(let days):
            if !weatherService.isAuthorized {
                speak(renderer.render(ResponseKey.weatherLocationDenied))
                return true
            }
            let summary = await weatherService.spokenForecast(days: days)
            speak(renderer.render(ResponseKey.weatherForecast, ["summary": summary]))
            return true

        default:
            return false
        }
    }
}
