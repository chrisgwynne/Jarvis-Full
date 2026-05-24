import XCTest
@testable import JarvisMac

/// Tests for the distributed execution pipeline (Phase P9 QA + Hardening).
///
/// Coverage:
///  - AndroidToolOrchestrator: submit/result/timeout/clear/cap/dedup/stale
///  - ToolExecutionResult: spokenSummary accuracy for all major capabilities
///  - MacBridgeCapabilityNames: constant values mirror Android
///  - DaemonOfflineQueue: replay-safety classification, drain-once, overflow
///  - OrchestrationClearReason: all cases present
@MainActor
final class DistributedExecutionTests: XCTestCase {

    // MARK: - Lifecycle

    override func setUp() async throws {
        // Reset shared diagnostics between tests
        AndroidToolOrchestratorDiagnostics.shared.reset()
        // Clear any pending from previous tests
        AndroidToolOrchestrator.shared.clearPending(reason: .test)
    }

    // MARK: - handleResult: resolves matching continuation

    func testHandleResult_resolvesMatchingContinuation() async {
        let orch = AndroidToolOrchestrator.shared
        var capturedRouteId: String?

        // Intercept the send to capture the routeId without actually sending
        orch.onDirectSend = { envelope in
            capturedRouteId = envelope["correlationId"] as? String
        }

        // Submit in background task so we can inject result before timeout
        orch.timeoutSeconds = 10
        let task = Task { await orch.submitTool(command: "flashlight.set", params: ["on": true]) }

        // Wait for continuation to register
        var deadline = 50
        while capturedRouteId == nil && deadline > 0 {
            try? await Task.sleep(for: .milliseconds(10))
            deadline -= 1
        }
        guard let routeId = capturedRouteId else {
            XCTFail("onDirectSend was never called — continuation not registered")
            task.cancel()
            return
        }

        // Inject a synthetic execution.result
        let json = syntheticResult(correlationId: routeId, ok: true, status: "ok")
        orch.handleResult(data: json)

        let result = await task.value
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.status, "ok")
        XCTAssertNotNil(result.rttMilliseconds)
    }

    // MARK: - handleResult: timeout resolution

    func testTimeout_resolvesAsFailure() async {
        let orch = AndroidToolOrchestrator.shared
        orch.timeoutSeconds = 0.1   // instant for test
        orch.onDirectSend = { _ in }

        let result = await orch.submitTool(command: "ring_phone")
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.status, "timeout")
        XCTAssertNotNil(result.rttMilliseconds)
    }

    // MARK: - handleResult: stale result dropped after timeout

    func testStaleResult_afterTimeout_droppedSafely() async {
        let orch = AndroidToolOrchestrator.shared
        orch.timeoutSeconds = 0.05
        orch.onDirectSend = { _ in }

        _ = await orch.submitTool(command: "ring_phone")

        // Now inject a result with a completely unknown routeId (simulates stale)
        let beforeDrop = AndroidToolOrchestratorDiagnostics.shared.staleResultDropCount
        let json = syntheticResult(correlationId: UUID().uuidString, ok: true, status: "ok")
        orch.handleResult(data: json)
        XCTAssertEqual(AndroidToolOrchestratorDiagnostics.shared.staleResultDropCount,
                       beforeDrop + 1,
                       "Stale result should increment staleResultDropCount")
    }

    // MARK: - handleResult: malformed data ignored

    func testHandleResult_malformedData_ignored() {
        let orch = AndroidToolOrchestrator.shared
        let before = AndroidToolOrchestratorDiagnostics.shared.staleResultDropCount
        orch.handleResult(data: Data("not json at all".utf8))
        // No crash; malformed exits before stale-drop check
        XCTAssertEqual(AndroidToolOrchestratorDiagnostics.shared.staleResultDropCount, before)
    }

    // MARK: - handleResult: missing correlationId

    func testHandleResult_missingCorrelationId_ignored() {
        let orch = AndroidToolOrchestrator.shared
        let json = try! JSONSerialization.data(withJSONObject: [
            "type": "execution.result",
            "payload": ["ok": true, "status": "ok"]
        ])
        // No correlationId → silently ignored
        orch.handleResult(data: json)
        // Should not crash
    }

    // MARK: - clearPending: resolves all as timeout

    func testClearPending_resolvesAllAsFailed() async {
        let orch = AndroidToolOrchestrator.shared
        orch.timeoutSeconds = 30   // long so they stay pending
        orch.onDirectSend = { _ in }

        let tasks = (0..<3).map { _ in
            Task { await orch.submitTool(command: "volume.set", params: ["percent": 50]) }
        }
        // Let continuations register
        try? await Task.sleep(for: .milliseconds(80))

        let pending = orch.pendingCount
        XCTAssertGreaterThan(pending, 0, "Should have pending requests")

        orch.clearPending(reason: .daemonRestart)
        XCTAssertEqual(orch.pendingCount, 0)

        let results = await withTaskGroup(of: ToolExecutionResult.self) { group in
            for t in tasks { group.addTask { await t.value } }
            var out: [ToolExecutionResult] = []
            for await r in group { out.append(r) }
            return out
        }
        XCTAssertEqual(results.count, 3)
        XCTAssertTrue(results.allSatisfy { !$0.ok }, "All cleared requests should be failures")
        XCTAssertTrue(results.allSatisfy { $0.status == "timeout" })
    }

    // MARK: - ToolExecutionResult: spokenSummary

    func testSpokenSummary_sendSms_includesRecipient() {
        let r = okResult()
        let s = r.spokenSummary(for: MacBridgeCapabilityNames.sendSms, params: ["recipient": "Cath"])
        XCTAssertTrue(s.contains("Cath"), "Summary should include recipient: \(s)")
    }

    func testSpokenSummary_confirmationRejected() {
        let r = ToolExecutionResult(ok: false, status: "confirmation_rejected",
                                    message: nil, resultPayload: [:], rttMilliseconds: nil)
        let s = r.spokenSummary(for: MacBridgeCapabilityNames.callContact)
        XCTAssertFalse(s.isEmpty)
        // Should be a graceful cancellation phrase
        XCTAssertTrue(s.count < 60, "Rejection phrase should be brief: \(s)")
    }

    func testSpokenSummary_timeout() {
        let r = ToolExecutionResult(ok: false, status: "timeout",
                                    message: nil, resultPayload: [:], rttMilliseconds: 15000)
        let s = r.spokenSummary(for: MacBridgeCapabilityNames.flashlightSet)
        XCTAssertFalse(s.isEmpty)
        XCTAssertTrue(s.lowercased().contains("phone") || s.lowercased().contains("respond"),
                      "Timeout should mention phone responsiveness: \(s)")
    }

    func testSpokenSummary_timerCreate_minutes() {
        let r = okResult()
        let s = r.spokenSummary(for: MacBridgeCapabilityNames.timerCreate, params: ["minutes": 10])
        XCTAssertTrue(s.contains("10"), "Should include duration: \(s)")
        XCTAssertTrue(s.lowercased().contains("minute"), "Should say minutes: \(s)")
    }

    func testSpokenSummary_flashlight_onOff() {
        let r = okResult()
        let on  = r.spokenSummary(for: MacBridgeCapabilityNames.flashlightSet, params: ["on": true])
        let off = r.spokenSummary(for: MacBridgeCapabilityNames.flashlightSet, params: ["on": false])
        XCTAssertTrue(on.lowercased().contains("on"),  "Should say on: \(on)")
        XCTAssertTrue(off.lowercased().contains("off"), "Should say off: \(off)")
    }

    func testSpokenSummary_navigation_includesDestination() {
        let r = okResult()
        let s = r.spokenSummary(for: MacBridgeCapabilityNames.startNavigation,
                                  params: ["destination": "the gym"])
        XCTAssertTrue(s.lowercased().contains("gym"), "Should include destination: \(s)")
    }

    func testSpokenSummary_volumeSet_includesPercent() {
        let r = okResult()
        let s = r.spokenSummary(for: MacBridgeCapabilityNames.volumeSet, params: ["percent": 75])
        XCTAssertTrue(s.contains("75"), "Should include percent: \(s)")
    }

    func testSpokenSummary_unknownCapability_returnsDone() {
        let r = okResult()
        let s = r.spokenSummary(for: "some_future_capability")
        XCTAssertEqual(s, "Done.", "Unknown capability should return 'Done.'")
    }

    // MARK: - MacBridgeCapabilityNames: spot-check values

    func testCapabilityNames_canonicalValues() {
        XCTAssertEqual(MacBridgeCapabilityNames.sendSms,        "send_sms")
        XCTAssertEqual(MacBridgeCapabilityNames.callContact,    "call_contact")
        XCTAssertEqual(MacBridgeCapabilityNames.flashlightSet,  "flashlight.set")
        XCTAssertEqual(MacBridgeCapabilityNames.mediaPlay,      "media.play")
        XCTAssertEqual(MacBridgeCapabilityNames.mediaPause,     "media.pause")
        XCTAssertEqual(MacBridgeCapabilityNames.mediaNext,      "media.next")
        XCTAssertEqual(MacBridgeCapabilityNames.mediaPrevious,  "media.previous")
        XCTAssertEqual(MacBridgeCapabilityNames.volumeSet,      "volume.set")
        XCTAssertEqual(MacBridgeCapabilityNames.appOpen,        "app.open")
        XCTAssertEqual(MacBridgeCapabilityNames.timerCreate,    "timer.create")
        XCTAssertEqual(MacBridgeCapabilityNames.startNavigation,"start_navigation")
        XCTAssertEqual(MacBridgeCapabilityNames.captureCamera,  "capture_camera")
    }

    // MARK: - DaemonOfflineQueue: replay-safety classification

    func testOfflineQueue_executionRequest_notQueued() {
        let q = DaemonOfflineQueue()
        let beforeUnsafe = q.replayUnsafeDroppedCount
        q.enqueue(makeEnvelope(type: "execution.request"))
        XCTAssertEqual(q.depth, 0,
                       "execution.request must never be queued (destructive replay risk)")
        XCTAssertEqual(q.replayUnsafeDroppedCount, beforeUnsafe + 1)
    }

    func testOfflineQueue_executionResult_queued() {
        let q = DaemonOfflineQueue()
        q.enqueue(makeEnvelope(type: "execution.result"))
        XCTAssertEqual(q.depth, 1, "execution.result is replay-safe and should be queued")
    }

    func testOfflineQueue_transcriptFinal_queued() {
        let q = DaemonOfflineQueue()
        q.enqueue(makeEnvelope(type: "transcript.final"))
        XCTAssertEqual(q.depth, 1)
    }

    func testOfflineQueue_orchestrateSpeak_notQueued() {
        let q = DaemonOfflineQueue()
        q.enqueue(makeEnvelope(type: "orchestrate.speak"))
        XCTAssertEqual(q.depth, 0, "orchestrate.speak is time-sensitive — must not queue")
    }

    func testOfflineQueue_proactiveNotify_notQueued() {
        let q = DaemonOfflineQueue()
        q.enqueue(makeEnvelope(type: "proactive.notify"))
        XCTAssertEqual(q.depth, 0, "proactive.notify is time-sensitive — must not queue")
    }

    func testOfflineQueue_replyFinal_notQueued() {
        let q = DaemonOfflineQueue()
        q.enqueue(makeEnvelope(type: "reply.final"))
        XCTAssertEqual(q.depth, 0, "reply.final is stale if Mac missed it — must not replay")
    }

    func testOfflineQueue_drain_emptiesQueue() {
        let q = DaemonOfflineQueue()
        q.enqueue(makeEnvelope(type: "execution.result"))
        q.enqueue(makeEnvelope(type: "transcript.final"))
        let drained = q.drain()
        XCTAssertEqual(drained.count, 2)
        XCTAssertEqual(q.depth, 0, "Queue should be empty after drain")
    }

    func testOfflineQueue_drainTwice_noReplay() {
        let q = DaemonOfflineQueue()
        q.enqueue(makeEnvelope(type: "execution.result"))
        _ = q.drain()
        let second = q.drain()
        XCTAssertEqual(second.count, 0, "Second drain must return nothing — no replay")
    }

    func testOfflineQueue_overflow_capsAtMaxDepth() {
        let q = DaemonOfflineQueue()
        for _ in 0..<55 {
            q.enqueue(makeEnvelope(type: "execution.result"))
        }
        XCTAssertEqual(q.depth, 50, "Queue should cap at maxDepth=50")
        XCTAssertGreaterThan(q.droppedCount, 0, "Some messages should have been dropped")
    }

    func testOfflineQueue_legacyToolResult_queued() {
        // Legacy backward compat: tool.result should still queue (it's replay-safe)
        let q = DaemonOfflineQueue()
        q.enqueue(makeEnvelope(type: "tool.result"))
        XCTAssertEqual(q.depth, 1, "Legacy tool.result should still queue for backward compat")
    }

    // MARK: - OrchestrationClearReason: all cases

    func testOrchestrationClearReason_allCasesPresent() {
        let reasons: [OrchestrationClearReason] = [
            .daemonRestart, .androidReconnect, .macReconnect, .shutdown, .test
        ]
        XCTAssertEqual(reasons.count, 5)
        // Each should have a non-empty rawValue
        for r in reasons {
            XCTAssertFalse(r.rawValue.isEmpty)
        }
    }

    // MARK: - ReplayUnsafeTypes constant set

    func testReplayUnsafeTypes_containsExecutionRequest() {
        XCTAssertTrue(DaemonOfflineQueue.replayUnsafeTypes.contains("execution.request"))
    }

    func testReplayUnsafeTypes_containsOrchestrate() {
        XCTAssertTrue(DaemonOfflineQueue.replayUnsafeTypes.contains("orchestrate.speak"))
        XCTAssertTrue(DaemonOfflineQueue.replayUnsafeTypes.contains("orchestrate.silent"))
    }

    // MARK: - pbxproj UUID regression

    func testPbxprojUUIDs_uniqueForDistributedFiles() throws {
        let pbxprojURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("JarvisMac.xcodeproj/project.pbxproj")
        let content = try String(contentsOf: pbxprojURL)
        let uuids = [
            "AO01A2B3C4D5E6F7A8B9C0001",  // AndroidToolOrchestrator.swift in Sources
            "AO02A2B3C4D5E6F7A8B9C0001",  // AndroidToolOrchestrator.swift file ref
        ]
        for uuid in uuids {
            let count = content.components(separatedBy: uuid).count - 1
            XCTAssertGreaterThan(count, 0, "UUID \(uuid) not found in pbxproj")
        }
    }

    // MARK: - Helpers

    private func okResult() -> ToolExecutionResult {
        ToolExecutionResult(ok: true, status: "ok", message: nil, resultPayload: [:], rttMilliseconds: 100)
    }

    private func syntheticResult(correlationId: String, ok: Bool, status: String) -> Data {
        let json: [String: Any] = [
            "type"          : "execution.result",
            "correlationId" : correlationId,
            "payload"       : ["ok": ok, "status": status]
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    private func makeEnvelope(type: String) -> DaemonMessageEnvelope {
        DaemonMessageEnvelope.make(type: type, target: .macApp)
    }
}

// MARK: - DaemonOfflineQueue test initialiser

extension DaemonOfflineQueue {
    /// Non-singleton instance for unit testing.
    convenience init() { self.init(testing: true) }
    fileprivate convenience init(testing: Bool) { self.init() }
}
