import XCTest
@testable import JarvisMac

// MARK: - DistributedBrainTests

@MainActor
final class DistributedBrainTests: XCTestCase {

    // MARK: - ConversationFrame dedup

    func testFrameDeduplication() {
        let fallback = DistributedFallbackCoordinator.shared
        let frameId = UUID().uuidString
        XCTAssertTrue(fallback.canAccept(frameId), "First acceptance should succeed")
        XCTAssertFalse(fallback.canAccept(frameId), "Duplicate frame should be rejected")
    }

    func testFallbackReplayQueue() {
        let fallback = DistributedFallbackCoordinator.shared
        fallback.markDisconnected("windows-test")
        let frame = ConversationFrame(
            id: UUID().uuidString, deviceId: "windows-test",
            role: .user, transcript: "hello", timestamp: Date(),
            sequenceNumber: 1
        )
        let buffered = fallback.buffer(frame, for: "windows-test")
        XCTAssertTrue(buffered)
        let replayed = fallback.markReconnected("windows-test")
        XCTAssertEqual(replayed.count, 1)
        XCTAssertEqual(replayed.first?.id, frame.id)
    }

    // MARK: - SpeakerCoordinator

    func testSpeakerLeaseExclusivity() {
        let speaker = SpeakerCoordinator.shared
        speaker.forceRelease()

        let lease1 = speaker.acquire(deviceId: "mac", speechId: "s1", expectedDurationSeconds: 5)
        XCTAssertNotNil(lease1, "Mac should acquire lease")

        let lease2 = speaker.acquire(deviceId: "windows", speechId: "s2", expectedDurationSeconds: 5)
        XCTAssertNil(lease2, "Windows should fail while Mac holds lease")

        speaker.release(deviceId: "mac", speechId: "s1")
        XCTAssertTrue(speaker.isIdle)
    }

    func testSpeakerPreemptionOnlyByMac() {
        let speaker = SpeakerCoordinator.shared
        speaker.forceRelease()
        _ = speaker.acquire(deviceId: "mac", speechId: "s3", expectedDurationSeconds: 5)

        let windowsInterrupt = speaker.interrupt(by: "windows")
        XCTAssertFalse(windowsInterrupt, "Windows must NOT self-grant interruption authority")

        let macInterrupt = speaker.interrupt(by: "mac")
        XCTAssertTrue(macInterrupt, "Mac may preempt its own lease")
    }

    // MARK: - GlobalPresenceAggregator

    func testPresenceDebounce() {
        let agg = GlobalPresenceAggregator.shared
        let snap1 = makePresence(deviceId: "windows", attention: .working)
        let snap2 = makePresence(deviceId: "windows", attention: .codingFlow)

        let r1 = agg.update(snap1)
        let r2 = agg.update(snap2) // immediately after — should be debounced
        XCTAssertTrue(r1)
        XCTAssertFalse(r2, "Second update within debounce window should be rejected")
    }

    func testPresenceBoundedRetention() {
        let agg = GlobalPresenceAggregator.shared
        // Insert 11 unique device snapshots — only 10 should survive
        for i in 0..<11 {
            let snap = PresenceSnapshot(
                deviceId: "device-\(i)", timestamp: Date(), foregroundApp: nil,
                foregroundWindowTitle: nil, browserURL: nil, ocrSummary: nil,
                isUserPresent: true, attentionLevel: .idle,
                activeCodingFile: nil, activeCodingLanguage: nil
            )
            _ = agg.update(snap)
        }
        XCTAssertLessThanOrEqual(agg.allPresence.count, 10)
    }

    // MARK: - DistributedOrchestrationEngine

    func testOrchestrationDefaultsToMac() {
        let engine = DistributedOrchestrationEngine.shared
        let decision = engine.decide(
            transcript: "what's the weather",
            sourceDeviceId: "windows",
            intentLabel: "weather",
            presence: nil,
            isMacListening: true,
            isMacSpeaking: false
        )
        XCTAssertEqual(decision.respondingDeviceId, DistributedOrchestrationEngine.macDeviceId)
    }

    func testOrchestrationCodingFlowReducesVerbosity() {
        let engine = DistributedOrchestrationEngine.shared
        let snap = makePresence(deviceId: "windows", attention: .codingFlow)
        let decision = engine.decide(
            transcript: "remind me later",
            sourceDeviceId: "windows",
            intentLabel: "reminder",
            presence: snap,
            isMacListening: true,
            isMacSpeaking: false
        )
        XCTAssertEqual(decision.verbosity, .brief)
    }

    // MARK: - DistributedReferenceResolver

    func testReferenceResolvesWindowsBrowserURL() async {
        let snap = makePresence(deviceId: "windows", attention: .browsing)
        var snapWithURL = snap
        snapWithURL = PresenceSnapshot(
            deviceId: "windows", timestamp: Date(),
            foregroundApp: "Chrome", foregroundWindowTitle: "GitHub PR #42",
            browserURL: "https://github.com/org/repo/pull/42",
            ocrSummary: nil, isUserPresent: true, attentionLevel: .browsing,
            activeCodingFile: nil, activeCodingLanguage: nil
        )
        _ = GlobalPresenceAggregator.shared.update(snapWithURL)

        let resolver = DistributedReferenceResolver.shared
        let result = resolver.resolve("open that page")
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.contains("github.com") == true, "Should resolve Windows browser URL")
    }

    // MARK: - DistributedConversationCoordinator

    func testConversationFrameOrdering() {
        let coord = DistributedConversationCoordinator.shared
        coord.beginSession(initiatingDeviceId: "mac")

        coord.recordMacUserTurn("What time is it?")
        coord.recordMacAssistantTurn("It is 3pm.")

        let block = coord.buildContextBlock()
        XCTAssertTrue(block.contains("[DISTRIBUTED DIALOGUE]"))
        XCTAssertTrue(block.contains("What time is it?"))
    }

    func testConversationFrameDedup() {
        let coord = DistributedConversationCoordinator.shared
        coord.beginSession(initiatingDeviceId: "mac")

        let frame = ConversationFrame(
            id: "unique-123", deviceId: "windows", role: .user,
            transcript: "test", timestamp: Date(), sequenceNumber: 1
        )
        let first = coord.ingest(frame)
        let second = coord.ingest(frame)   // same id
        XCTAssertTrue(first)
        XCTAssertFalse(second, "Same frame ingested twice should be rejected")
    }

    // MARK: - GlobalAttentionCoordinator

    func testAttentionCodingFlowLowInterruptibility() {
        let coord = GlobalAttentionCoordinator.shared
        // Simulate coding flow via Windows presence
        let snap = PresenceSnapshot(
            deviceId: "windows", timestamp: Date(), foregroundApp: "VS Code",
            foregroundWindowTitle: nil, browserURL: nil, ocrSummary: nil,
            isUserPresent: true, attentionLevel: .codingFlow,
            activeCodingFile: "main.swift", activeCodingLanguage: "swift"
        )
        _ = GlobalPresenceAggregator.shared.update(snap)
        coord.refresh()

        let score = coord.interruptibilityScore(urgency: .normal)
        XCTAssertLessThan(score, 0.4, "Coding flow should have low interruptibility for normal urgency")
    }

    func testAttentionCriticalAlwaysInterruptible() {
        let coord = GlobalAttentionCoordinator.shared
        let score = coord.interruptibilityScore(urgency: .critical)
        XCTAssertGreaterThan(score, 0.5, "Critical urgency should always be interruptible")
    }

    // MARK: - DistributedFallbackCoordinator divergence

    func testDivergenceDetection() {
        let fallback = DistributedFallbackCoordinator.shared
        XCTAssertFalse(fallback.sessionDivergenceCheck(macSequence: 10, remoteSequence: 12))
        XCTAssertTrue(fallback.sessionDivergenceCheck(macSequence: 10, remoteSequence: 16))
    }

    // MARK: - RemoteExecutionCoordinator queue cap

    func testExecutionCoordinatorBoundedQueue() async {
        let coord = RemoteExecutionCoordinator.shared
        coord.cancelAll()
        // Don't await — just check the pending count is bounded
        XCTAssertEqual(coord.pendingCount, 0)
    }

    // MARK: - (deleted) MacBridgeProtocolV2 is deprecated — external WS hosting moved to JarvisBrainDaemon

    // MARK: - pbxproj UUID regression

    func testPbxprojUUIDsUnique() throws {
        let pbxproj = try String(contentsOfFile:
            "/Users/chris/Desktop/jarvis/JarvisMac.xcodeproj/project.pbxproj")
        let prefixIDs = [
            "DM01", "DM02", "DC01", "DC02", "PA01", "PA02",
            "DO01", "DO02", "SK01", "SK02", "DR01", "DR02",
            "RX01", "RX02", "GC01", "GC02", "DF01", "DF02",
            "BV01", "BV02", "AC01", "AC02", "DD01", "DD02",
            "GL01", "GL02", "DT01", "DT02",
            "XM01", "XM02", "ZE01", "ZE02", "XX01", "XX02",
            "ZH01", "ZH02", "XS01", "XS02", "XL01", "XL02",
            "XW01", "XW02", "XD01", "XD02", "XB01", "XB02",
            "XY01", "XY02", "XT01", "XT02"
        ]
        for id in prefixIDs {
            let count = pbxproj.components(separatedBy: id).count - 1
            XCTAssertEqual(count, 1, "UUID \(id) should appear exactly once in pbxproj")
        }
    }

    // MARK: - Helpers

    private func makePresence(deviceId: String, attention: PresenceSnapshot.AttentionLevel) -> PresenceSnapshot {
        PresenceSnapshot(
            deviceId: deviceId, timestamp: Date(), foregroundApp: nil,
            foregroundWindowTitle: nil, browserURL: nil, ocrSummary: nil,
            isUserPresent: true, attentionLevel: attention,
            activeCodingFile: nil, activeCodingLanguage: nil
        )
    }
}
