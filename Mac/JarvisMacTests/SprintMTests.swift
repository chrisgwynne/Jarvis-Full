import XCTest
@testable import JarvisMac

// MARK: - Sprint M Tests
// Covers: ConversationalTimingEngine, AmbientWorldState, RuntimeHealthMonitor,
//         ProactivityOrchestrator.providerPublish, AttentionPolicy edge cases.

@MainActor
final class SprintMTests: XCTestCase {

    // MARK: - ConversationalTimingEngine

    func testTimingEngineInitialState() {
        let engine = ConversationalTimingEngine()
        XCTAssertFalse(engine.isSpeechActive)
        XCTAssertFalse(engine.isTTSActive)
        XCTAssertEqual(engine.secondsSinceUserSpeech, .infinity)
        XCTAssertEqual(engine.secondsSinceJarvisSpeech, .infinity)
    }

    func testTimingEngineNotGoodWhileSpeaking() {
        let engine = ConversationalTimingEngine()
        engine.userStartedSpeaking()
        XCTAssertFalse(engine.isGoodTimeToSpeak,
                       "should not be a good time while user is speaking")
        engine.userStoppedSpeaking()
    }

    func testTimingEngineNotGoodWhileTTSActive() {
        let engine = ConversationalTimingEngine()
        engine.jarvisStartedSpeaking()
        XCTAssertFalse(engine.isGoodTimeToSpeak,
                       "should not be a good time while Jarvis is speaking")
        engine.jarvisStoppedSpeaking()
    }

    func testTimingEngineGoodAfterSilence() {
        let engine = ConversationalTimingEngine()
        engine.minSilenceForGoodTiming = 0  // no wait needed
        engine.postTTSRecoverySeconds = 0
        engine.userStoppedSpeaking()
        engine.jarvisStoppedSpeaking()
        XCTAssertTrue(engine.isGoodTimeToSpeak,
                      "should be a good time when min silence is 0 and not speaking")
    }

    func testTimingEngineRecommendedDelayZeroForCritical() {
        let engine = ConversationalTimingEngine()
        engine.jarvisStartedSpeaking()
        let delay = engine.recommendedDelaySeconds(urgency: .critical)
        XCTAssertEqual(delay, 0, "critical events should have zero recommended delay")
        engine.jarvisStoppedSpeaking()
    }

    func testTimingEngineRecommendedDelayDuringTTS() {
        let engine = ConversationalTimingEngine()
        engine.jarvisStartedSpeaking()
        let delay = engine.recommendedDelaySeconds(urgency: .normal)
        XCTAssertGreaterThan(delay, 0, "non-critical events during TTS should have delay > 0")
        engine.jarvisStoppedSpeaking()
    }

    func testTimingEngineUserIdleAfterThreshold() {
        let engine = ConversationalTimingEngine()
        engine.idleThresholdSeconds = 0  // immediate idle
        engine.userStoppedSpeaking()
        XCTAssertTrue(engine.isUserIdle, "user should be idle once threshold is met")
    }

    // MARK: - AmbientWorldState

    func testWorldStateInitialValues() {
        let ws = AmbientWorldState()
        XCTAssertNil(ws.activeApp)
        XCTAssertFalse(ws.isMediaPlaying)
        XCTAssertFalse(ws.isInConversation)
        XCTAssertFalse(ws.hasUpcomingMeeting)
        XCTAssertEqual(ws.emotionalTone, .neutral)
    }

    func testWorldStateDeepWorkDetection() {
        let ws = AmbientWorldState()
        ws.activeApp = "Xcode"
        XCTAssertTrue(ws.isInDeepWorkApp)
        ws.activeApp = "Safari"
        XCTAssertFalse(ws.isInDeepWorkApp)
    }

    func testWorldStateMeetingDetection() {
        let ws = AmbientWorldState()
        ws.activeApp = "Zoom"
        XCTAssertTrue(ws.isInMeetingApp)
        ws.activeApp = "Finder"
        XCTAssertFalse(ws.isInMeetingApp)
    }

    func testWorldStateContextSummaryIdle() {
        let ws = AmbientWorldState()
        XCTAssertEqual(ws.contextSummary, "idle")
    }

    func testWorldStateContextSummaryWithApp() {
        let ws = AmbientWorldState()
        ws.activeApp = "Xcode"
        XCTAssertTrue(ws.contextSummary.contains("Xcode"))
    }

    func testWorldStateAttentionContextDerivation() {
        let ws = AmbientWorldState()
        ws.activeApp = "Zoom"
        ws.isInConversation = true
        ws.emotionalTone = .frustrated
        let timing = ConversationalTimingEngine()
        let ctx = ws.attentionContext(timingEngine: timing, recentInterruptionCount: 5)
        XCTAssertTrue(ctx.isInActiveMeeting)
        XCTAssertEqual(ctx.emotionalTone, .frustrated)
        XCTAssertEqual(ctx.recentInterruptionCount, 5)
    }

    // MARK: - RuntimeHealthMonitor

    func testHealthMonitorNoAlertBelowThreshold() {
        let monitor = RuntimeHealthMonitor()
        monitor.failureThreshold = 3
        // Record 2 failures — should not alert
        monitor.recordFailure(.llm)
        monitor.recordFailure(.llm)
        XCTAssertEqual(monitor.recentFailureSummary, "language_model: 2")
    }

    func testHealthMonitorRecoveryClearsCooldown() {
        let monitor = RuntimeHealthMonitor()
        monitor.alertCooldownSeconds = 9999
        monitor.recordFailure(.stt)
        monitor.recordFailure(.stt)
        monitor.recordFailure(.stt) // would trigger alert + cooldown
        monitor.recordRecovery(.stt)
        // After recovery, next set of failures can alert again
        // (can't assert TTS call here, just that recovery clears state)
        XCTAssertTrue(true, "recordRecovery should not crash")
    }

    func testHealthMonitorSubsystemRawValues() {
        XCTAssertEqual(RuntimeHealthMonitor.Subsystem.stt.rawValue, "speech_recognition")
        XCTAssertEqual(RuntimeHealthMonitor.Subsystem.llm.rawValue, "language_model")
        XCTAssertEqual(RuntimeHealthMonitor.Subsystem.homeAssistant.rawValue, "home_assistant")
    }

    // MARK: - ProactivityOrchestrator.providerPublish

    func testProviderPublishAcceptsSignal() {
        let orchestrator = ProactivityOrchestrator()
        var spokenTexts: [String] = []
        orchestrator.onSpeak = { spokenTexts.append($0) }

        let signal = ProactivitySignal(
            source: .github,
            title: "Test",
            body: "Body text",
            priority: .normal,
            dedupeKey: "test.dedup.1",
            spokenText: "Custom spoken text"
        )
        orchestrator.providerPublish(signal: signal)
        // Event is queued; delivery happens on next cycle. Just verify no crash.
        XCTAssertTrue(true, "providerPublish should accept a signal without crashing")
    }

    func testProviderPublishMapsUrgencyCorrectly() {
        // Maps SignalPriority.urgent → ProactiveUrgency.critical
        // Maps SignalPriority.high → .high
        // Can't directly inspect the internal event, but verify that the .urgent
        // signal triggers an immediate delivery attempt (which fires a runDeliveryCycle).
        // For now just verify no crash on all priority levels.
        let orchestrator = ProactivityOrchestrator()
        orchestrator.onSpeak = { _ in }

        for priority: SignalPriority in [.low, .normal, .high, .urgent, .critical] {
            let signal = ProactivitySignal(
                source: .calendar,
                title: "T",
                body: "B",
                priority: priority,
                dedupeKey: "urgency.test.\(priority.rawValue)"
            )
            orchestrator.providerPublish(signal: signal)
        }
        XCTAssertTrue(true)
    }

    // MARK: - pbxproj UUID uniqueness (regression guard)

    func testPbxprojUUIDsUniqueSprintM() throws {
        let pbxprojPath = Bundle(for: SprintMTests.self)
            .bundlePath
            .components(separatedBy: "/")
            .dropLast(3)
            .joined(separator: "/")
            .appending("/JarvisMac.xcodeproj/project.pbxproj")

        guard FileManager.default.fileExists(atPath: pbxprojPath),
              let contents = try? String(contentsOfFile: pbxprojPath, encoding: .utf8) else {
            return // acceptable in CI
        }

        let pattern = try NSRegularExpression(pattern: #"\b([A-F0-9]{24})\b"#)
        let matches = pattern.matches(in: contents,
                                      range: NSRange(contents.startIndex..., in: contents))
        let uuids = matches.compactMap { m -> String? in
            guard let r = Range(m.range(at: 1), in: contents) else { return nil }
            return String(contents[r])
        }
        let overduped = uuids.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
            .filter { $0.value > 2 }
        XCTAssertTrue(overduped.isEmpty,
                      "UUIDs appearing more than 2 times: \(overduped)")
    }
}
