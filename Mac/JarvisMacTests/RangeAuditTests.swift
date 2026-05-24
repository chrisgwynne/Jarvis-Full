import XCTest
@testable import JarvisMac

@MainActor
final class RangeAuditTests: XCTestCase {

    // 1. Empty memory summary does not crash
    func testEmptyMemorySummaryDoesNotCrash() {
        XCTAssertNoThrow("".safePreview())
        XCTAssertEqual("".safePreview(), "")
    }

    // 2. One-character summary does not crash
    func testOneCharacterSummaryDoesNotCrash() {
        XCTAssertNoThrow("A".safePreview(160))
        XCTAssertEqual("A".safePreview(160), "A")
    }

    // 3. Very long summary truncates safely
    func testVeryLongSummaryTruncatesSafely() {
        let long = String(repeating: "x", count: 10_000)
        let preview = long.safePreview(160)
        XCTAssertEqual(preview.count, 160)
    }

    // 4. safelyTruncated with maxLength 0 returns empty
    func testSafelyTruncatedZeroReturnsEmpty() {
        XCTAssertEqual("hello".safelyTruncated(to: 0), "")
    }

    // 5. safelyTruncated with negative maxLength returns empty
    func testSafelyTruncatedNegativeReturnsEmpty() {
        XCTAssertEqual("hello".safelyTruncated(to: -5), "")
    }

    // 6. safePrefix on empty collection returns empty
    func testSafePrefixOnEmptyCollection() {
        let arr: [Int] = []
        XCTAssertEqual(Array(arr.safePrefix(10)), [])
    }

    // 7. safePrefix with 0 returns empty
    func testSafePrefixZeroReturnsEmpty() {
        let arr = [1, 2, 3]
        XCTAssertEqual(Array(arr.safePrefix(0)), [])
    }

    // 8. safePrefix with count larger than array returns full array
    func testSafePrefixLargerThanCountReturnsFull() {
        let arr = [1, 2, 3]
        XCTAssertEqual(Array(arr.safePrefix(100)), [1, 2, 3])
    }

    // 9. safe subscript on array returns nil for out-of-bounds
    func testSafeSubscriptOutOfBoundsReturnsNil() {
        let arr = [1, 2, 3]
        XCTAssertNil(arr[safe: 5])
        XCTAssertEqual(arr[safe: 0], 1)
    }

    // 10. safePreview trims whitespace from both ends
    func testSafePreviewTrimsBothEnds() {
        let s = "   hello world   "
        XCTAssertEqual(s.safePreview(), "hello world")
    }

    // MARK: - Gemini / Summarisation safety tests (Fix 1, 2, 3)

    // 11. Gemini 404 handling — safe preview of model name does not crash
    func testGemini404SafePreviewModelName() {
        // Simulates the diagnostic path when a 404 fires and we log the model name.
        let modelName = "gemini-1.5-flash"
        let result = modelName.safePreview(160)
        XCTAssertFalse(result.isEmpty)
        XCTAssertEqual(result, "gemini-1.5-flash")
    }

    // 12. safePreview on empty string returns empty
    func testSafePreviewEmptyString() {
        XCTAssertEqual("".safePreview(), "")
    }

    // 13. safePreview on whitespace-only returns empty
    func testSafePreviewWhitespaceOnly() {
        XCTAssertEqual("   \n\t  ".safePreview(), "")
    }

    // 14. safePreview truncates a 500-char string to 160
    func testSafePreviewTruncatesLongString() {
        let long = String(repeating: "a", count: 500)
        let preview = long.safePreview(160)
        XCTAssertEqual(preview.count, 160)
    }

    // 15. safePreview with maxLength 0 returns empty
    func testSafePreviewZeroMaxLength() {
        XCTAssertEqual("hello".safePreview(0), "")
    }

    // 16. safePrefix on empty collection returns empty array
    func testSafePrefixEmptyCollectionNew() {
        let empty: [Int] = []
        XCTAssertEqual(Array(empty.safePrefix(10)), [])
    }

    // 17. safePrefix with 0 count returns empty
    func testSafePrefixZeroCount() {
        XCTAssertEqual(Array([1, 2, 3].safePrefix(0)), [])
    }

    // 18. safePrefix larger than collection returns all elements
    func testSafePrefixLargerThanCollection() {
        XCTAssertEqual(Array([1, 2, 3].safePrefix(100)), [1, 2, 3])
    }

    // 19. safelyTruncated with negative length returns empty
    func testSafelyTruncatedNegativeLengthReturnsEmpty() {
        XCTAssertEqual("hello".safelyTruncated(to: -1), "")
    }

    // 20. Known Gemini fallback models list is non-empty and contains 2.0-flash
    func testGeminiFallbackModelsNonEmpty() {
        let fallbacks = GeminiProvider.knownFallbackModels
        XCTAssertFalse(fallbacks.isEmpty, "Fallback model list must not be empty")
        XCTAssertTrue(fallbacks.contains("gemini-2.0-flash"),
                      "gemini-2.0-flash must be in the fallback list")
    }
}
