import XCTest
@testable import JarvisMac

@MainActor
final class DaemonPhase3Tests: XCTestCase {

    // 1. DaemonMessageEnvelope decodes valid JSON
    func testEnvelopeDecodesValidJSON() throws {
        let json = """
        {"id":"abc","type":"transcript.final","sourceDeviceId":"phone1",
         "sourcePlatform":"android","target":{"type":"macApp"},
         "timestamp":"2025-01-01T00:00:00Z","correlationId":null,
         "payload":{"transcript":"hello jarvis"}}
        """.data(using: .utf8)!
        let env = DaemonMessageEnvelope.decode(from: json)
        XCTAssertNotNil(env)
        XCTAssertEqual(env?.type, "transcript.final")
        XCTAssertEqual(env?.sourcePlatform, "android")
    }

    // 2. DaemonMessageEnvelope returns nil on malformed JSON
    func testEnvelopeReturnNilOnMalformedJSON() {
        let bad = "not json at all".data(using: .utf8)!
        XCTAssertNil(DaemonMessageEnvelope.decode(from: bad))
    }

    // 3. DaemonMessageEnvelope rejects oversized payload
    func testEnvelopeRejectsOversizedPayload() {
        let huge = Data(repeating: 0x41, count: 300 * 1024)
        XCTAssertNil(DaemonMessageEnvelope.decode(from: huge))
    }

    // 4. JSONValue round-trips string
    func testJSONValueStringRoundTrip() throws {
        let v = JSONValue.string("hello")
        let data = try JSONEncoder().encode(v)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(decoded, v)
    }

    // 5. JSONValue handles null
    func testJSONValueNull() throws {
        let v = JSONValue.null
        let data = try JSONEncoder().encode(v)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(decoded, v)
    }

    // 6. DaemonOfflineQueue caps at 50
    func testOfflineQueueCapAt50() {
        // Reset by draining first
        _ = DaemonOfflineQueue.shared.drain()

        // Create 51 transcript.final envelopes
        for i in 0..<51 {
            let env = DaemonMessageEnvelope.make(
                type: "transcript.final",
                target: .macApp,
                payload: .object(["transcript": .string("test \(i)")])
            )
            DaemonOfflineQueue.shared.enqueue(env)
        }
        // Queue caps at 50
        let depth = DaemonOfflineQueue.shared.depth
        XCTAssertLessThanOrEqual(depth, 50)
        _ = DaemonOfflineQueue.shared.drain()
    }

    // 7. DaemonOfflineQueue does not queue heartbeat
    func testOfflineQueueSkipsHeartbeat() {
        _ = DaemonOfflineQueue.shared.drain()
        let env = DaemonMessageEnvelope.make(type: "heartbeat", target: .daemon)
        DaemonOfflineQueue.shared.enqueue(env)
        XCTAssertEqual(DaemonOfflineQueue.shared.depth, 0)
    }

    // 8. DaemonOfflineQueue does not queue presence.update
    func testOfflineQueueSkipsPresenceUpdate() {
        _ = DaemonOfflineQueue.shared.drain()
        let env = DaemonMessageEnvelope.make(type: "presence.update", target: .broadcast)
        DaemonOfflineQueue.shared.enqueue(env)
        XCTAssertEqual(DaemonOfflineQueue.shared.depth, 0)
    }

    // 9. DaemonMessageTarget macApp encodes/decodes correctly
    func testMessageTargetMacAppCoding() throws {
        let target = DaemonMessageTarget.macApp
        let data = try JSONEncoder().encode(target)
        let decoded = try JSONDecoder().decode(DaemonMessageTarget.self, from: data)
        XCTAssertEqual(decoded, target)
    }

    // 10. DaemonMessageTarget android with deviceId encodes/decodes
    func testMessageTargetAndroidCoding() throws {
        let target = DaemonMessageTarget.android(deviceId: "phone1")
        let data = try JSONEncoder().encode(target)
        let decoded = try JSONDecoder().decode(DaemonMessageTarget.self, from: data)
        XCTAssertEqual(decoded, target)
    }

    // 11. DaemonAppBridge shared exists
    func testDaemonAppBridgeExists() {
        XCTAssertNotNil(DaemonAppBridge.shared)
    }

    // 12. DaemonAppBridge initial state is not connected
    func testDaemonAppBridgeInitiallyDisconnected() {
        let bridge = DaemonAppBridge()
        XCTAssertFalse(bridge.isConnected)
    }

    // 13. DaemonMessageRouter snapshot returns values without crash
    func testRouterSnapshotDoesNotCrash() {
        let snap = DaemonMessageRouter.shared.snapshot()
        XCTAssertGreaterThanOrEqual(snap.routedMessageCount, 0)
        XCTAssertGreaterThanOrEqual(snap.offlineQueueDepth, 0)
    }

    // 14. DaemonMessageEnvelope.make creates valid envelope
    func testMakeEnvelope() {
        let env = DaemonMessageEnvelope.make(type: "test.type", target: .macApp)
        XCTAssertEqual(env.type, "test.type")
        XCTAssertEqual(env.sourceDeviceId, "daemon")
        XCTAssertEqual(env.sourcePlatform, "daemon")
        XCTAssertFalse(env.id.isEmpty)
    }

    // 15. DaemonOfflineQueue drain returns all queued items
    func testOfflineQueueDrainReturnsAll() {
        _ = DaemonOfflineQueue.shared.drain()
        let env1 = DaemonMessageEnvelope.make(type: "transcript.final", target: .macApp)
        let env2 = DaemonMessageEnvelope.make(type: "tool.result", target: .macApp)
        DaemonOfflineQueue.shared.enqueue(env1)
        DaemonOfflineQueue.shared.enqueue(env2)
        let drained = DaemonOfflineQueue.shared.drain()
        XCTAssertEqual(drained.count, 2)
        XCTAssertEqual(DaemonOfflineQueue.shared.depth, 0)
    }
}
