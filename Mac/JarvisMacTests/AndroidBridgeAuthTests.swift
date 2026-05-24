import XCTest
@testable import JarvisMac

/// Phase 1A acceptance tests — verifies the central auth gate's pure
/// decision function admits / rejects frames correctly.  The bridge
/// wraps this helper with side effects (telemetry, rate-limit counters);
/// those are exercised by integration tests deferred to a future pass.
final class AndroidBridgeAuthTests: XCTestCase {

    // MARK: - When auth is disabled

    func test_authDisabled_passesThrough_evenWithoutToken() {
        let result = AndroidBridgeAuth.validate(
            envelopeAuth:  nil,
            expectedToken: nil,
            requireAuth:   false)
        XCTAssertEqual(result, .passthrough)
    }

    // MARK: - Required auth: rejection paths

    func test_requireAuth_butNoServerToken_rejects() {
        // Pathological config — admin enabled requireAuth but cleared the
        // token.  We must fail closed.
        let result = AndroidBridgeAuth.validate(
            envelopeAuth:  "anything",
            expectedToken: nil,
            requireAuth:   true)
        XCTAssertEqual(result, .rejected(.serverTokenMissing))

        let resultEmpty = AndroidBridgeAuth.validate(
            envelopeAuth:  "anything",
            expectedToken: "",
            requireAuth:   true)
        XCTAssertEqual(resultEmpty, .rejected(.serverTokenMissing))
    }

    func test_requireAuth_butClientOmitsToken_rejects_phoneEventCase() {
        // The Phase 1 vulnerability — a `phone_event` frame WITHOUT auth.
        let result = AndroidBridgeAuth.validate(
            envelopeAuth:  nil,                 // forged event has no auth
            expectedToken: "correct-secret",
            requireAuth:   true)
        XCTAssertEqual(result, .rejected(.clientTokenMissing))
    }

    func test_requireAuth_butClientOmitsToken_rejects_notificationEventCase() {
        // Equivalent assertion for `notification_event`.  The gate is
        // payload-shape-agnostic — same call, same result.
        let result = AndroidBridgeAuth.validate(
            envelopeAuth:  nil,
            expectedToken: "correct-secret",
            requireAuth:   true)
        XCTAssertEqual(result, .rejected(.clientTokenMissing))
    }

    func test_requireAuth_butClientSendsEmptyToken_rejects() {
        let result = AndroidBridgeAuth.validate(
            envelopeAuth:  "",
            expectedToken: "correct-secret",
            requireAuth:   true)
        XCTAssertEqual(result, .rejected(.clientTokenMissing))
    }

    func test_requireAuth_butClientSendsWrongToken_rejects() {
        let result = AndroidBridgeAuth.validate(
            envelopeAuth:  "guessed-wrong",
            expectedToken: "correct-secret",
            requireAuth:   true)
        XCTAssertEqual(result, .rejected(.clientTokenMismatch))
    }

    // MARK: - Required auth: success path

    func test_validAuthenticatedCommand_accepted() {
        let result = AndroidBridgeAuth.validate(
            envelopeAuth:  "correct-secret",
            expectedToken: "correct-secret",
            requireAuth:   true)
        XCTAssertEqual(result, .ok)
    }

    func test_validAuthenticatedPhoneEvent_accepted() {
        // Same call shape — the gate doesn't distinguish frame type.
        let result = AndroidBridgeAuth.validate(
            envelopeAuth:  "correct-secret",
            expectedToken: "correct-secret",
            requireAuth:   true)
        XCTAssertEqual(result, .ok)
    }

    // MARK: - Tokens are compared byte-for-byte

    func test_tokenCaseSensitive() {
        // Subtle but important — guard against accidental case-insensitive
        // comparisons. UUID-shaped tokens have hex letters; mismatched case
        // must NOT pass.
        let result = AndroidBridgeAuth.validate(
            envelopeAuth:  "ABCDEF",
            expectedToken: "abcdef",
            requireAuth:   true)
        XCTAssertEqual(result, .rejected(.clientTokenMismatch))
    }

    func test_tokenWhitespaceSensitive() {
        // Likewise — trailing whitespace must NOT match.  This prevents an
        // attacker who knows a partial token from probing via newline-padded
        // variants.
        let result = AndroidBridgeAuth.validate(
            envelopeAuth:  "secret\n",
            expectedToken: "secret",
            requireAuth:   true)
        XCTAssertEqual(result, .rejected(.clientTokenMismatch))
    }
}
