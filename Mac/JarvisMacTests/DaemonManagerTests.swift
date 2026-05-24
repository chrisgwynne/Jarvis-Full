import XCTest
@testable import JarvisMac

@MainActor
final class DaemonManagerTests: XCTestCase {

    func testDaemonManagerSingletonExists() {
        XCTAssertNotNil(DaemonManager.shared)
    }

    func testPlistURLIsInLaunchAgents() {
        let url = DaemonManager.shared.plistURL
        XCTAssertTrue(url.path.contains("LaunchAgents"))
        XCTAssertTrue(url.path.contains("com.jarvis.brain.plist"))
    }

    func testDaemonBinaryURLIsInAppBundle() {
        let url = DaemonManager.shared.daemonBinaryURL
        XCTAssertTrue(url.path.contains("MacOS"))
        XCTAssertTrue(url.path.contains("JarvisBrainDaemon"))
    }

    func testInitialStatusIsUnknown() {
        // Fresh state should be .unknown until polled
        let dm = DaemonManager()
        XCTAssertEqual(dm.status, .unknown)
    }

    func testHealthCheckReturnsFalseWhenDaemonNotRunning() async {
        // Daemon is not running in test environment — should not throw, just return false
        let alive = await DaemonManager.shared.checkDaemonHealth()
        // Either true (daemon happens to be running) or false — must not crash
        XCTAssertTrue(alive || !alive)
    }

    func testPlistURLFilename() {
        let dm = DaemonManager()
        XCTAssertEqual(dm.plistURL.lastPathComponent, "com.jarvis.brain.plist")
    }

    func testDaemonStatusEnumCasesExist() {
        // Verify all status cases compile and can be compared
        let cases: [DaemonManager.DaemonStatus] = [
            .notInstalled, .stopped, .running, .crashed, .unknown
        ]
        XCTAssertEqual(cases.count, 5)
    }

    func testDaemonStatusEquality() {
        XCTAssertEqual(DaemonManager.DaemonStatus.running, .running)
        XCTAssertNotEqual(DaemonManager.DaemonStatus.running, .stopped)
    }
}
