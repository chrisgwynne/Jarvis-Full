import Foundation
import Observation

// MARK: - Timer Entry

struct JarvisTimer: Identifiable {
    let id: UUID
    let name: String          // "pasta", "workout", or auto-generated "Timer 1"
    let duration: TimeInterval
    let startedAt: Date
    var isCancelled: Bool = false
    var firedAt: Date? = nil

    var remaining: TimeInterval {
        max(0, duration - Date().timeIntervalSince(startedAt))
    }

    var isExpired: Bool { remaining <= 0 && firedAt == nil && !isCancelled }
    var isActive: Bool { !isCancelled && firedAt == nil && remaining > 0 }

    var displayRemaining: String {
        let secs = Int(remaining)
        if secs >= 3600 {
            return String(format: "%d:%02d:%02d", secs/3600, (secs%3600)/60, secs%60)
        }
        return String(format: "%d:%02d", secs/60, secs%60)
    }
}

// MARK: - Stopwatch

struct JarvisStopwatch {
    var startedAt: Date?
    var stoppedAt: Date?
    var isRunning: Bool { startedAt != nil && stoppedAt == nil }

    var elapsed: TimeInterval {
        guard let start = startedAt else { return 0 }
        return (stoppedAt ?? Date()).timeIntervalSince(start)
    }

    var displayElapsed: String {
        let secs = Int(elapsed)
        return String(format: "%d:%02d:%02d", secs/3600, (secs%3600)/60, secs%60)
    }
}

// MARK: - TimerService

@Observable
@MainActor
final class TimerService {

    private(set) var timers: [JarvisTimer] = []
    private(set) var stopwatch = JarvisStopwatch()
    var onTimerExpired: ((JarvisTimer) -> Void)?

    private var tickTask: Task<Void, Never>?

    func start() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s tick
                await MainActor.run { self?.checkExpired() }
            }
        }
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
    }

    // MARK: - Timer management

    func setTimer(name: String? = nil, seconds: TimeInterval) -> JarvisTimer {
        let timerName = name ?? autoName()
        let timer = JarvisTimer(id: UUID(), name: timerName, duration: seconds, startedAt: Date())
        timers.append(timer)
        return timer
    }

    @discardableResult
    func cancelTimer(named name: String) -> Bool {
        guard let idx = timers.firstIndex(where: {
            $0.name.lowercased() == name.lowercased() && $0.isActive
        }) else { return false }
        timers[idx].isCancelled = true
        return true
    }

    func cancelAllTimers() {
        for idx in timers.indices { timers[idx].isCancelled = true }
    }

    func activeTimers() -> [JarvisTimer] {
        timers.filter { $0.isActive }
    }

    func firstActive() -> JarvisTimer? {
        timers.first(where: { $0.isActive })
    }

    // MARK: - Stopwatch

    func startStopwatch() { stopwatch = JarvisStopwatch(startedAt: Date(), stoppedAt: nil) }
    func stopStopwatchTimer() { stopwatch.stoppedAt = Date() }
    func resetStopwatch() { stopwatch = JarvisStopwatch() }

    // MARK: - Private

    private func checkExpired() {
        for idx in timers.indices {
            if timers[idx].isExpired {
                timers[idx].firedAt = Date()
                onTimerExpired?(timers[idx])
            }
        }
        // Prune old completed timers (keep last 10)
        let done = timers.filter { !$0.isActive }
        if done.count > 10 {
            timers = timers.filter { $0.isActive } + Array(done.suffix(10))
        }
    }

    private func autoName() -> String {
        let count = timers.filter { !$0.isCancelled }.count + 1
        return "Timer \(count)"
    }
}
