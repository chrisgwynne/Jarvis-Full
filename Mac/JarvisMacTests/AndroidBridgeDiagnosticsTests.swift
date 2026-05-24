import XCTest
@testable import JarvisMac

/// Tests the heartbeat-derived diagnostic fields that drive the
/// `phoneBattery` answer.  The `phoneBattery` intent reads
/// AndroidBridgeDiagnostics directly — never the LLM, never the network
/// — so getting the shape and the offline-friendly `lastSeenDescription`
/// right is the whole user-visible contract.
final class AndroidBridgeDiagnosticsTests: XCTestCase {

    // MARK: - lastSeenDescription

    func test_lastSeenDescription_neverSeen() {
        var d = AndroidBridgeDiagnostics()
        d.lastHeartbeat = nil
        XCTAssertEqual(d.lastSeenDescription(), "never seen")
    }

    func test_lastSeenDescription_secondsAgo() {
        var d = AndroidBridgeDiagnostics()
        let now = Date()
        d.lastHeartbeat = now.addingTimeInterval(-15)
        XCTAssertEqual(d.lastSeenDescription(now: now), "15 seconds ago")
    }

    func test_lastSeenDescription_minutesAgo_singular() {
        var d = AndroidBridgeDiagnostics()
        let now = Date()
        d.lastHeartbeat = now.addingTimeInterval(-90) // 1.5 min → 1 minute
        XCTAssertEqual(d.lastSeenDescription(now: now), "1 minute ago")
    }

    func test_lastSeenDescription_minutesAgo_plural() {
        var d = AndroidBridgeDiagnostics()
        let now = Date()
        d.lastHeartbeat = now.addingTimeInterval(-12 * 60)
        XCTAssertEqual(d.lastSeenDescription(now: now), "12 minutes ago")
    }

    func test_lastSeenDescription_hoursAgo() {
        var d = AndroidBridgeDiagnostics()
        let now = Date()
        d.lastHeartbeat = now.addingTimeInterval(-3 * 3600)
        XCTAssertEqual(d.lastSeenDescription(now: now), "3 hours ago")
    }

    func test_lastSeenDescription_daysAgo() {
        var d = AndroidBridgeDiagnostics()
        let now = Date()
        d.lastHeartbeat = now.addingTimeInterval(-2 * 86400)
        XCTAssertEqual(d.lastSeenDescription(now: now), "2 days ago")
    }

    // MARK: - Field shape

    func test_chargingDefault_isNil() {
        XCTAssertNil(AndroidBridgeDiagnostics().isCharging)
    }

    func test_networkDefault_isUnknownString() {
        XCTAssertEqual(AndroidBridgeDiagnostics().network, "unknown")
    }

    func test_batteryLevelDefault_isNegativeSentinel() {
        XCTAssertEqual(AndroidBridgeDiagnostics().batteryLevel, -1)
    }
}
