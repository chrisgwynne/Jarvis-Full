import Foundation
import WeatherKit

/// Polls WeatherKit and emits ProactivitySignals for:
///  1. Morning weather briefing (once daily, 7:00–8:00 am)
///  2. Severe weather conditions (storm, blizzard, freezing rain, hurricane) — any time, urgent
///  3. Rain within 2 hours (midday check, once daily) — low priority
///
/// Polls every 15 minutes.
@MainActor
final class WeatherProactivityProvider: ProactivitySignalProvider {
    let source: SignalSource = .system

    private weak var weatherService: WeatherService?
    private weak var engine: ProactivityEngine?
    private weak var appState: AppState?
    private weak var prefs: PreferencesStore?
    private var pollTask: Task<Void, Never>?

    // Severe weather dedup — tracks condition descriptions already announced.
    // Reset at start-of-day below.
    private var announcedSevereConditions: Set<String> = []
    private var lastDayChecked = Calendar.current.startOfDay(for: Date())

    init(weatherService: WeatherService,
         engine: ProactivityEngine,
         appState: AppState,
         prefs: PreferencesStore) {
        self.weatherService = weatherService
        self.engine         = engine
        self.appState       = appState
        self.prefs          = prefs
    }

    /// True when a date was already fired today.  Uses calendar-day
    /// comparison so DST / timezone shifts don't re-fire mid-day.
    private func firedToday(_ date: Date?) -> Bool {
        guard let date else { return false }
        return Calendar.current.isDate(date, inSameDayAs: Date())
    }

    func start() {
        pollTask = Task {
            while !Task.isCancelled {
                await pollNow()
                try? await Task.sleep(for: .seconds(900)) // every 15 minutes
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func pollNow() async {
        guard let weather = weatherService else { return }

        // Reset the (in-memory) severe-weather dedup at midnight.  The
        // morning/rain flags now live in PreferencesStore so they survive
        // launches naturally.
        let today = Calendar.current.startOfDay(for: Date())
        if today > lastDayChecked {
            announcedSevereConditions.removeAll()
            lastDayChecked = today
        }

        let comps  = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let hour   = comps.hour ?? 0

        // ── 1. Morning briefing (7:00–8:00 am, once per day) ──────────────────
        if hour == 7 && !firedToday(prefs?.current.lastMorningBriefingDate) {
            let spoken = await weather.spokenCurrentWeather()
            if !spoken.contains("couldn't get") {
                prefs?.update { $0.lastMorningBriefingDate = Date() }
                let signal = ProactivitySignal(
                    source: .system,
                    title: "Morning weather briefing",
                    body: spoken,
                    category: "weather_morning",
                    priority: .normal,
                    dedupeKey: "weather.morning.\(today.timeIntervalSince1970)",
                    spokenText: spoken,
                    requiresAttention: false
                )
                ProactivityOrchestrator.shared.providerPublish(signal: signal)
            }
        }

        // ── 2. Severe weather check (any time) ────────────────────────────────
        await checkSevereWeather(weather: weather)

        // ── 3. Midday rain warning (once daily, before noon) ──────────────────
        if hour < 12 && !firedToday(prefs?.current.lastRainWarningDate) {
            await checkRainWarning(weather: weather, today: today)
        }
    }

    // MARK: - Helpers

    private func checkSevereWeather(weather: WeatherService) async {
        guard let current = weather.lastWeather else {
            await weather.fetchWeather()
            guard let current = weather.lastWeather else { return }
            emitIfSevere(current)
            return
        }
        emitIfSevere(current)
    }

    private func emitIfSevere(_ current: CurrentWeather) {
        let severeConditions: Set<WeatherCondition> = [
            .heavySnow, .blizzard, .freezingRain, .freezingDrizzle,
            .hurricane, .tropicalStorm, .hail, .sleet,
            .thunderstorms, .isolatedThunderstorms, .scatteredThunderstorms,
            .strongStorms
        ]

        guard severeConditions.contains(current.condition) else { return }

        let conditionKey = current.condition.rawValue
        guard !announcedSevereConditions.contains(conditionKey) else { return }

        announcedSevereConditions.insert(conditionKey)

        let condDescription = current.condition.description
        let spoken = "Severe weather alert: \(condDescription). Please take care."
        let signal = ProactivitySignal(
            source: .system,
            title: "Severe weather: \(condDescription)",
            body: "Current conditions are hazardous",
            category: "weather_severe",
            priority: .urgent,
            dedupeKey: "weather.severe.\(conditionKey).\(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)",
            spokenText: spoken,
            requiresAttention: true
        )
        ProactivityOrchestrator.shared.providerPublish(signal: signal)
    }

    private func checkRainWarning(weather: WeatherService, today: Date) async {
        let rainResult = await weather.willItRain(tomorrow: false)
        let hasRain = !rainResult.lowercased().contains("no rain")

        guard hasRain else { return }

        prefs?.update { $0.lastRainWarningDate = Date() }
        let signal = ProactivitySignal(
            source: .system,
            title: "Rain expected today",
            body: rainResult,
            category: "weather_rain",
            priority: .low,
            dedupeKey: "weather.rain.\(today.timeIntervalSince1970)",
            spokenText: rainResult,
            requiresAttention: false
        )
        ProactivityOrchestrator.shared.providerPublish(signal: signal)
    }
}
