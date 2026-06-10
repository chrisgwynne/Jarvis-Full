import XCTest
import Foundation

// MARK: - ProtocolConformanceTests
//
// Executable protocol validation: every example in
// shared/contracts/ws-frame-examples.json must be accepted by the REAL daemon
// codec — DaemonMessageEnvelope (envelope-shaped frames) and
// DaemonFrameWrapper (flat client frames). The same contract file drives
// Android's BrainProtocolConformanceTest, so a frame-shape change that lands
// on one platform fails CI on the other.
//
// These tests compile against the actual daemon sources (the test target
// includes JarvisBrainDaemon minus main.swift — see project.yml), not
// replicas, so codec drift is a compile- or test-time failure.

final class ProtocolConformanceTests: XCTestCase {

    // MARK: Contract loading

    /// shared/contracts/ws-frame-examples.json, located relative to this
    /// source file so the tests track the repo checkout, not a copied fixture.
    private static let contract: [String: [String: Any]] = {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent()  // JarvisBrainDaemonTests/
            .deletingLastPathComponent()  // Mac/
            .deletingLastPathComponent()  // repo root
        let url = repoRoot
            .appendingPathComponent("shared/contracts/ws-frame-examples.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
            return [:]
        }
        return obj
    }()

    private func examples(_ group: String) throws -> [String: [String: Any]] {
        let g = try XCTUnwrap(Self.contract[group], "missing group '\(group)' in contract")
        return g.compactMapValues { $0 as? [String: Any] }
    }

    private func json(_ obj: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: obj)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    func testContractFileLoads() {
        XCTAssertFalse(Self.contract.isEmpty,
            "shared/contracts/ws-frame-examples.json missing or malformed")
        XCTAssertNotNil(Self.contract["client_to_mac"])
        XCTAssertNotNil(Self.contract["mac_to_client"])
    }

    // MARK: Envelope-shaped frames decode with the real envelope codec

    func testEnvelopeShapedExamplesDecodeAsDaemonMessageEnvelope() throws {
        for group in ["client_to_mac", "daemon_to_mac", "mac_to_daemon"] {
            for (name, example) in try examples(group) {
                // Envelope-shaped examples carry sourceDeviceId + target.
                guard example["sourceDeviceId"] != nil, example["target"] != nil else { continue }
                let data = try JSONSerialization.data(withJSONObject: example)
                let envelope = DaemonMessageEnvelope.decode(from: data)
                XCTAssertNotNil(envelope, "[\(group)/\(name)] failed to decode as DaemonMessageEnvelope")
                XCTAssertEqual(envelope?.type, example["type"] as? String, "[\(group)/\(name)] type mismatch")
                XCTAssertNotNil(envelope?.payload.objectValue, "[\(group)/\(name)] payload must be an object")
            }
        }
    }

    func testEnvelopeRoundTripPreservesTypeSourceAndTarget() throws {
        for group in ["client_to_mac", "daemon_to_mac", "mac_to_daemon"] {
            for (name, example) in try examples(group) {
                guard example["sourceDeviceId"] != nil, example["target"] != nil else { continue }
                let data = try JSONSerialization.data(withJSONObject: example)
                guard let envelope = DaemonMessageEnvelope.decode(from: data) else {
                    XCTFail("[\(group)/\(name)] decode failed"); continue
                }
                let reencoded = try XCTUnwrap(envelope.encode(), "[\(group)/\(name)] encode failed")
                let second = try XCTUnwrap(DaemonMessageEnvelope.decode(from: reencoded),
                                           "[\(group)/\(name)] re-decode failed")
                XCTAssertEqual(second.type, envelope.type, "[\(group)/\(name)]")
                XCTAssertEqual(second.sourceDeviceId, envelope.sourceDeviceId, "[\(group)/\(name)]")
                XCTAssertEqual(second.target, envelope.target, "[\(group)/\(name)]")
                XCTAssertEqual(second.payload, envelope.payload, "[\(group)/\(name)]")
            }
        }
    }

    func testCommActionTargetsResolveToConcreteDevices() throws {
        let execute = try XCTUnwrap(try examples("daemon_to_mac")["comm.action.execute"])
        let data = try JSONSerialization.data(withJSONObject: execute)
        let envelope = try XCTUnwrap(DaemonMessageEnvelope.decode(from: data))
        guard case .android(let deviceId) = envelope.target else {
            return XCTFail("comm.action.execute must target android, got \(envelope.target)")
        }
        XCTAssertEqual(deviceId, "pixel-7a")
        // Security invariant (PROTOCOL.md): comm actions forwarded to Android
        // always require confirmation.
        let payload = try XCTUnwrap(envelope.payload.objectValue)
        XCTAssertEqual(payload["requiresConfirmation"], .bool(true))
    }

    // MARK: Flat client frames wrap via the real DaemonFrameWrapper

    func testFlatClientFramesWrapIntoRoutableEnvelopes() throws {
        for (name, example) in try examples("client_to_mac") {
            guard example["sourceDeviceId"] == nil else { continue }  // envelope-shaped handled above
            let raw = try json(example)
            let result = DaemonFrameWrapper.prepare(
                rawJSON: raw, fromClientId: "client-uuid-1", platform: "android")
            guard case .wrappedFlat(let data) = result else {
                XCTFail("[\(name)] expected .wrappedFlat, got \(result)"); continue
            }
            let envelope = try XCTUnwrap(DaemonMessageEnvelope.decode(from: data),
                "[\(name)] wrapped frame must decode as DaemonMessageEnvelope")
            XCTAssertEqual(envelope.type, example["type"] as? String, "[\(name)] type must be preserved")
            // Flat frames carry their original fields in payload.
            let payload = try XCTUnwrap(envelope.payload.objectValue, "[\(name)]")
            XCTAssertEqual(payload["type"], .string(example["type"] as! String), "[\(name)]")
        }
    }

    func testTranscriptFinalWrapsWithCorrelationIdAndMacTarget() throws {
        let transcript = try XCTUnwrap(try examples("client_to_mac")["transcript.final"])
        let result = DaemonFrameWrapper.prepare(
            rawJSON: try json(transcript), fromClientId: "client-uuid-1", platform: "android")
        guard case .wrappedFlat(let data) = result else { return XCTFail("expected .wrappedFlat") }
        let envelope = try XCTUnwrap(DaemonMessageEnvelope.decode(from: data))
        XCTAssertEqual(envelope.type, "transcript.final")
        XCTAssertEqual(envelope.target, .macApp, "transcripts route to the Mac brain")
        XCTAssertEqual(envelope.sourceDeviceId, transcript["deviceId"] as? String,
            "deviceId from the frame wins over the connection clientId")
        XCTAssertEqual(envelope.correlationId, transcript["messageId"] as? String,
            "messageId becomes the correlationId the Mac echoes back")
    }

    func testReplyFramesWrapTowardTheOriginPlatform() throws {
        let macToClient = try examples("mac_to_client")
        let reply = try XCTUnwrap(macToClient["reply.final"])
        let result = DaemonFrameWrapper.prepare(
            rawJSON: try json(reply), fromClientId: "mac-client", platform: "mac")
        guard case .wrappedFlat(let data) = result else { return XCTFail("expected .wrappedFlat") }
        let envelope = try XCTUnwrap(DaemonMessageEnvelope.decode(from: data))
        XCTAssertEqual(envelope.type, "reply.final")
        XCTAssertEqual(envelope.correlationId, reply["routeId"] as? String,
            "routeId becomes the correlationId for reply routing")
    }

    func testPreWrappedEnvelopePassesThroughUnchanged() throws {
        let example = try XCTUnwrap(try examples("client_to_mac")["comm.event.received"])
        let raw = try json(example)
        let result = DaemonFrameWrapper.prepare(
            rawJSON: raw, fromClientId: "client-uuid-1", platform: "android")
        guard case .envelope(let data) = result else {
            return XCTFail("envelope-shaped frames must pass through, got \(result)")
        }
        let envelope = try XCTUnwrap(DaemonMessageEnvelope.decode(from: data))
        XCTAssertEqual(envelope.sourceDeviceId, example["sourceDeviceId"] as? String)
        XCTAssertEqual(envelope.type, "comm.event.received")
    }

    func testMalformedFramesAreRejectedNotCrashed() {
        for bad in ["", "not json", "[1,2,3]", "\"a string\"", "{truncated"] {
            let result = DaemonFrameWrapper.prepare(
                rawJSON: bad, fromClientId: "c", platform: "android")
            guard case .malformed = result else {
                return XCTFail("'\(bad)' should be .malformed, got \(result)")
            }
        }
    }

    func testOversizedEnvelopeIsRejected() throws {
        // The envelope codec enforces a 256 KB cap.
        let big = String(repeating: "x", count: 300 * 1024)
        let obj: [String: Any] = [
            "id": "1", "type": "context.update", "sourceDeviceId": "d",
            "sourcePlatform": "android", "target": ["type": "daemon"],
            "timestamp": "2026-05-24T10:00:00Z", "payload": ["value": big],
        ]
        let data = try JSONSerialization.data(withJSONObject: obj)
        XCTAssertNil(DaemonMessageEnvelope.decode(from: data), "oversized frames must be dropped")
    }
}
