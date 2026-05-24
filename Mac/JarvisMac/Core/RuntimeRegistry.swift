import Foundation

// MARK: - RuntimeRegistry
//
// Thin shell conformances for each major runtime domain.
// These do NOT duplicate logic from existing services — they delegate
// health checks to AppState (the single source of truth for device readiness)
// and implement start/stop as no-ops (JarvisController owns the actual
// service lifecycle during bootstrap).
//
// Startup order gaps are intentional — new subsystems can slot in.

// MARK: - SystemRuntime (order 10)

/// Covers SystemBus, EventStore, PreferencesStore.
final class SystemRuntime: RuntimeSubsystem {
    let id = "system"
    let displayName = "System Runtime"
    let startupOrder = 10
    private(set) var state: RuntimeState = .stopped

    private weak var appState: AppState?
    init(appState: AppState) { self.appState = appState }

    func start() async throws {
        // EventStore must be subscribed to SystemBus before we report .running,
        // so the ring buffer captures every event published during the rest of
        // bootstrap. EventStore.start() is idempotent (guarded by busToken check)
        // so a double-call from recovery is safe and will not create duplicate
        // subscriptions.
        EventStore.shared.start()
        state = .running
    }

    func stop() async {
        EventStore.shared.stop()
        state = .stopped
    }

    func healthCheck() async -> HealthStatus {
        .healthy
    }
}

// MARK: - MemoryRuntime (order 20)

final class MemoryRuntime: RuntimeSubsystem {
    let id = "memory"
    let displayName = "Memory Runtime"
    let startupOrder = 20
    private(set) var state: RuntimeState = .stopped

    func start() async throws { state = .running }
    func stop() async { state = .stopped }

    func healthCheck() async -> HealthStatus {
        .healthy
    }
}

// MARK: - AudioRuntime (order 30)

final class AudioRuntime: RuntimeSubsystem {
    let id = "audio"
    let displayName = "Audio Runtime"
    let startupOrder = 30
    private(set) var state: RuntimeState = .stopped

    private weak var appState: AppState?
    init(appState: AppState) { self.appState = appState }

    func start() async throws { state = .running }
    func stop() async { state = .stopped }

    func healthCheck() async -> HealthStatus {
        guard let appState else { return .degraded("AppState deallocated") }
        switch appState.microphoneStatus {
        case .ready:
            return .healthy
        case .denied:
            return .failed("Microphone permission denied")
        case .failed(let reason):
            return .failed("Microphone: \(reason)")
        case .unavailable(let reason):
            return .degraded("Microphone unavailable: \(reason)")
        case .unknown:
            return .degraded("Microphone status unknown")
        }
    }
}

// ConversationRuntime (order 40) is defined in ConversationRuntime.swift — full class.

// MARK: - OverlayRuntime (order 50)

final class OverlayRuntime: RuntimeSubsystem {
    let id = "overlay"
    let displayName = "Overlay Runtime"
    let startupOrder = 50
    private(set) var state: RuntimeState = .stopped

    func start() async throws { state = .running }
    func stop() async { state = .stopped }

    func healthCheck() async -> HealthStatus { .healthy }
}

// MARK: - AmbientRuntime (order 60)

final class AmbientRuntime: RuntimeSubsystem {
    let id = "ambient"
    let displayName = "Ambient Runtime"
    let startupOrder = 60
    private(set) var state: RuntimeState = .stopped

    func start() async throws { state = .running }
    func stop() async { state = .stopped }

    func healthCheck() async -> HealthStatus { .healthy }
}

// MARK: - LLMRuntime (order 70)

final class LLMRuntime: RuntimeSubsystem {
    let id = "llm"
    let displayName = "LLM Runtime"
    let startupOrder = 70
    private(set) var state: RuntimeState = .stopped

    private weak var appState: AppState?
    init(appState: AppState) { self.appState = appState }

    func start() async throws { state = .running }
    func stop() async { state = .stopped }

    func healthCheck() async -> HealthStatus {
        guard let appState else { return .degraded("AppState deallocated") }
        if let err = appState.llmLastError, !err.isEmpty {
            return .degraded("Last LLM error: \(err.prefix(80))")
        }
        return .healthy
    }
}

// MARK: - ProactivityRuntime (order 80)

final class ProactivityRuntime: RuntimeSubsystem {
    let id = "proactivity"
    let displayName = "Proactivity Runtime"
    let startupOrder = 80
    private(set) var state: RuntimeState = .stopped

    func start() async throws { state = .running }
    func stop() async { state = .stopped }

    func healthCheck() async -> HealthStatus { .healthy }
}

// MARK: - AndroidRuntime (order 90)

final class AndroidRuntime: RuntimeSubsystem {
    let id = "android"
    let displayName = "Android Runtime"
    let startupOrder = 90
    private(set) var state: RuntimeState = .stopped

    private weak var appState: AppState?
    init(appState: AppState) { self.appState = appState }

    func start() async throws { state = .running }
    func stop() async { state = .stopped }

    func healthCheck() async -> HealthStatus {
        // Android bridge is optional — unconnected is not a failure
        return .healthy
    }
}
