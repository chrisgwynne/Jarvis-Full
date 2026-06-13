import XCTest

/// Tests for DaemonOfflineQueue — replay-safety classification, drain-once,
/// overflow capping, and the replayUnsafeTypes constant set.
///
/// Compiled directly against the daemon sources (JarvisBrainDaemon target is
/// included as a source set in JarvisBrainDaemonTests — see project.yml).
final class DaemonOfflineQueueTests: XCTestCase {

    // MARK: - Replay-safety classification

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

    // MARK: - Drain behaviour

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

    // MARK: - Overflow cap

    func testOfflineQueue_overflow_capsAtMaxDepth() {
        let q = DaemonOfflineQueue()
        for _ in 0..<55 {
            q.enqueue(makeEnvelope(type: "execution.result"))
        }
        XCTAssertEqual(q.depth, 50, "Queue should cap at maxDepth=50")
        XCTAssertGreaterThan(q.droppedCount, 0, "Some messages should have been dropped")
    }

    // MARK: - Backward compat

    func testOfflineQueue_legacyToolResult_queued() {
        let q = DaemonOfflineQueue()
        q.enqueue(makeEnvelope(type: "tool.result"))
        XCTAssertEqual(q.depth, 1, "Legacy tool.result should still queue for backward compat")
    }

    // MARK: - ReplayUnsafeTypes constant set

    func testReplayUnsafeTypes_containsExecutionRequest() {
        XCTAssertTrue(DaemonOfflineQueue.replayUnsafeTypes.contains("execution.request"))
    }

    func testReplayUnsafeTypes_containsOrchestrate() {
        XCTAssertTrue(DaemonOfflineQueue.replayUnsafeTypes.contains("orchestrate.speak"))
        XCTAssertTrue(DaemonOfflineQueue.replayUnsafeTypes.contains("orchestrate.silent"))
    }

    // MARK: - Helpers

    private func makeEnvelope(type: String) -> DaemonMessageEnvelope {
        DaemonMessageEnvelope.make(type: type, target: .macApp)
    }
}
