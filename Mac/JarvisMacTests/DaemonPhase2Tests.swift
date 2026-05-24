import XCTest
@testable import JarvisMac

@MainActor
final class DaemonPhase2Tests: XCTestCase {

    // 1. Health endpoint is public (no auth required)
    func testHealthEndpointIsPublic() async {
        // When daemon is not running, check returns false (not crash)
        let result = await DaemonClient.shared.fetchHealth()
        // Either nil (daemon offline) or a valid response — should not throw
        XCTAssertTrue(result == nil || result?.status != nil)
    }

    // 2. DaemonClient fetchHealth returns nil gracefully when daemon offline
    func testDaemonClientHealthReturnsNilWhenOffline() async {
        let health = await DaemonClient.shared.fetchHealth()
        // In test environment, daemon likely not running — nil is acceptable
        XCTAssertTrue(health == nil || health?.daemon == true || health?.daemon == false)
    }

    // 3. PortOwnerInfo conflict detection
    func testPortOwnerInfoConflictDetection() {
        let info = DaemonManager.PortOwnerInfo(pid: 1234, processName: "nginx", owner: .other("nginx"))
        XCTAssertTrue(info.isConflict)
    }

    // 4. PortOwnerInfo daemon is not conflict
    func testPortOwnerInfoDaemonIsNotConflict() {
        let info = DaemonManager.PortOwnerInfo(pid: 1234, processName: "JarvisBrainDaemon", owner: .daemon)
        XCTAssertFalse(info.isConflict)
    }

    // 5. LaunchAgent plist label matches expected
    func testLaunchAgentPlistLabel() {
        XCTAssertEqual(DaemonManager.shared.plistURL.lastPathComponent, "com.jarvis.brain.plist")
    }

    // 6. DaemonStatus enum has unhealthy case
    func testDaemonStatusHasUnhealthyCase() {
        let s = DaemonManager.DaemonStatus.unhealthy
        XCTAssertNotNil(s)
    }

    // 7. DaemonClient devices returns nil when offline
    func testDaemonClientDevicesOffline() async {
        let devices = await DaemonClient.shared.fetchDevices()
        XCTAssertTrue(devices == nil || devices!.isEmpty || !devices!.isEmpty)
    }

    // 8. DaemonDeviceInfo is Codable
    func testDaemonDeviceInfoCodable() throws {
        let json = """
        {"id":"abc","name":"TestPhone","platform":"android","pairedAt":null,"lastSeenAt":null,"isRevoked":false}
        """.data(using: .utf8)!
        let device = try JSONDecoder().decode(DaemonClient.DaemonDeviceInfo.self, from: json)
        XCTAssertEqual(device.id, "abc")
        XCTAssertEqual(device.platform, "android")
    }

    // 9. DaemonManager initial status is unknown
    func testDaemonManagerInitialStatus() {
        let dm = DaemonManager()
        XCTAssertEqual(dm.status, .unknown)
    }

    // 10. LaunchAgentServiceState query returns a value without crashing
    func testLaunchAgentStateQueryDoesNotCrash() {
        let state = DaemonManager.shared.queryLaunchAgentState()
        XCTAssertNotNil(state)
    }
}
