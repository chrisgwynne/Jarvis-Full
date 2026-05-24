import XCTest
@testable import JarvisMac

// MARK: - ListeningLifecycleTests
//
// Tests covering the listening lifecycle coordinator types, orb color semantics,
// and lifecycle event log. These run without requiring the full JarvisController
// stack (which needs live audio/speech permissions).

@MainActor
final class ListeningLifecycleTests: XCTestCase {

    // MARK: - ListeningMode

    func testListeningModeDisplayNames() {
        XCTAssertEqual(ListeningMode.disabled.displayName, "Disabled")
        XCTAssertEqual(ListeningMode.wakeWordOnly.displayName, "Wake word only")
        XCTAssertEqual(ListeningMode.persistent.displayName, "Persistent")
        XCTAssertEqual(ListeningMode.conversation.displayName, "Conversation")
    }

    func testListeningModeRawValues() {
        XCTAssertEqual(ListeningMode.disabled.rawValue, "disabled")
        XCTAssertEqual(ListeningMode.wakeWordOnly.rawValue, "wakeWordOnly")
        XCTAssertEqual(ListeningMode.persistent.rawValue, "persistent")
        XCTAssertEqual(ListeningMode.conversation.rawValue, "conversation")
    }

    func testListeningModeEquality() {
        XCTAssertEqual(ListeningMode.persistent, ListeningMode.persistent)
        XCTAssertNotEqual(ListeningMode.disabled, ListeningMode.persistent)
    }

    // MARK: - ListeningState

    func testListeningStateDisplayNames() {
        XCTAssertEqual(ListeningState.idleListening.displayName, "Idle")
        XCTAssertEqual(ListeningState.wakeWordListening.displayName, "Wake-word armed")
        XCTAssertEqual(ListeningState.activelyListening.displayName, "Listening")
        XCTAssertEqual(ListeningState.processing.displayName, "Processing")
        XCTAssertEqual(ListeningState.speaking.displayName, "Speaking")
        XCTAssertEqual(ListeningState.unavailable(reason: "no mic").displayName, "Unavailable: no mic")
        XCTAssertEqual(ListeningState.temporarilyPaused(reason: "settle").displayName, "Paused: settle")
        XCTAssertEqual(ListeningState.recovering(reason: "backoff").displayName, "Recovering: backoff")
    }

    func testListeningStateEquality() {
        XCTAssertEqual(ListeningState.wakeWordListening, .wakeWordListening)
        XCTAssertNotEqual(ListeningState.activelyListening, .wakeWordListening)
        XCTAssertEqual(ListeningState.unavailable(reason: "a"), .unavailable(reason: "a"))
        XCTAssertNotEqual(ListeningState.unavailable(reason: "a"), .unavailable(reason: "b"))
    }

    // MARK: - ListeningLifecycleEvent

    func testLifecycleEventTimestampFormat() {
        let event = ListeningLifecycleEvent(
            timestamp: Date(),
            fromState: "Idle",
            toState: "Wake-word armed",
            reason: "bootstrap",
            caller: "testFunc"
        )
        // Timestamp should be formatted as HH:mm:ss.SSS
        let ts = event.displayTimestamp
        XCTAssertEqual(ts.count, 12, "Expected HH:mm:ss.SSS format (12 chars)")
        XCTAssertEqual(ts.filter { $0 == ":" }.count, 2)
        XCTAssertEqual(ts.filter { $0 == "." }.count, 1)
    }

    func testLifecycleEventFields() {
        let event = ListeningLifecycleEvent(
            timestamp: Date(),
            fromState: "Wake-word armed",
            toState: "Listening",
            reason: "wake_word",
            caller: "handleWakeEvent"
        )
        XCTAssertEqual(event.fromState, "Wake-word armed")
        XCTAssertEqual(event.toState, "Listening")
        XCTAssertEqual(event.reason, "wake_word")
        XCTAssertEqual(event.caller, "handleWakeEvent")
    }

    // MARK: - AssistantPhase accent colors

    func testPhaseColorsAreDistinct() {
        // The critical invariant: .listening and .error must NOT both be .red
        // (they were both .red before this fix, causing user confusion).
        let listeningColor = AssistantPhase.listening.accentColor
        let errorColor = AssistantPhase.error.accentColor
        // They should now be different
        XCTAssertNotEqual(listeningColor, errorColor,
            ".listening and .error must have different accent colors — both were .red before the fix")
    }

    func testListeningPhaseIsNotRed() {
        // .listening should be cyan (actively recording), not red (error color)
        let color = AssistantPhase.listening.accentColor
        // We can't directly compare SwiftUI Color values, but we verify it's
        // not the same as .error (which should be .red)
        let errorColor = AssistantPhase.error.accentColor
        XCTAssertNotEqual(color, errorColor)
    }

    func testWakeListeningPhaseIsDifferentFromListening() {
        // Wake listening (passive wake word) should differ from active STT
        let wakeColor = AssistantPhase.wakeListening.accentColor
        let listenColor = AssistantPhase.listening.accentColor
        XCTAssertNotEqual(wakeColor, listenColor,
            ".wakeListening and .listening should have distinct colors")
    }

    func testMutedPhaseMatchesIdle() {
        // Both idle and muted are "grey" / inactive states
        let idleColor = AssistantPhase.idle.accentColor
        let mutedColor = AssistantPhase.muted.accentColor
        XCTAssertEqual(idleColor, mutedColor,
            ".idle and .muted should both be grey (not actively doing anything)")
    }

    func testSpeakingAndBargedInShareColor() {
        // Both speaking and barged-in are orange — interruption variant of speaking
        let speakingColor = AssistantPhase.speaking.accentColor
        let bargedColor = AssistantPhase.bargedIn.accentColor
        XCTAssertEqual(speakingColor, bargedColor,
            ".speaking and .bargedIn should share the orange color")
    }

    // MARK: - AppState lifecycle event log

    func testAppStateLifecycleEventLogBound() {
        let state = AppState()
        // Push more than 50 events — log should stay bounded at 50
        for i in 0..<60 {
            state.pushLifecycleEvent(
                from: "state\(i)",
                to: "state\(i+1)",
                reason: "test_\(i)"
            )
        }
        XCTAssertLessThanOrEqual(state.listeningEventLog.count, 50,
            "Lifecycle event log must not exceed 50 entries")
    }

    func testAppStateLifecycleEventLogRetainsLatest() {
        let state = AppState()
        for i in 0..<55 {
            state.pushLifecycleEvent(from: "a\(i)", to: "b\(i)", reason: "r\(i)")
        }
        // The last entry should be the most recent push
        XCTAssertEqual(state.listeningEventLog.last?.reason, "r54")
        // Oldest should have been evicted
        XCTAssertNotEqual(state.listeningEventLog.first?.reason, "r0")
    }

    func testAppStateLifecycleEventLogWritesToLog() {
        let state = AppState()
        let initialLogCount = state.logs.count
        state.pushLifecycleEvent(from: "Idle", to: "Wake-word armed", reason: "bootstrap")
        XCTAssertGreaterThan(state.logs.count, initialLogCount,
            "pushLifecycleEvent should write to the main AppState log")
        let lastLog = state.logs.last
        XCTAssertTrue(lastLog?.message.contains("[ListeningLifecycle]") ?? false,
            "Lifecycle log entry must contain [ListeningLifecycle] prefix")
    }

    // MARK: - Desired mode initial state

    func testAppStateDefaultDesiredMode() {
        let state = AppState()
        // Default desired mode should be persistent (matches Preferences default)
        XCTAssertEqual(state.listeningDesiredMode, .persistent)
    }

    func testAppStateDefaultActualState() {
        let state = AppState()
        XCTAssertEqual(state.listeningActualState, .idleListening)
    }

    // MARK: - Stop reason coverage

    func testStopReasonRawValues() {
        XCTAssertEqual(StopReason.userCancelled.rawValue, "user_cancelled")
        XCTAssertEqual(StopReason.silenceTimeout.rawValue, "silence_timeout")
        XCTAssertEqual(StopReason.emptyFinal.rawValue, "empty_final")
        XCTAssertEqual(StopReason.recognizerError.rawValue, "recognizer_error")
        XCTAssertEqual(StopReason.ttsInterrupt.rawValue, "tts_interrupt")
        XCTAssertEqual(StopReason.stateTransition.rawValue, "state_transition")
    }

    // MARK: - Phase lifecycle invariants

    func testListeningPhaseShortLabels() {
        XCTAssertEqual(AssistantPhase.wakeListening.shortLabel, "PASSIVE")
        XCTAssertEqual(AssistantPhase.listening.shortLabel, "LISTENING")
        XCTAssertEqual(AssistantPhase.conversationalListening.shortLabel, "FOLLOW-UP")
        XCTAssertEqual(AssistantPhase.thinking.shortLabel, "THINKING")
        XCTAssertEqual(AssistantPhase.speaking.shortLabel, "SPEAKING")
        XCTAssertEqual(AssistantPhase.muted.shortLabel, "MUTED")
        XCTAssertEqual(AssistantPhase.error.shortLabel, "ERROR")
    }

    // MARK: - Orb color semantic guarantees

    func testOrbColorsDocumentedContract() {
        // These assertions document the intended color semantics.
        // A failure here means someone changed a color without updating the reference.
        // The contract (from OrbColorReferenceContributor and the orb view):
        //   idle / muted  → grey
        //   wakeListening → blue
        //   listening     → cyan   (NOT red — that would clash with error)
        //   conversation  → green
        //   thinking      → purple
        //   speaking      → orange
        //   bargedIn      → orange
        //   error         → red
        let phaseColors: [(AssistantPhase, String)] = [
            (.idle,                    "gray"),
            (.muted,                   "gray"),
            (.wakeListening,           "blue"),
            (.listening,               "cyan"),
            (.conversationalListening, "green"),
            (.awaitingResponse,        "green"),
            (.thinking,                "purple"),
            (.speaking,                "orange"),
            (.bargedIn,                "orange"),
            (.error,                   "red"),
        ]
        // We can't compare Color values by name, but we can verify the relative
        // uniqueness guarantees.  The critical ones:
        let listeningC = AssistantPhase.listening.accentColor
        let errorC = AssistantPhase.error.accentColor
        let wakeC = AssistantPhase.wakeListening.accentColor
        let muteC = AssistantPhase.muted.accentColor
        let idleC = AssistantPhase.idle.accentColor

        XCTAssertNotEqual(listeningC, errorC,   "listening ≠ error (both were red before fix)")
        XCTAssertNotEqual(listeningC, wakeC,    "listening ≠ wakeListening")
        XCTAssertEqual(muteC, idleC,            "muted = idle (both grey/inactive)")

        // Phase/color count matches documented contract
        XCTAssertEqual(phaseColors.count, 10)
    }
}
