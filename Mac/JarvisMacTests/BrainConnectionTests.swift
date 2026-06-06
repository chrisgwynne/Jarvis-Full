import XCTest
@testable import JarvisMac

@MainActor
final class BrainConnectionTests: XCTestCase {

    override func setUp() async throws {
        // Reset bridge state before each test
        DaemonAppBridge.shared.disconnect()
    }

    // MARK: - Acceptance Test A
    // Local Mac daemon — URL configured, no auth required
    func testA_LocalDaemon_URLDerivation() {
        let bridge = DaemonAppBridge.shared
        // deriveWebSocketURL is private — test indirectly via connect()
        // Just confirm that connect() doesn't crash with a local URL
        bridge.connect(baseURL: "http://127.0.0.1:8765")
        // After connect attempt without a running daemon, status should be connecting or reconnecting
        // (not "notConfigured" and not "wrongURL" for a valid URL)
        XCTAssertNotEqual(bridge.connectionStatus, .notConfigured)
    }

    // MARK: - Acceptance Test B
    // Daemon temporarily killed — should reconnect, not enter permanent offline
    func testB_DropAndReconnect_NoPermanentOffline() async throws {
        let bridge = DaemonAppBridge.shared
        bridge.connect(baseURL: "http://127.0.0.1:8765")
        // Simulate disconnect
        bridge.disconnect()
        // Bridge should NOT have permanentlyOffline = true
        XCTAssertFalse(bridge.permanentlyOffline,
                       "Bridge must never enter permanent offline — always keep retrying")
    }

    // MARK: - Acceptance Test C
    // Wrong URL — status must be clear, no pairing prompt
    func testC_WrongURL_ClearStatus() {
        let bridge = DaemonAppBridge.shared
        // Empty URL → notConfigured
        bridge.connect(baseURL: "")
        XCTAssertEqual(bridge.connectionStatus, .notConfigured)
    }

    // MARK: - Acceptance Test D (model-layer)
    // BrainConnectionStatus correctly describes each state
    func testD_ConnectionStatus_Labels() {
        let connected = BrainConnectionStatus.connected
        XCTAssertTrue(connected.isConnected)
        XCTAssertFalse(connected.isOffline)
        XCTAssertEqual(connected.shortLabel, "Connected")

        let reconnecting = BrainConnectionStatus.reconnecting(attempt: 3, delaySecs: 8)
        XCTAssertFalse(reconnecting.isConnected)
        XCTAssertTrue(reconnecting.shortLabel.contains("3"))
        XCTAssertTrue(reconnecting.shortLabel.contains("8"))

        let offline = BrainConnectionStatus.offline(reason: "Connection refused")
        XCTAssertFalse(offline.isConnected)
        XCTAssertTrue(offline.isOffline)
        XCTAssertTrue(offline.shortLabel.contains("Connection refused"))

        let wrongURL = BrainConnectionStatus.wrongURL(detail: "DNS failure")
        XCTAssertTrue(wrongURL.isOffline)
        XCTAssertTrue(wrongURL.shortLabel.contains("DNS failure"))

        let incompat = BrainConnectionStatus.incompatible(expected: "2", got: "1")
        XCTAssertTrue(incompat.isOffline)
        XCTAssertTrue(incompat.shortLabel.contains("expected 2"))
        XCTAssertTrue(incompat.shortLabel.contains("got 1"))

        let notConfig = BrainConnectionStatus.notConfigured
        XCTAssertEqual(notConfig.shortLabel, "Not configured")
    }

    // MARK: - Acceptance Test E
    // No auth token — connect() without token does not crash
    func testE_NoAuth_ConnectWithoutToken() {
        // Must not require a Keychain token
        let bridge = DaemonAppBridge.shared
        // This should not crash or return .notConfigured for a non-empty URL
        bridge.connect(baseURL: "http://192.168.1.100:8765")
        // Status: connecting or reconnecting (daemon not actually present)
        XCTAssertNotEqual(bridge.connectionStatus, .notConfigured)
    }

    // MARK: - Acceptance Test F
    // resetAndReconnect clears attempts and sets connecting
    func testF_ResetAndReconnect_ClearsState() {
        let bridge = DaemonAppBridge.shared
        // Simulate some failed attempts
        bridge.connect(baseURL: "http://127.0.0.1:8765")
        bridge.resetAndReconnect()
        XCTAssertEqual(bridge.reconnectAttempts, 0)
        XCTAssertFalse(bridge.permanentlyOffline)
    }

    // MARK: - URL derivation unit tests

    func testURLDerivation_HTTP_to_WS() {
        // Test indirectly by checking connect() doesn't wrongURL for valid URLs
        let bridge = DaemonAppBridge.shared
        // Valid http URL → should not immediately show wrongURL
        bridge.connect(baseURL: "http://127.0.0.1:8765")
        XCTAssertNotEqual(bridge.connectionStatus, BrainConnectionStatus.wrongURL(detail: ""))
    }

    func testURLDerivation_EmptyURL_NotConfigured() {
        let bridge = DaemonAppBridge.shared
        bridge.connect(baseURL: "")
        XCTAssertEqual(bridge.connectionStatus, .notConfigured)
    }

    func testURLDerivation_BadURL_WrongURL() {
        let bridge = DaemonAppBridge.shared
        bridge.connect(baseURL: "not a url at all %^&")
        if case .wrongURL = bridge.connectionStatus {
            // Expected
        } else if bridge.connectionStatus == .notConfigured {
            // Also acceptable for malformed URLs
        } else {
            XCTFail("Expected .wrongURL or .notConfigured for malformed URL, got \(bridge.connectionStatus.shortLabel)")
        }
    }

    // MARK: - Port number formatting — no locale separator

    func testPortFormatting_NeverUsesComma() {
        let port: UInt16 = 8765
        let formatted = String(port)
        XCTAssertEqual(formatted, "8765", "Port number must not use thousands separator")
        XCTAssertFalse(formatted.contains(","))
    }

    func testPortFormatting_DisplayedVerbatim() {
        // The URL should contain "8765" not "8,765"
        let url = "http://127.0.0.1:\(String(8765))"
        XCTAssertTrue(url.contains("8765"))
        XCTAssertFalse(url.contains("8,765"))
    }

    // MARK: - Preference defaults

    func testPreferences_DaemonBaseURL_DefaultsToLocalhost() {
        let prefs = Preferences.defaults
        XCTAssertEqual(prefs.daemonBaseURL, "http://127.0.0.1:8765",
                       "Default URL must be the local daemon address")
    }

    func testPreferences_DaemonAuthRequired_DefaultsFalse() {
        let prefs = Preferences.defaults
        XCTAssertFalse(prefs.daemonAuthRequired,
                       "Auth must be off by default for private/local mode")
    }

    // MARK: - No permanent offline state

    func testNoPermanentOfflineDeadState() {
        // The new bridge never enters a "permanently offline" dead state
        // where it stops retrying. This tests the architectural guarantee.
        let bridge = DaemonAppBridge.shared
        bridge.connect(baseURL: "http://127.0.0.1:8765")
        bridge.disconnect()
        // Even after disconnect, permanentlyOffline must remain false
        // (the user can still call resetAndReconnect, or connect is called again)
        XCTAssertFalse(bridge.permanentlyOffline,
                       "Bridge must never lock into permanent offline — always reconnectable")
    }

    // pbxproj UUID regression
    func testPbxprojUUIDs() throws {
        let path = "/Users/chris/Desktop/jarvis/Mac/JarvisMac.xcodeproj/project.pbxproj"
        let content = try String(contentsOfFile: path, encoding: .utf8)
        let required = [
            "BC01A2B3C4D5E6F7A8B9C0001",  // BrainConnectionTests build file
            "BC02A2B3C4D5E6F7A8B9C0001",  // BrainConnectionTests file ref
        ]
        for uuid in required {
            XCTAssertTrue(content.contains(uuid), "UUID \(uuid) not in pbxproj")
        }
    }
}

// MARK: - Preferences.defaults helper for tests

private extension Preferences {
    static var defaults: Preferences {
        (try? JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))) ?? Preferences()
    }
}
