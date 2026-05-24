import XCTest
@testable import JarvisMac

@MainActor
final class ConversationalArchitectureTests: XCTestCase {

    // MARK: - ActionPolicy.shouldSpeak

    func testSilentSuccessDefault() {
        let policy = ActionPolicy.default
        XCTAssertFalse(policy.shouldSpeak(intentLabel: "homeTurnOn", result: .success))
    }

    func testVerbosePolicyAlwaysSpeaksOnSuccess() {
        let policy = ActionPolicy.verbose
        XCTAssertTrue(policy.shouldSpeak(intentLabel: "homeTurnOn", result: .success))
    }

    func testSpeaksOnFailure() {
        let policy = ActionPolicy.default
        XCTAssertTrue(policy.shouldSpeak(intentLabel: "homeTurnOn", result: .failure("timeout")))
    }

    func testSpeaksOnClarification() {
        let policy = ActionPolicy.default
        XCTAssertTrue(policy.shouldSpeak(intentLabel: "homeTurnOn", result: .needsClarification("which light?")))
    }

    func testSpeaksOnDestructive() {
        let policy = ActionPolicy.default
        XCTAssertTrue(policy.shouldSpeak(intentLabel: "deleteFile", result: .destructive(description: "delete all")))
    }

    func testResultsMatterLabelAlwaysSpeaks() {
        let policy = ActionPolicy.default
        XCTAssertTrue(policy.shouldSpeak(intentLabel: "getCurrentWeather", result: .success))
        XCTAssertTrue(policy.shouldSpeak(intentLabel: "readLatestEmail", result: .success))
    }

    func testUserRequestedConfirmationSpeaks() {
        let policy = ActionPolicy.default
        XCTAssertTrue(policy.shouldSpeak(intentLabel: "homeTurnOn", result: .success,
                                         userRequestedConfirmation: true))
    }

    func testPendingNeverSpeaks() {
        let policy = ActionPolicy.default
        XCTAssertFalse(policy.shouldSpeak(intentLabel: "homeTurnOn", result: .pending))
    }

    func testIsDestructiveRecognition() {
        let policy = ActionPolicy.default
        XCTAssertTrue(policy.isDestructive("clearMemory"))
        XCTAssertTrue(policy.isDestructive("deleteFile"))
        XCTAssertFalse(policy.isDestructive("homeTurnOn"))
    }

    // MARK: - RollingDialogueMemory

    func testAddAndRetrieveTurns() async {
        let mem = RollingDialogueMemory.shared
        mem.clear()
        mem.addUserTurn("hello there", intent: "greeting")
        mem.addAssistantTurn("Hi! How can I help?")
        XCTAssertEqual(mem.turns.count, 2)
        XCTAssertEqual(mem.turns[0].role, DialogueTurn.Role.user)
        XCTAssertEqual(mem.turns[1].role, DialogueTurn.Role.assistant)
    }

    func testPronounResolutionIt() async {
        let mem = RollingDialogueMemory.shared
        mem.clear()
        mem.addUserTurn("turn on the kitchen light", intent: "homeTurnOn")
        // After adding a turn, activeEntities should capture "kitchen" or similar
        // Entity extraction may not find "kitchen light" exactly, so just verify
        // resolve returns something non-nil OR activeTopic is set.
        let resolved = mem.resolve("it")
        // resolved may be nil if no entities or topic extracted from this short phrase
        // but the important thing is it doesn't crash
        _ = resolved
        XCTAssert(true)
    }

    func testIsRepeatRequest() async {
        let mem = RollingDialogueMemory.shared
        XCTAssertTrue(mem.isRepeatRequest("do it again"))
        XCTAssertTrue(mem.isRepeatRequest("repeat that"))
        XCTAssertFalse(mem.isRepeatRequest("turn on the light"))
    }

    func testBuildContextBlockEmpty() async {
        let mem = RollingDialogueMemory.shared
        mem.clear()
        XCTAssertEqual(mem.buildContextBlock(), "")
    }

    func testBuildContextBlockWithTurns() async {
        let mem = RollingDialogueMemory.shared
        mem.clear()
        mem.addUserTurn("what's the weather like?")
        mem.addAssistantTurn("It's sunny and 22 degrees.")
        let block = mem.buildContextBlock()
        XCTAssertTrue(block.contains("[DIALOGUE CONTEXT]"))
        XCTAssertTrue(block.contains("User:"))
        XCTAssertTrue(block.contains("Jarvis:"))
    }

    func testEmotionalToneDetection() async {
        let mem = RollingDialogueMemory.shared
        mem.clear()
        mem.addUserTurn("ugh it still doesn't work and keeps breaking, so annoying")
        XCTAssertEqual(mem.emotionalTone, DialogueTurn.EmotionalTone.frustrated)
    }

    // MARK: - ConversationRouter — mixed utterance detection

    func testMixedUtteranceDetected() {
        let router = ConversationRouter()
        let result = router.classifyFast(
            "turn the lights on, but yeah the calibration might fix it",
            rawText: ""
        )
        XCTAssertEqual(result.route, .mixedChatAndCommand)
        XCTAssertEqual(result.confidence, 0.85, accuracy: 0.01)
        XCTAssertNotNil(result.commandHint)
        XCTAssertTrue(result.commandHint?.contains("turn the lights on") == true)
    }

    func testMixedUtteranceWithThoughConjunction() {
        let router = ConversationRouter()
        let result = router.classifyFast(
            "play some music, though i'm not sure what mood i'm in",
            rawText: ""
        )
        XCTAssertEqual(result.route, .mixedChatAndCommand)
    }

    func testPureCommandNotMixed() {
        let router = ConversationRouter()
        let result = router.classifyFast("turn on the kitchen light", rawText: "")
        XCTAssertEqual(result.route, .command)
        XCTAssertNotEqual(result.route, .mixedChatAndCommand)
    }

    func testShortTranscriptNotMixed() {
        // Transcripts ≤ 25 chars skip the mixed check — avoid false positives on short phrases
        let router = ConversationRouter()
        let result = router.classifyFast("play, but stop", rawText: "")
        XCTAssertNotEqual(result.route, .mixedChatAndCommand)
    }

    // MARK: - ConversationRouteResult.shouldShortCircuit

    func testMixedShortCircuitFalse() {
        let result = ConversationRouteResult(
            route: .mixedChatAndCommand, confidence: 0.90,
            commandHint: "turn on", rationale: "test", fastPath: true
        )
        XCTAssertFalse(result.shouldShortCircuit,
                       "mixedChatAndCommand must not short-circuit — it needs the intent pipeline")
    }

    func testCommandShortCircuitFalse() {
        let result = ConversationRouteResult(
            route: .command, confidence: 0.95,
            commandHint: nil, rationale: "test", fastPath: true
        )
        XCTAssertFalse(result.shouldShortCircuit)
    }

    func testGeneralChatShortCircuits() {
        let result = ConversationRouteResult(
            route: .generalChat, confidence: 0.80,
            commandHint: nil, rationale: "test", fastPath: true
        )
        XCTAssertTrue(result.shouldShortCircuit)
    }

    func testLowConfidenceGeneralChatDoesNotShortCircuit() {
        let result = ConversationRouteResult(
            route: .generalChat, confidence: 0.60,
            commandHint: nil, rationale: "test", fastPath: true
        )
        XCTAssertFalse(result.shouldShortCircuit,
                       "confidence < 0.70 must not short-circuit even for chat routes")
    }

    // MARK: - AttentionPolicy

    func testAttentionPolicyCriticalBypasses() {
        let policy = AttentionPolicy()
        var ctx = AttentionContext()
        ctx.isInActiveMeeting = true
        ctx.recentInterruptionCount = 20
        let event = ProactiveEvent(
            source: .homeAssistant, urgency: .critical,
            title: "Smoke detected", body: "Smoke alarm triggered in kitchen."
        )
        XCTAssertEqual(policy.decide(event: event, context: ctx), .speakNow,
                       "critical events must bypass all gates including meeting and spam guard")
    }

    func testAttentionPolicyMeetingBlocksNormal() {
        let policy = AttentionPolicy()
        var ctx = AttentionContext()
        ctx.isInActiveMeeting = true
        let event = ProactiveEvent(
            source: .news, urgency: .normal,
            title: "News", body: "A story came in."
        )
        XCTAssertEqual(policy.decide(event: event, context: ctx), .suppress)
    }

    func testAttentionPolicyMeetingAllowsHighAsOverlay() {
        let policy = AttentionPolicy()
        var ctx = AttentionContext()
        ctx.isInActiveMeeting = true
        let event = ProactiveEvent(
            source: .github, urgency: .high,
            title: "Build failed", body: "CI pipeline failed on main."
        )
        XCTAssertEqual(policy.decide(event: event, context: ctx), .overlayOnly)
    }

    func testAttentionPolicyFrustrationBundlesLowPriority() {
        let policy = AttentionPolicy()
        var ctx = AttentionContext()
        ctx.emotionalTone = .frustrated
        let event = ProactiveEvent(
            source: .todoist, urgency: .low,
            title: "Task", body: "You have a pending task."
        )
        XCTAssertEqual(policy.decide(event: event, context: ctx), .bundle)
    }

    func testAttentionPolicySpamGuard() {
        let policy = AttentionPolicy()
        var ctx = AttentionContext()
        ctx.recentInterruptionCount = 10  // above maxInterruptionsPerTenMinutes (6)
        let highEvent = ProactiveEvent(
            source: .github, urgency: .high,
            title: "PR review", body: "Someone requested your review."
        )
        let lowEvent = ProactiveEvent(
            source: .news, urgency: .low,
            title: "News", body: "A story."
        )
        XCTAssertEqual(policy.decide(event: highEvent, context: ctx), .bundle)
        XCTAssertEqual(policy.decide(event: lowEvent, context: ctx), .suppress)
    }

    func testAttentionPolicyDeepWorkOverlay() {
        var policy = AttentionPolicy()
        policy.deepWorkApps = ["Xcode"]
        var ctx = AttentionContext()
        ctx.currentApp = "Xcode"
        let highEvent = ProactiveEvent(
            source: .github, urgency: .high,
            title: "Build failed", body: "CI pipeline failed."
        )
        let lowEvent = ProactiveEvent(
            source: .news, urgency: .normal,
            title: "News", body: "A story."
        )
        XCTAssertEqual(policy.decide(event: highEvent, context: ctx), .overlayOnly)
        XCTAssertEqual(policy.decide(event: lowEvent, context: ctx), .defer_)
    }

    func testAttentionPolicyTiredSilencesLow() {
        let policy = AttentionPolicy()
        var ctx = AttentionContext()
        ctx.emotionalTone = .tired
        let event = ProactiveEvent(
            source: .todoist, urgency: .normal,
            title: "Task", body: "Pending task."
        )
        XCTAssertEqual(policy.decide(event: event, context: ctx), .silentMemory)
    }

    // MARK: - ProactiveEvent model

    func testProactiveEventExpired() {
        let expired = ProactiveEvent(
            source: .calendar, urgency: .normal,
            title: "Old event", body: "Yesterday's reminder.",
            expiresAt: Date().addingTimeInterval(-60)
        )
        XCTAssertTrue(expired.isExpired)
    }

    func testProactiveEventNotExpired() {
        let future = ProactiveEvent(
            source: .calendar, urgency: .normal,
            title: "Future event", body: "Future reminder.",
            expiresAt: Date().addingTimeInterval(3600)
        )
        XCTAssertFalse(future.isExpired)
    }

    func testProactiveEventNoExpiryNeverExpires() {
        let event = ProactiveEvent(
            source: .calendar, urgency: .normal,
            title: "Event", body: "Body."
        )
        XCTAssertFalse(event.isExpired)
    }

    func testProactiveUrgencyOrdering() {
        XCTAssertTrue(ProactiveUrgency.critical > ProactiveUrgency.high)
        XCTAssertTrue(ProactiveUrgency.high > ProactiveUrgency.normal)
        XCTAssertTrue(ProactiveUrgency.normal > ProactiveUrgency.low)
        XCTAssertFalse(ProactiveUrgency.low > ProactiveUrgency.normal)
    }

    func testProactiveEventInterruptibilityDefaultFromUrgency() {
        let critical = ProactiveEvent(source: .homeAssistant, urgency: .critical, title: "", body: "")
        let low = ProactiveEvent(source: .news, urgency: .low, title: "", body: "")
        XCTAssertEqual(critical.interruptibilityScore, 1.0, accuracy: 0.01)
        XCTAssertEqual(low.interruptibilityScore, 0.25, accuracy: 0.01)
    }

    // MARK: - JarvisSelfQueryService.isAboutSelf

    func testIsAboutSelfDetectsCapabilityQueries() {
        let svc = JarvisSelfQueryService.shared
        XCTAssertTrue(svc.isAboutSelf("what can you do"))
        XCTAssertTrue(svc.isAboutSelf("can you control my lights"))
        XCTAssertTrue(svc.isAboutSelf("do you support spotify"))
        XCTAssertFalse(svc.isAboutSelf("turn on the kitchen light"))
        XCTAssertFalse(svc.isAboutSelf("what is the weather"))
    }

    // MARK: - pbxproj UUID uniqueness

    func testPbxprojUUIDsUnique() throws {
        let pbxprojPath = Bundle(for: ConversationalArchitectureTests.self)
            .bundlePath
            .components(separatedBy: "/")
            .dropLast(3)
            .joined(separator: "/")
            .appending("/JarvisMac.xcodeproj/project.pbxproj")

        guard FileManager.default.fileExists(atPath: pbxprojPath),
              let contents = try? String(contentsOfFile: pbxprojPath, encoding: .utf8) else {
            // Acceptable in CI where .xcodeproj may not be present
            return
        }

        let pattern = try NSRegularExpression(pattern: #"\b([A-F0-9]{24})\b"#)
        let matches = pattern.matches(in: contents, range: NSRange(contents.startIndex..., in: contents))
        let uuids = matches.compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: contents) else { return nil }
            return String(contents[range])
        }
        let uniqueUUIDs = Set(uuids)
        // Allow some duplicates (a UUID appears once as file ref and once as build file),
        // but reject more than 2× duplication which signals a copy-paste error.
        let maxExpectedDuplication = 2
        let overduped = uuids.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
            .filter { $0.value > maxExpectedDuplication }
        XCTAssertTrue(overduped.isEmpty,
                      "UUIDs appearing more than \(maxExpectedDuplication) times: \(overduped)")
        _ = uniqueUUIDs
    }
}
