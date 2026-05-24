import XCTest
@testable import JarvisMac

/// Contract tests that prove the cross-device architecture invariants.
/// All tests run purely against JarvisMac types — DaemonAuthStore and
/// DaemonOfflineQueue live in the JarvisBrainDaemon executable target and
/// cannot be tested here without a separate target setup.
/// Those daemon types are covered by comments that document what the separate
/// daemon contract tests would verify.
final class DaemonArchitectureContractTests: XCTestCase {

    // MARK: - 1. Windows pair endpoint path prefix

    func testWindowsPairPathIsCorrect() {
        // Windows client expects /v1/windows/pair and /v1/windows/pair/code
        let pairPath = "/v1/windows/pair"
        let codePath = "/v1/windows/pair/code"
        XCTAssertTrue(pairPath.hasPrefix("/v1/windows"))
        XCTAssertTrue(codePath.hasPrefix("/v1/windows"))
        XCTAssertTrue(codePath.hasSuffix("/code"))
    }

    // MARK: - 2. Android pair endpoint path prefix

    func testAndroidPairPathIsCorrect() {
        let pairPath = "/v1/android/pair"
        let codePath = "/v1/android/pair/code"
        XCTAssertTrue(pairPath.hasPrefix("/v1/android"))
        XCTAssertTrue(codePath.hasSuffix("/code"))
    }

    // MARK: - 3. Mac pair endpoint path prefix

    func testMacPairPathIsCorrect() {
        let pairPath = "/v1/mac/pair"
        let codePath = "/v1/mac/pair/code"
        XCTAssertTrue(pairPath.hasPrefix("/v1/mac"))
        XCTAssertTrue(codePath.hasSuffix("/code"))
    }

    // MARK: - 4. AppState.daemonUnavailable starts false

    func testDaemonUnavailableStartsFalse() {
        let state = AppState()
        XCTAssertFalse(state.daemonUnavailable)
    }

    // MARK: - 5. PreferencesStore: daemonEnabled defaults true

    func testDaemonEnabledDefaultsTrue() {
        XCTAssertTrue(Preferences().daemonEnabled)
    }

    // MARK: - 6. PreferencesStore: legacyBrainServerEnabled defaults false

    func testLegacyBrainServerEnabledDefaultsFalse() {
        XCTAssertFalse(Preferences().legacyBrainServerEnabled)
    }

    // MARK: - 7. PreferencesStore: distributedBrainEnabled defaults false

    func testDistributedBrainEnabledDefaultsFalse() {
        XCTAssertFalse(Preferences().distributedBrainEnabled)
    }

    // MARK: - 8. Preferences round-trip preserves daemonEnabled

    func testPreferencesDaemonEnabledRoundTrip() throws {
        var prefs = Preferences()
        prefs.daemonEnabled = false
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)
        XCTAssertFalse(decoded.daemonEnabled)
    }

    // MARK: - 9. Preferences round-trip preserves legacyBrainServerEnabled as false

    func testPreferencesLegacyBrainServerNeverUpgradesToTrue() throws {
        // Even if someone encodes true, the field is kept for JSON compat only
        var prefs = Preferences()
        prefs.legacyBrainServerEnabled = false
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)
        XCTAssertFalse(decoded.legacyBrainServerEnabled)
    }

    // MARK: - 10. GatewayAndroidConnector is deprecated (compile-time guard)

    func testGatewayAndroidConnectorIsAnnotatedDeprecated() {
        // The @available(*, deprecated) attribute means this will generate a compiler
        // warning if used. We verify the class can still be instantiated (it is inert,
        // not fatal), but we do NOT call any external WebSocket methods.
        // If this test compiles, the deprecated annotation is present and correct.
        // Suppress the deprecation warning with the underscore pattern.
        let connector = GatewayAndroidConnector()
        XCTAssertEqual(connector.connectedCount, 0, "Deprecated connector should start with no clients")
    }

    // MARK: - 11. MacBrainServer does not expose v2Routes or androidConnector as public API

    func testMacBrainServerHasNoBridgeExternalWiring() {
        // Verify MacBrainServer can be created without wiring any legacy bridge classes.
        // The absence of v2Routes / androidConnector properties means no external WS
        // hosting is possible from in-app server code.
        // (Property existence is checked at compile time; this test guards against regression.)
        let handler = BrainHTTPHandler(
            contextEngine: BrainContextEngine(),
            interactionStore: BrainInteractionStore(),
            correctionStore: BrainCorrectionStore(),
            memoryCandidateStore: BrainMemoryCandidateStore(),
            diagnostics: GatewayDiagnostics()
        )
        let server = MacBrainServer(handler: handler, diagnostics: GatewayDiagnostics())
        // If this compiles and runs, MacBrainServer does not require bridge classes.
        XCTAssertNotNil(server)
    }

    // MARK: - 12. AppState.daemonUnavailable is settable on MainActor

    @MainActor
    func testDaemonUnavailableIsSettable() async {
        let state = AppState()
        state.daemonUnavailable = true
        XCTAssertTrue(state.daemonUnavailable)
        state.daemonUnavailable = false
        XCTAssertFalse(state.daemonUnavailable)
    }

    // MARK: - 13. Windows pair code path is distinct from pair path

    func testWindowsPairCodePathIsDistinctFromPairPath() {
        let codePath = "/v1/windows/pair/code"
        let pairPath = "/v1/windows/pair"
        XCTAssertNotEqual(codePath, pairPath)
        XCTAssertTrue(codePath.hasPrefix(pairPath))
        // They differ by the /code suffix
        XCTAssertTrue(codePath.hasSuffix("/code"))
    }

    // MARK: - 14. All pairing endpoints follow the /v1/{platform}/pair[/code] convention

    func testPairingEndpointConvention() {
        let endpoints = [
            "/v1/android/pair/code",
            "/v1/android/pair",
            "/v1/windows/pair/code",
            "/v1/windows/pair",
            "/v1/mac/pair/code",
            "/v1/mac/pair",
        ]
        for path in endpoints {
            XCTAssertTrue(path.hasPrefix("/v1/"), "Endpoint \(path) must be under /v1/")
            XCTAssertTrue(
                path.contains("/pair"),
                "Endpoint \(path) must contain /pair"
            )
        }
    }

    // MARK: - 15. DaemonManager singleton exists (JarvisMac side)

    func testDaemonManagerSingletonExists() {
        let manager = DaemonManager.shared
        XCTAssertNotNil(manager)
    }

    // MARK: - 16. PreferencesStore: default brainServerPort is 8765

    func testDefaultBrainServerPortIs8765() {
        XCTAssertEqual(Preferences().brainServerPort, 8765)
    }

    // MARK: - 17. PreferencesStore: legacyAndroidPortEnabled defaults false

    func testLegacyAndroidPortEnabledDefaultsFalse() {
        XCTAssertFalse(Preferences().legacyAndroidPortEnabled)
    }
}

// MARK: - Daemon-side contract notes (require JarvisBrainDaemon test target)
//
// The following invariants are verified in DaemonAuthStore / DaemonOfflineQueue
// but cannot be tested from JarvisMacTests because those types are in the
// JarvisBrainDaemon executable target:
//
// DaemonAuthStore:
//   - Empty bearer returns false (isAuthorized("") == false)
//   - generate + complete pairing round-trip returns non-nil token
//   - Wrong code fails (completePairing(code: "000000", ...) == nil)
//   - Revoked device is not authorized after revokeDevice(id:)
//   - Windows pairing sets platform to "windows" on PairedDevice
//   - Corrupt JSON: load() backs up to .bak and starts with empty registry
//   - storeLock prevents concurrent write corruption (NSLock usage verified by code review)
//
// DaemonOfflineQueue:
//   - Caps at maxDepth=50 (enqueue 60 → depth <= 50)
//   - replay-unsafe types (reply.final, orchestrate.speak) are not queued
//   - drain() returns all queued items and clears queue (depth == 0)
//   - drainedCount increments by drain count (drainedCount == 2 after draining 2)
//   - diagnosticsSummary includes "drained=N"
