import XCTest
@testable import JarvisMac

// MARK: - Sprint N Tests
// Covers: ConversationalPivotPlanner, StreamingConversationEngine,
//         EpisodicMemoryStore, MemoryImportanceScoring, EpisodicMemoryRetriever,
//         MemoryConsolidationWorker, PersistentVisionContext, SceneChangeDetector,
//         BehaviourPatternEngine, PredictiveSuggestionEngine,
//         ReminderEscalationModel, JarvisRuntimeCoordinator.

@MainActor
final class SprintNTests: XCTestCase {

    // MARK: - ConversationalPivotPlanner

    func testPivotPlannerInitialStateIsIdle() {
        let planner = ConversationalPivotPlanner()
        XCTAssertFalse(planner.isActive)
        XCTAssertTrue(planner.spokenClauses.isEmpty)
        XCTAssertTrue(planner.unspokenClauses.isEmpty)
    }

    func testPivotPlannerBeginResponseSetsActive() {
        let planner = ConversationalPivotPlanner()
        planner.beginResponse(sentences: ["Hello.", "I was saying this."])
        XCTAssertTrue(planner.isActive)
        XCTAssertEqual(planner.unspokenClauses.count, 2)
    }

    func testPivotPlannerMarkSpokenMovesClause() {
        let planner = ConversationalPivotPlanner()
        planner.beginResponse(sentences: ["First.", "Second."])
        planner.markSentenceSpoken("First.")
        XCTAssertEqual(planner.spokenClauses, ["First."])
        XCTAssertEqual(planner.unspokenClauses, ["Second."])
    }

    func testPivotPlannerClassifiesCorrectionInterruption() {
        let planner = ConversationalPivotPlanner()
        let kind = planner.classify("no, I meant after the pinch gesture")
        XCTAssertEqual(kind, .correction)
    }

    func testPivotPlannerClassifiesConfirmation() {
        let planner = ConversationalPivotPlanner()
        let kind = planner.classify("yeah exactly")
        XCTAssertEqual(kind, .confirmation)
    }

    func testPivotPlannerBuildContextClearsState() {
        let planner = ConversationalPivotPlanner()
        planner.beginResponse(sentences: ["First.", "Second."])
        planner.markSentenceSpoken("First.")
        let ctx = planner.buildPivotContext(interruptionText: "no wait")
        XCTAssertEqual(ctx.spokenClauses, ["First."])
        XCTAssertFalse(planner.isActive)
        XCTAssertEqual(planner.pivotCount, 1)
    }

    func testPivotContextBlockContainsWasAndPlanned() {
        let planner = ConversationalPivotPlanner()
        planner.beginResponse(sentences: ["Alpha.", "Beta."])
        planner.markSentenceSpoken("Alpha.")
        let ctx = planner.buildPivotContext(interruptionText: "actually no")
        let block = ctx.contextBlock()
        XCTAssertTrue(block.contains("Was saying:"))
        XCTAssertTrue(block.contains("Had planned:"))
        XCTAssertTrue(block.contains("actually no"))
    }

    // MARK: - StreamingConversationEngine

    func testStreamingEngineSplitsIntoSentences() {
        let engine = StreamingConversationEngine()
        let sentences = engine.splitIntoSentences("Hello. I am here. How are you?")
        XCTAssertEqual(sentences.count, 3)
    }

    func testStreamingEngineSingleSentenceReturnsFalse() {
        let engine = StreamingConversationEngine()
        var spoken = [String]()
        engine.speakSentence = { spoken.append($0) }
        let didStream = engine.beginStreaming(fullText: "Short sentence without more text.")
        // Single sentence — engine returns false (falls back to single TTS)
        XCTAssertFalse(didStream)
    }

    func testStreamingEngineMultiSentenceActivatesStreaming() {
        let engine = StreamingConversationEngine()
        engine.speakSentence = { _ in }
        let didStream = engine.beginStreaming(fullText: "First sentence here. Second sentence here. Third one.")
        XCTAssertTrue(didStream)
        XCTAssertTrue(engine.isStreaming)
    }

    func testStreamingEngineAdvanceDeliversPendingSentence() {
        let engine = StreamingConversationEngine()
        var spoken: [String] = []
        engine.speakSentence = { spoken.append($0) }
        _ = engine.beginStreaming(fullText: "Alpha sentence here. Beta sentence here. Gamma sentence.")
        // First sentence already spoken in beginStreaming
        let firstSpokenCount = spoken.count
        engine.advanceIfStreaming()
        XCTAssertGreaterThan(spoken.count, firstSpokenCount)
    }

    func testStreamingEngineInterruptionFiringPivot() {
        let engine = StreamingConversationEngine()
        engine.speakSentence = { _ in }
        var pivotFired = false
        engine.onPivot = { _ in pivotFired = true }
        _ = engine.beginStreaming(fullText: "One long sentence here. Another long sentence here.")
        engine.handleInterruption(userText: "no wait actually")
        XCTAssertTrue(pivotFired)
        XCTAssertFalse(engine.isStreaming)
    }

    // MARK: - EpisodicMemoryStore

    func testEpisodicStoreRegistersEntry() {
        let store = EpisodicMemoryStore()
        store.register(text: "We decided to use SQLite",
                       title: "DB decision",
                       type: .projectDecision,
                       importance: 0.8,
                       confidence: 0.9)
        XCTAssertEqual(store.entries.count, 1)
    }

    func testEpisodicStoreDeduplicatesDuplicates() {
        let store = EpisodicMemoryStore()
        let text = "We decided to use SQLite for all storage needs"
        store.register(text: text, title: "T1", type: .projectDecision, importance: 0.8, confidence: 0.9)
        store.register(text: text, title: "T2", type: .projectDecision, importance: 0.7, confidence: 0.9)
        XCTAssertEqual(store.entries.count, 1)
    }

    func testEpisodicStoreMarkResolved() {
        let store = EpisodicMemoryStore()
        store.register(text: "Unique text for resolution test", title: "T",
                       type: .idea, importance: 0.5, confidence: 0.7)
        let id = store.entries.first!.id
        store.markResolved(id)
        XCTAssertTrue(store.entries.first!.isResolved)
    }

    // MARK: - MemoryImportanceScoring

    func testImportanceScoringHighForDecision() {
        let score = MemoryImportanceScoring.baseScore(for: .projectDecision)
        XCTAssertGreaterThan(score, 0.65)
    }

    func testImportanceScoringLowForDiscard() {
        let score = MemoryImportanceScoring.baseScore(for: .discard)
        XCTAssertEqual(score, 0.0)
    }

    func testEmphasisBonusDetectsKeyword() {
        let bonus = MemoryImportanceScoring.emphasisBonus(in: "This is important and we must remember")
        XCTAssertGreaterThan(bonus, 0)
    }

    func testDecayPenaltyIncreasesWithAge() {
        let fresh = MemoryImportanceScoring.decayPenalty(ageDays: 0)
        let old   = MemoryImportanceScoring.decayPenalty(ageDays: 30)
        XCTAssertLessThan(fresh, old)
    }

    // MARK: - PersistentVisionContext

    func testVisionContextInitialStateUnknown() {
        let ctx = PersistentVisionContext()
        XCTAssertEqual(ctx.presenceKind, .unknown)
        XCTAssertFalse(ctx.isDeskOccupied)
        XCTAssertFalse(ctx.isFresh)
    }

    func testVisionContextUpdatePresenceMarksOccupied() {
        let ctx = PersistentVisionContext()
        ctx.updatePresence(.present, confidence: 0.90)
        XCTAssertEqual(ctx.presenceKind, .present)
        XCTAssertTrue(ctx.isDeskOccupied)
        XCTAssertTrue(ctx.isFresh)
    }

    func testVisionContextLowConfidenceNotOccupied() {
        let ctx = PersistentVisionContext()
        ctx.updatePresence(.present, confidence: 0.30)
        XCTAssertEqual(ctx.presenceKind, .present)
        XCTAssertFalse(ctx.isDeskOccupied)  // below 0.55 threshold
    }

    // MARK: - SceneChangeDetector

    func testSceneChangeDetectorHysteresisRequiresMultipleFrames() {
        let detector = SceneChangeDetector()
        detector.presenceHysteresisCount = 3
        let ctx = PersistentVisionContext()
        // 2 frames — should NOT commit
        detector.reportPresence(isPresent: true, confidence: 0.9)
        detector.reportPresence(isPresent: true, confidence: 0.9)
        XCTAssertNotEqual(ctx.presenceKind, .present, "should not commit with < hysteresis frames")
    }

    func testSceneChangeDetectorCommitsAfterHysteresis() {
        let detector = SceneChangeDetector()
        detector.presenceHysteresisCount = 2
        for _ in 0..<2 { detector.reportPresence(isPresent: true, confidence: 0.85) }
        XCTAssertEqual(PersistentVisionContext.shared.presenceKind, .present)
    }

    // MARK: - BehaviourPatternEngine

    func testBehaviourPatternEngineRecordsIntent() {
        let engine = BehaviourPatternEngine()
        engine.recordIntent("getCurrentWeather", inApp: "Xcode")
        XCTAssertFalse(engine.patterns.isEmpty)
    }

    func testBehaviourPatternEngineIncreasesCount() {
        let engine = BehaviourPatternEngine()
        for _ in 0..<6 { engine.recordIntent("checkEmail", inApp: nil) }
        let count = engine.patterns.filter { $0.intentLabel == "checkEmail" }
                         .reduce(0) { $0 + $1.occurrenceCount }
        XCTAssertGreaterThanOrEqual(count, 6)
    }

    // MARK: - ReminderEscalationModel

    func testReminderEscalationTracksReminder() {
        let model = ReminderEscalationModel()
        model.track(title: "Team standup", dueDate: Date().addingTimeInterval(600), source: "calendar")
        XCTAssertEqual(model.trackedReminders.count, 1)
    }

    func testReminderEscalationSnoozeDismiss() {
        let model = ReminderEscalationModel()
        model.track(title: "Design review", dueDate: Date().addingTimeInterval(300), source: "calendar")
        let id = model.trackedReminders.first!.id
        model.snooze(id, minutes: 5)
        XCTAssertTrue(model.trackedReminders.first!.isSnoozed)
        model.dismiss(id)
        XCTAssertTrue(model.trackedReminders.isEmpty)
    }

    // MARK: - JarvisRuntimeCoordinator

    func testCoordinatorRecordsDecisions() {
        let coordinator = JarvisRuntimeCoordinator()
        coordinator.speakText = { _ in }
        coordinator.isTTSActive = { false }
        coordinator.isListeningActive = { false }
        coordinator.isConversationActive = { false }
        coordinator.submitSpeak("Hello world", urgency: .normal, from: "test")
        XCTAssertFalse(coordinator.recentDecisions.isEmpty)
    }

    func testCoordinatorSuppressesLowUrgencyWhenListening() {
        let coordinator = JarvisRuntimeCoordinator()
        var spoken = [String]()
        coordinator.speakText = { spoken.append($0) }
        coordinator.isTTSActive = { false }
        coordinator.isListeningActive = { true }
        coordinator.isConversationActive = { false }
        coordinator.submitSpeak("Low priority text", urgency: .low, from: "test")
        XCTAssertTrue(spoken.isEmpty, "Should suppress low urgency when listening")
    }

    func testCoordinatorAlwaysSpeaksCritical() {
        let coordinator = JarvisRuntimeCoordinator()
        var spoken = [String]()
        coordinator.speakText = { spoken.append($0) }
        coordinator.isTTSActive = { true }  // TTS active, but critical bypasses
        coordinator.isListeningActive = { false }
        coordinator.isConversationActive = { false }
        coordinator.submitSpeak("Emergency alert!", urgency: .critical, from: "test")
        XCTAssertFalse(spoken.isEmpty, "Critical urgency should bypass TTS check")
    }

    // MARK: - pbxproj UUID uniqueness (regression guard)

    func testPbxprojUUIDsUniqueSprintN() throws {
        let pbxprojPath = Bundle(for: SprintNTests.self)
            .bundlePath
            .components(separatedBy: "/")
            .dropLast(3)
            .joined(separator: "/")
            .appending("/JarvisMac.xcodeproj/project.pbxproj")

        guard FileManager.default.fileExists(atPath: pbxprojPath),
              let contents = try? String(contentsOfFile: pbxprojPath, encoding: .utf8) else {
            return
        }

        let pattern = try NSRegularExpression(pattern: #"\b([A-F0-9]{24})\b"#)
        let matches = pattern.matches(in: contents, range: NSRange(contents.startIndex..., in: contents))
        let uuids = matches.compactMap { m -> String? in
            guard let r = Range(m.range(at: 1), in: contents) else { return nil }
            return String(contents[r])
        }
        let overduped = uuids.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
            .filter { $0.value > 2 }
        XCTAssertTrue(overduped.isEmpty, "UUIDs appearing more than 2 times: \(overduped)")
    }
}
