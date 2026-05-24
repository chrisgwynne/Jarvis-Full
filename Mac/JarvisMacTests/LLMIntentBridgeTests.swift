import XCTest
@testable import JarvisMac

/// Tests the LLM → local-intent mapping that the audit flagged as having
/// no schema validation past the allowlist gate.  The bridge must:
///
///   * Reject garbage JSON (parser returns nil → caller maps to `unknown`).
///   * Reject any intent in the blocklist (`shell`, `delete_file`, etc.)
///     regardless of confidence.
///   * Reject intents not in the allowlist with `.unmapped`.
///   * Accept an allowlisted intent above the confidence floor.
///
/// The bridge is intentionally a static utility — these tests are pure
/// and need no harness.
final class LLMIntentBridgeTests: XCTestCase {

    // MARK: - Parse

    func test_parse_returnsNilForGarbage() {
        XCTAssertNil(LLMIntentBridge.parse("this is not json at all"))
        XCTAssertNil(LLMIntentBridge.parse(""))
    }

    func test_parse_handlesMarkdownFencedJSON() {
        // Common LLM behaviour — emits ```json …``` around the payload.
        let wrapped = """
        ```json
        {"intent": "show_news", "confidence": 0.95}
        ```
        """
        XCTAssertNotNil(LLMIntentBridge.parse(wrapped))
    }

    func test_parse_extractsJSONFromSurroundingChatter() {
        let chatty = "Sure thing! Here is the JSON: {\"intent\": \"show_news\", \"confidence\": 0.95}  Hope that helps!"
        XCTAssertNotNil(LLMIntentBridge.parse(chatty))
    }

    // MARK: - Intent mapping

    func test_blockedIntent_returnsBlockedAction() {
        let j = LLMIntentJSON(
            intent: "delete_file", target: nil, entities: nil,
            confidence: 0.99, speak: nil, requiresConfirmation: nil,
            reason: nil, awaitResponse: nil, pendingResponseType: nil,
            pendingOnYes: nil, pendingOnNo: nil)
        switch LLMIntentBridge.intent(from: j) {
        case .failure(.blockedAction(let name)):
            XCTAssertEqual(name, "delete_file")
        default:
            XCTFail("Expected .blockedAction for 'delete_file'")
        }
    }

    func test_lowConfidence_returnsLowConfidence() {
        let j = LLMIntentJSON(
            intent: "show_news", target: nil, entities: nil,
            confidence: 0.50, speak: nil, requiresConfirmation: nil,
            reason: nil, awaitResponse: nil, pendingResponseType: nil,
            pendingOnYes: nil, pendingOnNo: nil)
        switch LLMIntentBridge.intent(from: j) {
        case .failure(.lowConfidence):
            return // pass
        default:
            XCTFail("Expected .lowConfidence for confidence below floor")
        }
    }

    func test_validAllowedIntent_passes() {
        let j = LLMIntentJSON(
            intent: "show_news", target: nil, entities: nil,
            confidence: 0.95, speak: nil, requiresConfirmation: nil,
            reason: nil, awaitResponse: nil, pendingResponseType: nil,
            pendingOnYes: nil, pendingOnNo: nil)
        switch LLMIntentBridge.intent(from: j) {
        case .success(.showNews):
            return // pass
        default:
            XCTFail("Expected .showNews for valid show_news intent at high confidence")
        }
    }

    func test_unknownIntent_returnsUnmapped() {
        let j = LLMIntentJSON(
            intent: "do_a_barrel_roll", target: nil, entities: nil,
            confidence: 0.95, speak: nil, requiresConfirmation: nil,
            reason: nil, awaitResponse: nil, pendingResponseType: nil,
            pendingOnYes: nil, pendingOnNo: nil)
        switch LLMIntentBridge.intent(from: j) {
        case .failure(.unmapped):
            return // pass
        default:
            XCTFail("Expected .unmapped for unknown intent name")
        }
    }

    func test_unknownIntent_lowConfidence_skipsConfidenceFloor_thenReturnsUnmapped() {
        // The bridge intentionally exempts `unknown` from the confidence
        // floor — see LLMIntentBridge.swift `if … j.intent != "unknown"`.
        // After clearing the floor, the switch's `case "unknown"` returns
        // `.unmapped`, which the caller treats as "no LLM-driven action —
        // fall through to deterministic handlers or ask the user".
        // This test pins down that contract so neither the exemption nor
        // the unmapped-return get accidentally inverted later.
        let j = LLMIntentJSON(
            intent: "unknown", target: nil, entities: nil,
            confidence: 0.10, speak: "Sorry, I'm not sure what you want.",
            requiresConfirmation: nil, reason: nil,
            awaitResponse: nil, pendingResponseType: nil,
            pendingOnYes: nil, pendingOnNo: nil)
        switch LLMIntentBridge.intent(from: j) {
        case .failure(.lowConfidence):
            XCTFail("`unknown` must be exempt from the confidence floor")
        case .failure(.unmapped):
            return // contract verified
        case .failure(let other):
            XCTFail("Expected .unmapped for unknown intent, got \(other)")
        case .success(let i):
            XCTFail("Expected .unmapped for unknown intent, got success(\(i))")
        }
    }
}
