import XCTest
@testable import JarvisMac

// MARK: - RuntimeRecoveryTests
//
// Verifies the coordinator-driven recovery loop actually recovers:
//   1. A failed health check triggers recover() on recoverable subsystems.
//   2. Recovery success is only declared when post-recovery health confirms
//      it (regression guard: the no-op shell recover() used to "succeed"
//      every cycle, resetting the retry budget and publishing a false
//      SubsystemRecoveredEvent forever).
//   3. The retry budget is bounded.
//   4. Non-recoverable subsystems are reported, not restarted.

@MainActor
final class RuntimeRecoveryTests: XCTestCase {

    // MARK: Fake subsystem

    private final class FakeSubsystem: RuntimeSubsystem {
        let id: String
        let displayName = "Fake"
        let startupOrder = 999
        private(set) var state: RuntimeState = .running
        let canRecoverIndependently: Bool

        /// Health returned by the next checks.
        var health: HealthStatus = .healthy
        /// When true, recover() flips health back to .healthy (a real fix).
        var recoverActuallyFixes = true
        /// When non-nil, recover() throws this.
        var recoverError: Error?

        private(set) var recoverCallCount = 0

        init(id: String, canRecover: Bool = true) {
            self.id = id
            self.canRecoverIndependently = canRecover
        }

        func start() async throws { state = .running }
        func stop() async { state = .stopped }
        func healthCheck() async -> HealthStatus { health }
        func recover() async throws {
            recoverCallCount += 1
            if let recoverError { throw recoverError }
            if recoverActuallyFixes { health = .healthy }
        }
    }

    private func makeCoordinator() -> RuntimeCoordinator {
        let coordinator = RuntimeCoordinator()
        coordinator.stopHealthMonitor()  // tests drive runHealthChecks() directly
        return coordinator
    }

    // MARK: Tests

    func testFailedHealthTriggersRecovery() async {
        let coordinator = makeCoordinator()
        let subsystem = FakeSubsystem(id: "fake-audio")
        coordinator.register(subsystem)

        subsystem.health = .failed("engine wedged")
        await coordinator.runHealthChecks()

        XCTAssertEqual(subsystem.recoverCallCount, 1, "failed subsystem must be recovered")
        XCTAssertEqual(coordinator.lastHealthSnapshot["fake-audio"], .healthy,
            "post-recovery health must be re-checked and recorded")
        XCTAssertEqual(coordinator.restartCounts["fake-audio"], 0,
            "successful recovery resets the retry budget")
    }

    func testIneffectiveRecoveryDoesNotResetRetryBudgetOrDeclareSuccess() async {
        let coordinator = makeCoordinator()
        let subsystem = FakeSubsystem(id: "fake-audio")
        subsystem.recoverActuallyFixes = false  // recover() returns but fixes nothing
        coordinator.register(subsystem)

        subsystem.health = .failed("permission denied")
        await coordinator.runHealthChecks()

        XCTAssertEqual(subsystem.recoverCallCount, 1)
        XCTAssertEqual(coordinator.restartCounts["fake-audio"], 1,
            "an ineffective recover() must consume retry budget, not reset it")
        XCTAssertEqual(coordinator.lastHealthSnapshot["fake-audio"], .failed("permission denied"))
    }

    func testRetryBudgetIsBounded() async {
        let coordinator = makeCoordinator()
        let subsystem = FakeSubsystem(id: "fake-audio")
        subsystem.recoverActuallyFixes = false
        coordinator.register(subsystem)
        subsystem.health = .failed("stuck")

        // Drive more health cycles than the budget allows.
        for _ in 0..<(coordinator.maxRestartAttempts + 3) {
            await coordinator.runHealthChecks()
        }

        XCTAssertEqual(subsystem.recoverCallCount, coordinator.maxRestartAttempts,
            "recover() must stop being called once the budget is exhausted")
    }

    func testThrowingRecoveryConsumesBudget() async {
        let coordinator = makeCoordinator()
        let subsystem = FakeSubsystem(id: "fake-audio")
        subsystem.recoverError = RuntimeRecoveryError.requiresUserAction("mic permission")
        coordinator.register(subsystem)
        subsystem.health = .failed("Microphone permission denied")

        for _ in 0..<(coordinator.maxRestartAttempts + 2) {
            await coordinator.runHealthChecks()
        }

        XCTAssertEqual(subsystem.recoverCallCount, coordinator.maxRestartAttempts,
            "unrecoverable failures must exhaust the bounded budget, then stop")
    }

    func testNonRecoverableSubsystemIsNeverRestarted() async {
        let coordinator = makeCoordinator()
        let subsystem = FakeSubsystem(id: "fake-core", canRecover: false)
        coordinator.register(subsystem)

        subsystem.health = .failed("broken")
        await coordinator.runHealthChecks()

        XCTAssertEqual(subsystem.recoverCallCount, 0,
            "canRecoverIndependently == false must bypass recovery entirely")
    }

    func testRecoveryAfterTransientFailureRestoresReadiness() async {
        let coordinator = makeCoordinator()
        let subsystem = FakeSubsystem(id: "fake-audio")
        coordinator.register(subsystem)
        coordinator.markReady()
        coordinator.stopHealthMonitor()

        subsystem.health = .failed("transient")
        await coordinator.runHealthChecks()
        XCTAssertEqual(coordinator.lastHealthSnapshot["fake-audio"], .healthy)

        await coordinator.runHealthChecks()
        XCTAssertEqual(coordinator.readiness, .ready,
            "readiness must return to .ready once the subsystem is healthy again")
    }

    // MARK: AudioRuntime specifics

    func testAudioRuntimeRecoverInvokesWiredRepairAction() async throws {
        let appState = AppState()
        appState.microphoneStatus = .ready
        let audio = AudioRuntime(appState: appState)
        var repaired = false
        audio.onRecover = { repaired = true }

        try await audio.recover()
        XCTAssertTrue(repaired, "recover() must run the wired rebuildWakeWord action")
    }

    func testAudioRuntimeRecoverThrowsWhenMicPermissionDenied() async {
        let appState = AppState()
        appState.microphoneStatus = .denied
        let audio = AudioRuntime(appState: appState)
        var repaired = false
        audio.onRecover = { repaired = true }

        do {
            try await audio.recover()
            XCTFail("mic-denied recovery must throw — it needs the user, not a retry loop")
        } catch {
            XCTAssertFalse(repaired, "repair action must not run when permission is denied")
        }
    }

    func testAudioRuntimeHealthSeesWakeWordFailure() async {
        let appState = AppState()
        appState.microphoneStatus = .ready
        appState.listeningEnabled = true
        appState.wakeWordStatus = .failed("engine died")
        let audio = AudioRuntime(appState: appState)

        let health = await audio.healthCheck()
        XCTAssertEqual(health, .failed("Wake word: engine died"),
            "a dead wake-word engine is the recoverable failure the coordinator must see")
    }
}
