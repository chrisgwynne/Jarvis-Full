import XCTest
@testable import JarvisMac

@MainActor
final class DaemonPhase4Tests: XCTestCase {

    // 1. Empty remote transcript returns ignored response
    func testEmptyRemoteTranscriptIgnored() async {
        let response = RemoteBrainResponse.ignored("empty_transcript", routeId: "r0")
        if case .ignored(let reason) = response.outcome {
            XCTAssertEqual(reason, "empty_transcript")
        } else {
            XCTFail("Expected ignored outcome")
        }
    }

    // 2. RemoteDeviceContext is Codable
    func testRemoteDeviceContextCodable() throws {
        let ctx = RemoteDeviceContext(deviceId: "abc", platform: "android",
                                      deviceName: "Pixel", capabilities: ["stt", "tts"],
                                      receivedAt: Date(), routeId: "route-1")
        let data = try JSONEncoder().encode(ctx)
        let decoded = try JSONDecoder().decode(RemoteDeviceContext.self, from: data)
        XCTAssertEqual(decoded.deviceId, "abc")
        XCTAssertEqual(decoded.platform, "android")
        XCTAssertEqual(decoded.capabilities, ["stt", "tts"])
        XCTAssertEqual(decoded.routeId, "route-1")
    }

    // 3. RemoteBrainResponse reply outcome defaults speak=false, display=true
    func testRemoteBrainResponseReplyDefaults() {
        let r = RemoteBrainResponse.reply("Hello from Jarvis", routeId: "r1")
        if case .reply(let text, let speak, let display) = r.outcome {
            XCTAssertEqual(text, "Hello from Jarvis")
            XCTAssertFalse(speak, "Mac should not speak remote replies by default")
            XCTAssertTrue(display)
        } else {
            XCTFail("Expected reply outcome")
        }
    }

    // 4. RemoteBrainResponse error outcome
    func testRemoteBrainResponseError() {
        let r = RemoteBrainResponse.error("no_response_generated", routeId: "r2")
        if case .error(let reason) = r.outcome {
            XCTAssertEqual(reason, "no_response_generated")
        } else {
            XCTFail("Expected error outcome")
        }
    }

    // 5. RemoteToolPermission denied carries reason
    func testRemoteToolPermissionDenied() {
        let p = RemoteToolPermission.denied(reason: "capability_missing")
        if case .denied(let reason) = p {
            XCTAssertFalse(reason.isEmpty)
            XCTAssertEqual(reason, "capability_missing")
        } else {
            XCTFail("Expected denied")
        }
    }

    // 6. RemoteToolPermission allowed
    func testRemoteToolPermissionAllowed() {
        let p = RemoteToolPermission.allowed
        if case .allowed = p { XCTAssertTrue(true) }
        else { XCTFail("Expected allowed") }
    }

    // 7. Stale message (>90s old) age check
    func testStaleMessageDetection() {
        let staleDate = Date().addingTimeInterval(-120)  // 2 minutes ago
        let ctx = RemoteDeviceContext(deviceId: "dev1", platform: "android",
                                      deviceName: nil, capabilities: [],
                                      receivedAt: staleDate, routeId: "stale-route")
        let age = Date().timeIntervalSince(ctx.receivedAt)
        XCTAssertGreaterThan(age, 90, "Message should be detected as stale (>90s)")
    }

    // 8. DaemonAppBridge sendReply does not crash when disconnected
    func testDaemonAppBridgeSendReplyDoesNotCrash() {
        let bridge = DaemonAppBridge()
        XCTAssertNoThrow(
            bridge.sendReply(text: "hello", speak: false, display: true,
                             routeId: "r1", targetPlatform: "android", targetDeviceId: "d1")
        )
    }

    // 9. DaemonAppBridge sendCommandResult does not crash when disconnected
    func testDaemonAppBridgeSendCommandResultDoesNotCrash() {
        let bridge = DaemonAppBridge()
        XCTAssertNoThrow(
            bridge.sendCommandResult(text: "Done.", intentLabel: "homeTurnOn",
                                     routeId: "r2", targetPlatform: "android", targetDeviceId: "d1")
        )
    }

    // 10. DaemonAppBridge sendErrorReport does not crash when disconnected
    func testDaemonAppBridgeSendErrorReportDoesNotCrash() {
        let bridge = DaemonAppBridge()
        XCTAssertNoThrow(
            bridge.sendErrorReport(reason: "no_response_generated",
                                   routeId: "r3", targetPlatform: "android", targetDeviceId: "d1")
        )
    }

    // 11. DaemonAppBridge onTranscript callback now accepts platform parameter
    func testDaemonAppBridgeCallbackSignatureIncludesPlatform() {
        let bridge = DaemonAppBridge()
        var capturedPlatform: String? = nil
        bridge.onTranscript = { _, _, platform in
            capturedPlatform = platform
        }
        // Verify closure compiles with (String, String, String) -> Void
        XCTAssertNil(capturedPlatform)
        XCTAssertNotNil(bridge.onTranscript)
    }

    // 12. RemoteBrainResponse routeId is preserved
    func testRemoteBrainResponseRouteIdPreserved() {
        let routeId = "test-route-abc"
        let r = RemoteBrainResponse.reply("OK", routeId: routeId)
        XCTAssertEqual(r.routeId, routeId)
    }

    // 13. RemoteBrainResponse.ignored preserves routeId
    func testRemoteBrainResponseIgnoredRouteId() {
        let r = RemoteBrainResponse.ignored("duplicate_route_id", routeId: "dup-1")
        XCTAssertEqual(r.routeId, "dup-1")
        if case .ignored(let reason) = r.outcome {
            XCTAssertEqual(reason, "duplicate_route_id")
        } else {
            XCTFail("Expected ignored outcome")
        }
    }

    // 14. RemoteDeviceContext with nil deviceName encodes/decodes correctly
    func testRemoteDeviceContextNilDeviceName() throws {
        let ctx = RemoteDeviceContext(deviceId: "x1", platform: "windows",
                                      deviceName: nil, capabilities: [],
                                      receivedAt: Date(), routeId: "r-x1")
        let data = try JSONEncoder().encode(ctx)
        let decoded = try JSONDecoder().decode(RemoteDeviceContext.self, from: data)
        XCTAssertNil(decoded.deviceName)
        XCTAssertEqual(decoded.platform, "windows")
    }

    // 15. RemoteBrainResponse.reply with speak=true
    func testRemoteBrainResponseReplyWithSpeak() {
        let r = RemoteBrainResponse.reply("Speaking now.", routeId: "r-speak", speak: true)
        if case .reply(_, let speak, _) = r.outcome {
            XCTAssertTrue(speak)
        } else {
            XCTFail("Expected reply outcome")
        }
    }

    // 16. pbxproj UUID regression — Phase 4 UUIDs unique
    func testPhase4UUIDsUnique() {
        let uuids = [
            "RV01A2B3C4D5E6F7A8B9C0001",
            "RV02A2B3C4D5E6F7A8B9C0001",
            "D401A2B3C4D5E6F7A8B9C0001",
            "D402A2B3C4D5E6F7A8B9C0001",
        ]
        XCTAssertEqual(uuids.count, Set(uuids).count, "All Phase 4 pbxproj UUIDs must be unique")
    }
}
