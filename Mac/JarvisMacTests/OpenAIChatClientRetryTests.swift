import XCTest
@testable import JarvisMac

/// Tests the retry classification added in Phase 3A.  The goal is purely
/// to lock in the table — which `LLMError` cases are retryable vs not.
/// Actual network behaviour is covered by integration tests (not yet
/// scaffolded) since it requires a controllable URLProtocol stub.
final class OpenAIChatClientRetryTests: XCTestCase {

    // MARK: - Retryable

    func test_rateLimited_isRetryable() {
        XCTAssertTrue(OpenAIChatClient.shouldRetry(error: .rateLimited))
    }

    func test_timeout_isRetryable() {
        XCTAssertTrue(OpenAIChatClient.shouldRetry(error: .timeout))
    }

    func test_network_isRetryable() {
        XCTAssertTrue(OpenAIChatClient.shouldRetry(error: .network("connection lost")))
    }

    func test_5xx_isRetryable() {
        XCTAssertTrue(OpenAIChatClient.shouldRetry(error: .http(500, "")))
        XCTAssertTrue(OpenAIChatClient.shouldRetry(error: .http(502, "")))
        XCTAssertTrue(OpenAIChatClient.shouldRetry(error: .http(503, "")))
        XCTAssertTrue(OpenAIChatClient.shouldRetry(error: .http(504, "")))
    }

    // MARK: - Not retryable

    func test_4xx_isNotRetryable() {
        // Bad request / auth — won't fix itself with another attempt.
        XCTAssertFalse(OpenAIChatClient.shouldRetry(error: .http(400, "")))
        XCTAssertFalse(OpenAIChatClient.shouldRetry(error: .http(401, "")))
        XCTAssertFalse(OpenAIChatClient.shouldRetry(error: .http(403, "")))
        XCTAssertFalse(OpenAIChatClient.shouldRetry(error: .http(404, "")))
    }

    func test_cancellation_isNotRetryable() {
        XCTAssertFalse(OpenAIChatClient.shouldRetry(error: .cancelled))
    }

    func test_decode_isNotRetryable() {
        XCTAssertFalse(OpenAIChatClient.shouldRetry(error: .decode("malformed JSON")))
    }

    func test_empty_isNotRetryable() {
        XCTAssertFalse(OpenAIChatClient.shouldRetry(error: .empty))
    }

    func test_notConfigured_isNotRetryable() {
        XCTAssertFalse(OpenAIChatClient.shouldRetry(error: .notConfigured("no api key")))
    }

    func test_providerDisabled_isNotRetryable() {
        XCTAssertFalse(OpenAIChatClient.shouldRetry(error: .providerDisabled("turned off")))
    }
}
