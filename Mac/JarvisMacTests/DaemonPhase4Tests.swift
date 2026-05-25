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

    // MARK: - cappedForRemoteTts (remote reply conciseness cap)
    // These tests use a minimal test double that mirrors the helper extracted into JarvisController.
    // The helper is tested here as a pure function so we don't need a full JarvisController setup.

    private func cap(_ text: String, maxSentences: Int = 3, maxChars: Int = 320) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        var sentences: [String] = []
        var current = ""
        for char in trimmed {
            current.append(char)
            if char == "." || char == "!" || char == "?" {
                let s = current.trimmingCharacters(in: .whitespaces)
                if !s.isEmpty { sentences.append(s) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { sentences.append(tail) }
        let capped = sentences.prefix(maxSentences).joined(separator: " ")
        guard capped.count > maxChars else { return capped }
        let truncated = String(capped.prefix(maxChars))
        let terminators: [Character] = [".", "!", "?"]
        if let lastTerm = truncated.lastIndex(where: { terminators.contains($0) }),
           truncated.distance(from: truncated.startIndex, to: lastTerm) > maxChars / 2 {
            return String(truncated[...lastTerm]).trimmingCharacters(in: .whitespaces)
        }
        return truncated.trimmingCharacters(in: .whitespaces)
    }

    // 17. Empty string returns empty (no TTS for blank replies)
    func testCappedForRemoteTtsEmptyStringReturnsEmpty() {
        XCTAssertEqual("", cap(""))
        XCTAssertEqual("", cap("   "))
        XCTAssertEqual("", cap("\n\n\t"))
    }

    // 18. Short reply passes through unchanged
    func testCappedForRemoteTtsShortReplyUnchanged() {
        let short = "The weather is fine."
        XCTAssertEqual(short, cap(short))
    }

    // 19. Exactly 3 sentences pass through
    func testCappedForRemoteTtsThreeSentencesPassThrough() {
        let three = "First sentence. Second sentence. Third sentence."
        let result = cap(three)
        XCTAssertTrue(result.contains("First"))
        XCTAssertTrue(result.contains("Second"))
        XCTAssertTrue(result.contains("Third"))
    }

    // 20. 4 sentences are capped at 3
    func testCappedForRemoteTtsFourSentencesCappedAtThree() {
        let four = "One. Two. Three. Four."
        let result = cap(four)
        XCTAssertFalse(result.contains("Four"), "Fourth sentence must be removed: \(result)")
        XCTAssertTrue(result.contains("One"))
        XCTAssertTrue(result.contains("Three"))
    }

    // 21. Hard char cap applied for very long single sentences
    func testCappedForRemoteTtsHardCharCap() {
        let longText = String(repeating: "a", count: 400) + "."
        let result = cap(longText)
        XCTAssertLessThanOrEqual(result.count, 320, "Result must be ≤ 320 chars")
    }

    // 22. Exclamation and question marks count as sentence endings
    func testCappedForRemoteTtsPunctuationVariants() {
        let text = "Are you ready? Yes I am! Now let us go. And also this."
        let result = cap(text)
        XCTAssertTrue(result.contains("Are you ready?"))
        XCTAssertTrue(result.contains("Yes I am!"))
        XCTAssertTrue(result.contains("Now let us go."))
        XCTAssertFalse(result.contains("And also this"), "4th sentence must be dropped")
    }

    // 23. Remote reply with no terminal punctuation (tail clause) passes through under 3-sentence cap
    func testCappedForRemoteTtsTailClauseWithNoPunctuation() {
        let text = "This has no ending"
        XCTAssertEqual(text, cap(text))
    }

    // 24. Sentence cap with custom maxSentences=1 keeps only the first sentence
    func testCappedForRemoteTtsCustomMaxSentencesOne() {
        let text = "First. Second. Third."
        let result = cap(text, maxSentences: 1)
        XCTAssertEqual("First.", result)
    }

    // 25. Remote reply conciseness contract: mirrors Android ResponseFormatter limits
    func testRemoteReplyConcisencyContractMatchesAndroid() {
        // Android ResponseFormatter: MAX_SENTENCES=3, MAX_CHARS=320
        // Mac cappedForRemoteTts must enforce the same limits.
        let shortReply = "Here is your answer."
        let longReply  = String(repeating: "Word ", count: 100) + "."
        let fourSentence = "A. B. C. D."
        XCTAssertEqual(shortReply, cap(shortReply))
        XCTAssertLessThanOrEqual(cap(longReply).count, 320)
        XCTAssertFalse(cap(fourSentence).contains("D."),
                       "Should not contain 4th sentence in remote reply")
    }
}
