import Foundation
import WeatherKit
import CoreLocation

/// WeatherKit-backed weather service. Requires:
///   - WeatherKit capability in the app's entitlements. Add it in Xcode →
///     target → Signing & Capabilities → + Capability → WeatherKit.
///   - A device/simulator running macOS 13+ (WeatherKit requires macOS 13).
/// Falls back gracefully when WeatherKit is unavailable or location is denied.
@MainActor
final class WeatherService: NSObject, CLLocationManagerDelegate {

    private let locationManager = CLLocationManager()
    private let weatherService = WeatherKit.WeatherService.shared

    private(set) var currentLocation: CLLocation?
    private(set) var isAuthorized = false
    private(set) var lastWeather: CurrentWeather?
    private(set) var lastHourly: Forecast<HourWeather>?
    private(set) var lastDaily: Forecast<DayWeather>?
    private(set) var lastError: String?
    private(set) var locationName: String = "your location"

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    // MARK: - Permission + start

    func requestAccess() {
        locationManager.requestWhenInUseAuthorization()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                self.isAuthorized = true
                self.locationManager.requestLocation()
            default:
                self.isAuthorized = false
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            self.currentLocation = loc
            await self.reverseGeocode(loc)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.lastError = error.localizedDescription }
    }

    private func reverseGeocode(_ location: CLLocation) async {
        let geocoder = CLGeocoder()
        if let placemarks = try? await geocoder.reverseGeocodeLocation(location),
           let name = placemarks.first?.locality ?? placemarks.first?.administrativeArea {
            locationName = name
        }
    }

    // MARK: - Fetch

    func fetchWeather() async {
        guard let location = currentLocation else {
            locationManager.requestLocation()
            return
        }
        do {
            let weather = try await weatherService.weather(for: location)
            lastWeather = weather.currentWeather
            lastHourly = weather.hourlyForecast
            lastDaily = weather.dailyForecast
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Spoken output

    func spokenCurrentWeather() async -> String {
        if lastWeather == nil { await fetchWeather() }
        guard let w = lastWeather else {
            return "I couldn't get the weather right now."
        }
        let temp = Int(w.temperature.converted(to: .celsius).value)
        let feelsLike = Int(w.apparentTemperature.converted(to: .celsius).value)
        let condition = w.condition.description.lowercased()
        let humidity = Int(w.humidity * 100)
        var result = "It's \(temp)°C in \(locationName), \(condition)."
        if abs(feelsLike - temp) >= 3 {
            result += " Feels like \(feelsLike)°C."
        }
        if humidity > 70 {
            result += " Humidity is \(humidity)%."
        }
        return result
    }

    func spokenForecast(days: Int = 3) async -> String {
        if lastDaily == nil { await fetchWeather() }
        guard let forecast = lastDaily else {
            return "I couldn't get the forecast right now."
        }
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "EEEE"
        let entries = forecast.prefix(days)
        if entries.isEmpty { return "No forecast available." }
        var parts: [String] = []
        for day in entries {
            let name = Calendar.current.isDateInToday(day.date) ? "Today" :
                       Calendar.current.isDateInTomorrow(day.date) ? "Tomorrow" :
                       dayFormatter.string(from: day.date)
            let high = Int(day.highTemperature.converted(to: .celsius).value)
            let low  = Int(day.lowTemperature.converted(to: .celsius).value)
            let cond = day.condition.description.lowercased()
            parts.append("\(name): \(cond), \(low) to \(high)°C")
        }
        return "Forecast for \(locationName): " + parts.joined(separator: ". ")
    }

    func willItRain(tomorrow: Bool = false) async -> String {
        if lastHourly == nil { await fetchWeather() }
        let target = tomorrow ? Calendar.current.date(byAdding: .day, value: 1, to: Date())! : Date()
        let startOfDay = Calendar.current.startOfDay(for: target)
        let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay)!
        guard let hourly = lastHourly else { return "I'm not sure about rain right now." }
        var rainHours: [HourWeather] = []
        for hour in hourly {
            if hour.date >= startOfDay && hour.date < endOfDay &&
               (hour.precipitationChance > 0.3 ||
                [Precipitation.rain, .sleet, .snow, .mixed, .hail].contains(hour.precipitation)) {
                rainHours.append(hour)
            }
        }
        let day = tomorrow ? "tomorrow" : "today"
        if rainHours.isEmpty {
            return "No rain expected \(day)."
        }
        let maxChance = Int((rainHours.map { $0.precipitationChance }.max() ?? 0) * 100)
        return "Rain is likely \(day), with up to \(maxChance)% chance. You might want an umbrella."
    }
}
