import Foundation

// MARK: - TTSBenchmarkRecord

/// Single synthesis benchmark observation.
struct TTSBenchmarkRecord: Identifiable, Codable {
    let id:               UUID
    let backendId:        String
    let backendName:      String
    let textLength:       Int
    let preloadMs:        Int     // warm-up time (0 if preload was skipped)
    let firstAudioMs:     Int     // speak() → first isSpeakingStream true
    let totalPlaybackMs:  Int     // speak() → isSpeakingStream false
    let synthesisDoneMs:  Int     // subprocess/network done (backend-reported)
    let error:            String?
    let timestamp:        Date
    let memoryMB:         Double? // resident memory delta if measured
    let cpuPercent:       Double? // CPU spike if measured

    var succeeded: Bool { error == nil }
}

// MARK: - TTSBenchmarkStore

/// Thread-safe ring buffer of recent benchmark records, capped at 200.
/// Populated by TTSBackendRouter on every synthesis; read by VoiceLabView.
final class TTSBenchmarkStore {
    static let shared = TTSBenchmarkStore()
    private init() {}

    private let lock  = NSLock()
    private var store: [TTSBenchmarkRecord] = []
    private let cap   = 200

    func add(_ record: TTSBenchmarkRecord) {
        lock.lock()
        defer { lock.unlock() }
        store.append(record)
        if store.count > cap { store.removeFirst(store.count - cap) }
    }

    /// All records, newest first.
    func all() -> [TTSBenchmarkRecord] {
        lock.lock()
        defer { lock.unlock() }
        return store.reversed()
    }

    /// Records for a specific backend, newest first.
    func records(for backendId: String) -> [TTSBenchmarkRecord] {
        all().filter { $0.backendId == backendId }
    }

    /// Average first-audio latency for a backend (successful runs only).
    func avgFirstAudioMs(for backendId: String) -> Double? {
        let vals = records(for: backendId)
            .filter(\.succeeded)
            .map { Double($0.firstAudioMs) }
        guard !vals.isEmpty else { return nil }
        return vals.reduce(0, +) / Double(vals.count)
    }

    /// p50 first-audio latency.
    func p50(for backendId: String) -> Int? {
        let vals = records(for: backendId)
            .filter(\.succeeded)
            .map(\.firstAudioMs)
            .sorted()
        guard !vals.isEmpty else { return nil }
        return vals[Int(Double(vals.count) * 0.5)]
    }

    /// p95 first-audio latency.
    func p95(for backendId: String) -> Int? {
        let vals = records(for: backendId)
            .filter(\.succeeded)
            .map(\.firstAudioMs)
            .sorted()
        guard !vals.isEmpty else { return nil }
        return vals[max(0, Int(Double(vals.count) * 0.95) - 1)]
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        store.removeAll()
    }
}
