import XCTest
@testable import JarvisMac

/// Tests `GeminiProvider` request-construction surface — URL building,
/// missing-key handling, model resolution, and JSON-mode opt-in.  None
/// of these hit the network; the provider's `buildEndpointURL` and
/// availability helpers are sufficient to lock in the contract.
final class GeminiProviderTests: XCTestCase {

    // MARK: - URL building

    func test_buildEndpointURL_appendsModelAndKey() throws {
        let p = makeProvider(baseURL: "https://generativelanguage.googleapis.com/v1beta",
                             model: "gemini-1.5-flash",
                             key: "TESTKEY123")
        let url = try p.buildEndpointURL(model: "gemini-1.5-flash", apiKey: "TESTKEY123")
        XCTAssertEqual(url.absoluteString,
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=TESTKEY123")
    }

    func test_buildEndpointURL_stripsTrailingSlash() throws {
        let p = makeProvider(baseURL: "https://generativelanguage.googleapis.com/v1beta/",
                             model: "gemini-2.5-pro",
                             key: "K")
        let url = try p.buildEndpointURL(model: "gemini-2.5-pro", apiKey: "K")
        XCTAssertEqual(url.host, "generativelanguage.googleapis.com")
        XCTAssertTrue(url.path.contains("/v1beta/models/gemini-2.5-pro:generateContent"))
    }

    func test_buildEndpointURL_throws_onEmptyBase() {
        let p = makeProvider(baseURL: "", model: "gemini-1.5-flash", key: "K")
        XCTAssertThrowsError(try p.buildEndpointURL(model: "gemini-1.5-flash", apiKey: "K"))
    }

    func test_buildEndpointURL_acceptsFutureModelNames() throws {
        // Forward compat — any model identifier the user types must produce a
        // valid URL.  No hardcoded model enum exists in production.
        let p = makeProvider(baseURL: "https://generativelanguage.googleapis.com/v1beta",
                             model: "gemini-3.0-ultra-2026",
                             key: "K")
        let url = try p.buildEndpointURL(model: "gemini-3.0-ultra-2026", apiKey: "K")
        XCTAssertTrue(url.absoluteString.contains("gemini-3.0-ultra-2026"))
    }

    // MARK: - Availability

    func test_isAvailable_false_whenDisabled() async {
        let p = makeProvider(baseURL: "https://x", model: "m", key: "K", enabled: false)
        let avail = await p.isAvailable()
        XCTAssertFalse(avail)
    }

    func test_isAvailable_false_whenKeyMissing() async {
        let p = makeProvider(baseURL: "https://x", model: "m", key: nil, enabled: true)
        let avail = await p.isAvailable()
        XCTAssertFalse(avail)
    }

    func test_isAvailable_false_whenModelEmpty() async {
        let p = makeProvider(baseURL: "https://x", model: "", key: "K", enabled: true)
        let avail = await p.isAvailable()
        XCTAssertFalse(avail)
    }

    func test_isAvailable_true_whenFullyConfigured() async {
        let p = makeProvider(baseURL: "https://x", model: "gemini-1.5-flash", key: "K", enabled: true)
        let avail = await p.isAvailable()
        XCTAssertTrue(avail)
    }

    // MARK: - Missing-key path on complete()

    func test_complete_missingKey_throwsNotConfigured() async {
        let p = makeProvider(baseURL: "https://x", model: "gemini-1.5-flash", key: nil, enabled: true)
        do {
            _ = try await p.complete(LLMRequest(
                systemPrompt: "hi", userPrompt: "hi",
                temperature: 0.1, maxTokens: 8, timeoutSeconds: 5))
            XCTFail("Expected throw")
        } catch LLMError.notConfigured {
            // pass
        } catch {
            XCTFail("Expected .notConfigured, got \(error)")
        }
    }

    func test_complete_disabled_throwsProviderDisabled() async {
        let p = makeProvider(baseURL: "https://x", model: "m", key: "K", enabled: false)
        do {
            _ = try await p.complete(LLMRequest(
                systemPrompt: "hi", userPrompt: "hi",
                temperature: 0.1, maxTokens: 8, timeoutSeconds: 5))
            XCTFail("Expected throw")
        } catch LLMError.providerDisabled {
            // pass
        } catch {
            XCTFail("Expected .providerDisabled, got \(error)")
        }
    }

    // MARK: - Helpers

    private func makeProvider(baseURL: String,
                              model: String,
                              key: String?,
                              enabled: Bool = true) -> GeminiProvider {
        GeminiProvider(
            baseURL:     { baseURL },
            modelName:   { model },
            visionModel: { model },
            enabled:     { enabled },
            apiKey:      { key }
        )
    }
}
