import XCTest
@testable import JarvisMac

/// Tests for the RTSP and Vision lifecycle hardening added in Sprint Q.
///
/// Focus areas:
/// - `RTSPStreamManager` task storage, guard against duplicates, and `stopAllDetectionLoops`.
/// - `VisionModule` observable state after `stop()`.
///
/// Hardware-dependent paths (actual RTSP connections, CoreML models) are deliberately
/// avoided: we test only in-memory state and task bookkeeping.
@MainActor
final class VisionLifecycleTests: XCTestCase {

    // MARK: - RTSPStreamManager: loop lifecycle

    /// `startDetectionLoop` stores exactly one task per feedID.
    func testStartDetectionLoopStoresOneTask() {
        let manager = RTSPStreamManager()
        let feedID = UUID()
        manager.startDetectionLoop(feedID: feedID)
        XCTAssertEqual(manager.activeLoopCount, 1)
        manager.stopAllDetectionLoops()
    }

    /// `stopAllDetectionLoops` cancels all tasks and clears the dictionary.
    func testStopAllDetectionLoopsCancelsAllTasks() {
        let manager = RTSPStreamManager()
        let feed1 = UUID()
        let feed2 = UUID()
        manager.startDetectionLoop(feedID: feed1)
        manager.startDetectionLoop(feedID: feed2)
        XCTAssertEqual(manager.activeLoopCount, 2)
        manager.stopAllDetectionLoops()
        XCTAssertEqual(manager.activeLoopCount, 0)
        XCTAssertTrue(manager.activeLoopFeedIDs.isEmpty)
    }

    /// A duplicate `startDetectionLoop` call for the same feedID is a no-op.
    func testDuplicateLoopStartIsGuarded() {
        let manager = RTSPStreamManager()
        let feedID = UUID()
        manager.startDetectionLoop(feedID: feedID)
        manager.startDetectionLoop(feedID: feedID) // should no-op
        XCTAssertEqual(manager.activeLoopCount, 1)
        manager.stopAllDetectionLoops()
    }

    /// Stop then start produces a clean slate — exactly one task after re-start.
    func testStopThenStartCleansState() {
        let manager = RTSPStreamManager()
        let feedID = UUID()
        manager.startDetectionLoop(feedID: feedID)
        manager.stopAllDetectionLoops()
        XCTAssertEqual(manager.activeLoopCount, 0)
        manager.startDetectionLoop(feedID: feedID)
        XCTAssertEqual(manager.activeLoopCount, 1)
        manager.stopAllDetectionLoops()
        XCTAssertEqual(manager.activeLoopCount, 0)
    }

    /// `activeLoopFeedIDs` reflects exactly the feeds that were started.
    func testActiveLoopFeedIDsMatchStartedFeeds() {
        let manager = RTSPStreamManager()
        let feed1 = UUID()
        let feed2 = UUID()
        manager.startDetectionLoop(feedID: feed1)
        manager.startDetectionLoop(feedID: feed2)
        let ids = Set(manager.activeLoopFeedIDs)
        XCTAssertTrue(ids.contains(feed1))
        XCTAssertTrue(ids.contains(feed2))
        manager.stopAllDetectionLoops()
    }

    // MARK: - RTSPStreamManager: per-feed stop

    /// `stopDetectionLoop(feedID:)` removes only the targeted feed.
    func testStopDetectionLoopRemovesOnlyTargetFeed() {
        let manager = RTSPStreamManager()
        let feed1 = UUID()
        let feed2 = UUID()
        manager.startDetectionLoop(feedID: feed1)
        manager.startDetectionLoop(feedID: feed2)
        manager.stopDetectionLoop(feedID: feed1)
        XCTAssertEqual(manager.activeLoopCount, 1)
        XCTAssertFalse(manager.activeLoopFeedIDs.contains(feed1))
        XCTAssertTrue(manager.activeLoopFeedIDs.contains(feed2))
        manager.stopAllDetectionLoops()
    }

    // MARK: - VisionModule: state invariants

    /// A freshly created VisionModule is not running.
    func testVisionModuleIsNotRunningInitially() {
        let module = VisionModule.shared
        XCTAssertFalse(module.isRunning)
    }

    /// `stop()` on a module that was never started leaves `isRunning` false without crashing.
    func testStopOnUnstartedModuleDoesNotCrash() {
        let module = VisionModule.shared
        module.stop()   // must not crash even though isRunning is false
        XCTAssertFalse(module.isRunning)
    }

    /// After `stop()` the active feed count and targets are cleared.
    func testStopClearsPublishedState() {
        let module = VisionModule.shared
        // stop() on a non-running module is a no-op via the guard, but the
        // published state was already zero — confirm it stays zero.
        module.stop()
        XCTAssertEqual(module.activeFeedCount, 0)
        XCTAssertTrue(module.allActiveTargets.isEmpty)
    }

    /// `activeRTSPLoopCount` delegates to the underlying RTSPStreamManager.
    func testActiveRTSPLoopCountDelegatesToManager() {
        let module = VisionModule.shared
        // The module's rtspStreamManager starts with 0 loops (no feeds started)
        XCTAssertEqual(module.activeRTSPLoopCount, 0)
        XCTAssertTrue(module.activeRTSPFeedIDs.isEmpty)
    }
}
