import XCTest
@testable import JarvisMac

/// Tests the defensive `GeminiProvider.parseResponse(_:)` parser.
/// These are the response shapes that previously produced the misleading
/// "Decode error: Missing candidates[0].content.parts" — every one now
/// must yield a typed `GeminiProviderError` that names what actually
/// happened (MAX_TOKENS, SAFETY, function-call-only parts, etc.).
final class GeminiResponseParserTests: XCTestCase {

    /// Helper: parse a literal JSON string the way `performOnce` does.
    private func parse(_ jsonString: String)
        -> Result<(text: String, finishReason: String?), GeminiProviderError> {
        let data = Data(jsonString.utf8)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.malformedJSON("not a json object"))
        }
        return GeminiProvider.parseResponse(json)
    }

    // MARK: - Happy paths

    func test_normalSinglePartTextResponse_parses() {
        let r = parse("""
        {
          "candidates": [
            {
              "content": { "role": "model", "parts": [ { "text": "OK" } ] },
              "finishReason": "STOP"
            }
          ]
        }
        """)
        guard case .success(let parsed) = r else {
            return XCTFail("expected success, got \(r)")
        }
        XCTAssertEqual(parsed.text, "OK")
        XCTAssertEqual(parsed.finishReason, "STOP")
    }

    func test_multiplePartsAreConcatenated() {
        let r = parse("""
        {
          "candidates": [
            {
              "content": { "role": "model",
                           "parts": [ { "text": "Hello, " }, { "text": "world." } ] },
              "finishReason": "STOP"
            }
          ]
        }
        """)
        guard case .success(let parsed) = r else {
            return XCTFail("expected success, got \(r)")
        }
        XCTAssertEqual(parsed.text, "Hello, world.")
    }

    func test_textPartsAcrossMultipleCandidatesAreConcatenated() {
        // Rare but possible — Gemini will sometimes emit multi-candidate
        // responses when `candidateCount > 1`.  The parser must aggregate
        // text across every candidate so we never silently lose output.
        let r = parse("""
        {
          "candidates": [
            { "content": { "parts": [ { "text": "alpha " } ] }, "finishReason": "STOP" },
            { "content": { "parts": [ { "text": "beta" } ] },   "finishReason": "STOP" }
          ]
        }
        """)
        guard case .success(let parsed) = r else {
            return XCTFail("expected success, got \(r)")
        }
        XCTAssertEqual(parsed.text, "alpha beta")
    }

    func test_nonTextPartsAreIgnoredAlongsideText() {
        // Gemini may interleave a function-call part with text parts.
        // The function call has no `text` field — parser must skip it
        // but still emit the surrounding text.
        let r = parse("""
        {
          "candidates": [
            {
              "content": {
                "parts": [
                  { "text": "Sure — " },
                  { "functionCall": { "name": "lookup", "args": {} } },
                  { "text": "here you go." }
                ]
              },
              "finishReason": "STOP"
            }
          ]
        }
        """)
        guard case .success(let parsed) = r else {
            return XCTFail("expected success, got \(r)")
        }
        XCTAssertEqual(parsed.text, "Sure — here you go.")
    }

    // MARK: - The bug class — "200 OK but no text"

    func test_emptyCandidates_returnsNoCandidates() {
        let r = parse("""
        { "candidates": [] }
        """)
        guard case .failure(.noCandidates) = r else {
            return XCTFail("expected .noCandidates, got \(r)")
        }
    }

    func test_missingCandidatesKey_returnsNoCandidates() {
        // Some safety blocks return only promptFeedback with no candidates.
        // We treat that as promptBlocked when blockReason is present, and
        // noCandidates otherwise.
        let r = parse("""
        { "promptFeedback": { } }
        """)
        guard case .failure(.noCandidates) = r else {
            return XCTFail("expected .noCandidates, got \(r)")
        }
    }

    func test_candidateWithoutContent_returnsNoContentInCandidate() {
        let r = parse("""
        {
          "candidates": [ { "finishReason": "OTHER" } ]
        }
        """)
        guard case .failure(.noContentInCandidate(let fr)) = r else {
            return XCTFail("expected .noContentInCandidate, got \(r)")
        }
        XCTAssertEqual(fr, "OTHER")
    }

    func test_candidateWithContentButNoParts_returnsNoPartsInContent() {
        let r = parse("""
        {
          "candidates": [
            { "content": { "role": "model" }, "finishReason": "OTHER" }
          ]
        }
        """)
        guard case .failure(.noPartsInContent(let fr)) = r else {
            return XCTFail("expected .noPartsInContent, got \(r)")
        }
        XCTAssertEqual(fr, "OTHER")
    }

    func test_candidateWithEmptyParts_returnsNoPartsInContent() {
        let r = parse("""
        {
          "candidates": [
            { "content": { "parts": [] }, "finishReason": "OTHER" }
          ]
        }
        """)
        guard case .failure(.noPartsInContent(let fr)) = r else {
            return XCTFail("expected .noPartsInContent, got \(r)")
        }
        XCTAssertEqual(fr, "OTHER")
    }

    func test_partsHaveNoTextOrEmpty_returnsPartsHadNoText() {
        let r = parse("""
        {
          "candidates": [
            {
              "content": {
                "parts": [
                  { "functionCall": { "name": "x", "args": {} } },
                  { "text": "" }
                ]
              },
              "finishReason": "OTHER"
            }
          ]
        }
        """)
        guard case .failure(.partsHadNoText(let fr)) = r else {
            return XCTFail("expected .partsHadNoText, got \(r)")
        }
        XCTAssertEqual(fr, "OTHER")
    }

    // MARK: - Documented Gemini finish reasons

    func test_maxTokensWithNoText_returnsMaxTokensNoText() {
        // The headline bug.  Gemini hit max_tokens before any text part —
        // candidate exists, content exists, parts empty.  Must NOT be
        // reported as a generic decode error.
        let r = parse("""
        {
          "candidates": [
            { "content": { "parts": [] }, "finishReason": "MAX_TOKENS" }
          ]
        }
        """)
        guard case .failure(.maxTokensNoText) = r else {
            return XCTFail("expected .maxTokensNoText, got \(r)")
        }
    }

    func test_safetyBlocked_returnsSafetyBlockedWithRatings() {
        let r = parse("""
        {
          "candidates": [
            {
              "content": { "parts": [] },
              "finishReason": "SAFETY",
              "safetyRatings": [
                { "category": "HARM_CATEGORY_HARASSMENT",
                  "probability": "HIGH", "blocked": true }
              ]
            }
          ]
        }
        """)
        guard case .failure(.safetyBlocked(let fr, let safety)) = r else {
            return XCTFail("expected .safetyBlocked, got \(r)")
        }
        XCTAssertEqual(fr, "SAFETY")
        XCTAssertEqual(safety, ["HARM_CATEGORY_HARASSMENT=HIGH [BLOCKED]"])
    }

    func test_recitationBlocked_returnsSafetyBlocked() {
        let r = parse("""
        {
          "candidates": [
            { "content": { "parts": [] }, "finishReason": "RECITATION" }
          ]
        }
        """)
        if case .failure(.safetyBlocked(let fr, _)) = r {
            XCTAssertEqual(fr, "RECITATION")
        } else {
            XCTFail("expected .safetyBlocked, got \(r)")
        }
    }

    // MARK: - Prompt block (input rejected)

    func test_promptFeedbackBlockReason_returnsPromptBlocked() {
        let r = parse("""
        {
          "promptFeedback": {
            "blockReason": "SAFETY",
            "safetyRatings": [
              { "category": "HARM_CATEGORY_DANGEROUS_CONTENT",
                "probability": "HIGH", "blocked": true }
            ]
          }
        }
        """)
        guard case .failure(.promptBlocked(let reason, let safety)) = r else {
            return XCTFail("expected .promptBlocked, got \(r)")
        }
        XCTAssertEqual(reason, "SAFETY")
        XCTAssertEqual(safety, ["HARM_CATEGORY_DANGEROUS_CONTENT=HIGH [BLOCKED]"])
    }

    // MARK: - URL redaction (key never logged)

    func test_redactURL_replacesKeyQueryWithStars() {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=SECRETKEY123")
        let r = GeminiProvider.redact(url: url)
        XCTAssertFalse(r.contains("SECRETKEY123"))
        XCTAssertTrue(r.contains("key=***"))
        // Preserves the rest of the URL exactly.
        XCTAssertTrue(r.hasPrefix("https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent"))
    }

    func test_redactURL_preservesOtherQueryParams() {
        let url = URL(string: "https://example.com/x?key=ABC&foo=bar")
        let r = GeminiProvider.redact(url: url)
        XCTAssertTrue(r.contains("key=***"))
        XCTAssertTrue(r.contains("foo=bar"))
        XCTAssertFalse(r.contains("ABC"))
    }

    func test_redactURL_handlesURLWithoutKey() {
        let url = URL(string: "https://example.com/x?foo=bar")
        let r = GeminiProvider.redact(url: url)
        XCTAssertEqual(r, "https://example.com/x?foo=bar")
    }

    // MARK: - Request-body shape (disableThinking)

    func test_userMessage_includesActionableMaxTokensGuidance() {
        // The string the user sees when 2.5 thinking exhausts the budget.
        let msg = GeminiProviderError.maxTokensNoText.userMessage
        XCTAssertTrue(msg.contains("thinking"),
            "userMessage should mention thinking-token behaviour for 2.5 models. Got: \(msg)")
        XCTAssertTrue(msg.contains("maxOutputTokens"),
            "userMessage should mention the maxOutputTokens setting. Got: \(msg)")
    }

    // MARK: - Error → LLMError mapping

    func test_maxTokensError_mapsToLLMErrorDecode_withActionableMessage() {
        // Previously mapped to .empty, which surfaces as the generic
        // "Empty response" string — losing the actionable advice we
        // wrote in `userMessage`.  Now maps to `.decode(userMessage)`
        // so the user sees the full diagnostic.  Both `.decode` and
        // `.empty` are in `OpenAIChatClient.shouldRetry`'s no-retry set,
        // so this doesn't change retry / circuit semantics.
        let err = GeminiProviderError.maxTokensNoText.asLLMError
        guard case .decode(let msg) = err else {
            return XCTFail("expected .decode, got \(err)")
        }
        XCTAssertTrue(msg.contains("max output tokens"),
            "Mapped error must carry the actionable maxOutputTokens guidance. Got: \(msg)")
    }

    func test_safetyBlockedError_mapsToLLMErrorDecode() {
        let err = GeminiProviderError.safetyBlocked(finishReason: "SAFETY", safety: []).asLLMError
        if case .decode = err { return }
        XCTFail("expected .decode, got \(err)")
    }
}
