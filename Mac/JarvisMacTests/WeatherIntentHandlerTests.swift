import XCTest
@testable import JarvisMac

final class WeatherIntentHandlerTests: XCTestCase {

    @MainActor
    private func makeHandler() -> WeatherIntentHandler {
        let weather  = WeatherService()
        let renderer = ResponseRenderer(store: ResponseTemplateStore())
        return WeatherIntentHandler(weatherService: weather, renderer: renderer)
    }

    // MARK: - Return value

    @MainActor
    func test_weatherIntents_returnTrue() async {
        let h = makeHandler()
        h.speak = { _ in }

        let handled1 = await h.handle(.currentWeather)
        let handled2 = await h.handle(.weatherForecast(days: 3))
        XCTAssertTrue(handled1)
        XCTAssertTrue(handled2)
    }

    @MainActor
    func test_nonWeatherIntent_returnsFalse() async {
        let h = makeHandler()
        h.speak = { _ in }

        let handled = await h.handle(.showCalendar)
        XCTAssertFalse(handled)
    }

    // MARK: - Unauthorized location guard

    @MainActor
    func test_currentWeather_withoutLocationAuth_speaksDenied() async {
        let h = makeHandler()
        // WeatherService.isAuthorized starts false (location not granted in tests).
        var spokenTexts = [String]()
        h.speak = { spokenTexts.append($0) }

        _ = await h.handle(.currentWeather)

        XCTAssertFalse(spokenTexts.isEmpty)
        // The spoken response should be the "location denied" template, not empty.
        XCTAssertFalse(spokenTexts.first?.isEmpty ?? true)
    }

    @MainActor
    func test_weatherForecast_withoutLocationAuth_speaksDenied() async {
        let h = makeHandler()
        var spokenTexts = [String]()
        h.speak = { spokenTexts.append($0) }

        _ = await h.handle(.weatherForecast(days: 5))

        XCTAssertFalse(spokenTexts.isEmpty)
        XCTAssertFalse(spokenTexts.first?.isEmpty ?? true)
    }
}
