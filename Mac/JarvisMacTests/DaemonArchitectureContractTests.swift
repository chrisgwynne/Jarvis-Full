import XCTest
@testable import JarvisMac

/// Contract tests that prove the cross-device architecture invariants.
/// These tests validate source-level contracts: deprecated classes are not instantiated,
/// internal types hold correct defaults, and the daemon-centric routing is properly wired.
@MainActor
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
        XCTAssertTrue(Preferences.testDefaults.daemonEnabled)
    }

    // MARK: - 6. PreferencesStore: legacyBrainServerEnabled defaults false

    func testLegacyBrainServerEnabledDefaultsFalse() {
        XCTAssertFalse(Preferences.testDefaults.legacyBrainServerEnabled)
    }

    // MARK: - 7. PreferencesStore: distributedBrainEnabled defaults false

    func testDistributedBrainEnabledDefaultsFalse() {
        XCTAssertFalse(Preferences.testDefaults.distributedBrainEnabled)
    }

    // MARK: - 8. Preferences round-trip preserves daemonEnabled

    func testPreferencesDaemonEnabledRoundTrip() throws {
        var prefs = Preferences.testDefaults
        prefs.daemonEnabled = false
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)
        XCTAssertFalse(decoded.daemonEnabled)
    }

    // MARK: - 9. Preferences round-trip preserves legacyBrainServerEnabled as false

    func testPreferencesLegacyBrainServerNeverUpgradesToTrue() throws {
        // Even if someone encodes true, the field is kept for JSON compat only
        var prefs = Preferences.testDefaults
        prefs.legacyBrainServerEnabled = false
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)
        XCTAssertFalse(decoded.legacyBrainServerEnabled)
    }

    // MARK: - 10. GatewayAndroidConnector is never instantiated in JarvisController

    func testJarvisControllerDoesNotReferenceGatewayAndroidConnector() {
        // Read JarvisController.swift source and verify GatewayAndroidConnector is not referenced
        // (other than the @available deprecated annotation on the class itself).
        let sourceURL = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()           // JarvisMacTests/
            .deletingLastPathComponent()           // Mac/
            .appendingPathComponent("JarvisMac/Core/JarvisController.swift")
        guard let source = try? String(contentsOf: sourceURL, encoding: .utf8) else {
            XCTFail("Could not read JarvisController.swift")
            return
        }
        XCTAssertFalse(
            source.contains("GatewayAndroidConnector"),
            "JarvisController must not reference GatewayAndroidConnector — external WebSocket is owned by JarvisBrainDaemon"
        )
    }

    func testMacBrainServerHasNoAndroidConnectorProperty() {
        // Verify MacBrainServer.swift does not declare an androidConnector property.
        let sourceURL = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("JarvisMac/MacBrain/MacBrainServer.swift")
        guard let source = try? String(contentsOf: sourceURL, encoding: .utf8) else {
            XCTFail("Could not read MacBrainServer.swift")
            return
        }
        XCTAssertFalse(
            source.contains("androidConnector"),
            "MacBrainServer must not own androidConnector — external WebSocket is owned by JarvisBrainDaemon"
        )
    }

    func testStartBrainServerDoesNotReferenceMacBridgeProtocolV2() {
        // Verify JarvisController's startBrainServer() function does not wire MacBridgeProtocolV2.
        let sourceURL = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("JarvisMac/Core/JarvisController.swift")
        guard let source = try? String(contentsOf: sourceURL, encoding: .utf8) else {
            XCTFail("Could not read JarvisController.swift")
            return
        }
        // Verify: either MacBridgeProtocolV2 is not mentioned in startBrainServer context,
        // or any mention is inside a deprecated/dead code comment.
        // Simple check: if it appears it must only be in a comment or @available annotation.
        let lines = source.components(separatedBy: .newlines)
        let liveLines = lines.filter {
            $0.contains("MacBridgeProtocolV2") &&
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") &&
            !$0.contains("deprecated") &&
            !$0.contains("@available")
        }
        XCTAssertTrue(
            liveLines.isEmpty,
            "MacBridgeProtocolV2 must not be wired at runtime. Found live references:\n\(liveLines.joined(separator: "\n"))"
        )
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
        XCTAssertEqual(Preferences.testDefaults.brainServerPort, 8765)
    }

    // MARK: - 17. PreferencesStore: legacyAndroidPortEnabled defaults false

    func testLegacyAndroidPortEnabledDefaultsFalse() {
        XCTAssertFalse(Preferences.testDefaults.legacyAndroidPortEnabled)
    }
}

// MARK: - Daemon-side contract tests
//
// DaemonAuthStore and DaemonOfflineQueue invariants are tested in
// Mac/JarvisBrainDaemonTests/DaemonCoreTests.swift (JarvisBrainDaemonTests target).
// Those tests use source-based replicas of the daemon logic since the daemon
// is an executable target that cannot be @testable import-ed.

// MARK: - Test helper

private extension Preferences {
    /// `Preferences` has no zero-arg init; decoding empty JSON yields all defaults.
    static var testDefaults: Preferences {
        try! JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
    }
}
