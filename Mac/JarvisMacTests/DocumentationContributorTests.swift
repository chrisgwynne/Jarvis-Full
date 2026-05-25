import XCTest
@testable import JarvisMac

/// Smoke tests for the built-in `DocumentationContributor`s.  These
/// guarantee that the actual contributors used in production:
///   * compile and run against a real `PreferencesStore` / diagnostics
///   * emit a non-empty section when their feature is enabled
///   * hide themselves (or report disabled/notConfigured) when the
///     underlying feature is turned off
///
/// We use a sandbox `PreferencesStore` and toggle individual flags to
/// drive each branch.
@MainActor
final class DocumentationContributorTests: XCTestCase {

    // MARK: - Stable / always-on contributors

    func test_gettingStarted_alwaysEmitsSection() {
        let s = GettingStartedContributor().section()
        XCTAssertNotNil(s)
        XCTAssertFalse(s?.examples.isEmpty ?? true,
            "Getting Started must list at least one example.")
    }

    func test_conversations_alwaysEmitsSection() {
        XCTAssertNotNil(ConversationsContributor().section())
    }

    func test_conversationalHelp_alwaysEmitsSection() {
        let s = ConversationalHelpContributor().section()
        XCTAssertNotNil(s)
        // Help section must include the "how do I" example so the IntentRouter
        // documentation-lookup prefix is discoverable in the overlay.
        XCTAssertTrue(
            s?.examples.contains(where: { $0.phrase.lowercased().contains("how do i") }) ?? false)
    }

    // MARK: - State-driven contributors

    func test_androidContributor_offlineWhenNotConnected() {
        let diag = AndroidBridgeDiagnostics()        // default: isConnected = false
        let s = AndroidContributor(diagnostics: { diag }).section()
        XCTAssertNotNil(s)
        XCTAssertEqual(s?.status, .notConfigured)
        XCTAssertTrue(s?.troubleshooting
            .first(where: { $0.symptom.contains("offline") })?.isActive == true,
            "When Android is offline, the 'integration is offline' troubleshooting item must be active.")
    }

    func test_androidContributor_enabledWhenConnected() {
        var diag = AndroidBridgeDiagnostics()
        diag.isConnected = true
        diag.deviceName  = "Galaxy Fold 6"
        diag.batteryLevel = 82
        diag.isCharging   = true
        let s = AndroidContributor(diagnostics: { diag }).section()
        XCTAssertNotNil(s)
        XCTAssertEqual(s?.status, .enabled)
        XCTAssertTrue(s?.subtitle?.contains("Galaxy Fold 6") ?? false)
        XCTAssertTrue(s?.subtitle?.contains("82") ?? false)
    }

    func test_callsAndMessaging_statusReflectsAndroidConnection() {
        var diag = AndroidBridgeDiagnostics()
        diag.isConnected = false
        let offline = CallsAndMessagingContributor(diagnostics: { diag }).section()
        XCTAssertEqual(offline?.status, .notConfigured)
        diag.isConnected = true
        let online = CallsAndMessagingContributor(diagnostics: { diag }).section()
        XCTAssertEqual(online?.status, .enabled)
    }

    func test_aiProviders_notConfiguredWhenAllOff() {
        let prefs = makeSandboxPrefs()
        prefs.update {
            $0.miniMaxEnabled = false
            $0.geminiEnabled  = false
            $0.llamaCppEnabled = false
        }
        let s = AIProvidersContributor(prefs: prefs).section()
        XCTAssertEqual(s?.status, .notConfigured)
        XCTAssertTrue(s?.requiredIntegrations.contains(where: { $0.contains("Enable") }) ?? false)
    }

    func test_aiProviders_enabledWhenAnyOn() {
        let prefs = makeSandboxPrefs()
        prefs.update {
            $0.geminiEnabled = true
        }
        let s = AIProvidersContributor(prefs: prefs).section()
        XCTAssertEqual(s?.status, .enabled)
        XCTAssertTrue(s?.subtitle?.contains("Gemini") ?? false)
    }

    func test_aiProviders_surfacesMissingKeyTroubleshooting() {
        let prefs = makeSandboxPrefs()
        prefs.update { $0.geminiEnabled = true }
        Keychain.remove(KeychainAccount.geminiAPIKey)
        let s = AIProvidersContributor(prefs: prefs).section()
        XCTAssertTrue(
            s?.troubleshooting.contains(where: {
                $0.symptom.lowercased().contains("missing api key") && $0.isActive
            }) ?? false,
            "When Gemini is enabled but no key is set in Keychain, an active troubleshooting item must surface that.")
    }

    func test_cameraVision_reflectsCloudConsent() {
        let prefs = makeSandboxPrefs()
        prefs.update { $0.cloudVisionConsent = false }
        let off = CameraVisionContributor(prefs: prefs).section()
        XCTAssertEqual(off?.status, .degraded)
        XCTAssertTrue(off?.subtitle?.contains("OFF") ?? false)

        prefs.update { $0.cloudVisionConsent = true }
        let on = CameraVisionContributor(prefs: prefs).section()
        XCTAssertEqual(on?.status, .enabled)
    }

    func test_memoryObsidian_notConfiguredWhenVaultEmpty() {
        let prefs = makeSandboxPrefs()
        prefs.update {
            $0.obsidianVaultPath = nil
            $0.obsidianLLMContextEnabled = true
        }
        let s = MemoryObsidianContributor(prefs: prefs).section()
        XCTAssertEqual(s?.status, .notConfigured)
    }

    func test_memoryObsidian_enabledWhenConfigured() {
        let prefs = makeSandboxPrefs()
        prefs.update {
            $0.obsidianVaultPath = "/tmp/some-vault"
            $0.obsidianLLMContextEnabled = true
        }
        let s = MemoryObsidianContributor(prefs: prefs).section()
        XCTAssertEqual(s?.status, .enabled)
    }

    func test_privacy_subtitleReflectsCloudVisionAndAuth() {
        let prefs = makeSandboxPrefs()
        prefs.update {
            $0.cloudVisionConsent     = false
            $0.requireWebSocketAuth   = true
        }
        let s = PrivacyContributor(prefs: prefs).section()
        XCTAssertTrue(s?.subtitle?.contains("OFF") ?? false)
        XCTAssertTrue(s?.subtitle?.contains("required") ?? false)
    }

    // MARK: - Engine integration via the help-overlay sidebar

    func test_engineHidesContributors_whenFeatureOff() {
        let prefs = makeSandboxPrefs()
        prefs.update {
            $0.obsidianVaultPath = nil
            $0.obsidianLLMContextEnabled = false
        }
        let engine = LivingDocumentationEngine()
        engine.register(MemoryObsidianContributor(prefs: prefs))
        // Even when Obsidian is "off", the contributor still emits a
        // section flagged as `.notConfigured` — the goal is to TELL the
        // user how to enable it, not pretend the topic doesn't exist.
        XCTAssertEqual(engine.allSections().count, 1)
        XCTAssertEqual(engine.allSections().first?.status, .notConfigured)
    }

    // MARK: - Helpers

    /// Build a `PreferencesStore` pointing at the user's app-support
    /// dir (the store has no inject-point for an alternate URL).  Each
    /// test resets only the fields it cares about.  This mirrors the
    /// pattern used in GitHubIssueServiceTests.
    private func makeSandboxPrefs() -> PreferencesStore {
        let p = PreferencesStore()
        p.update {
            $0.miniMaxEnabled = false
            $0.geminiEnabled = false
            $0.llamaCppEnabled = false
            $0.cloudVisionConsent = false
            $0.obsidianVaultPath = nil
            $0.obsidianLLMContextEnabled = false
            $0.requireWebSocketAuth = true
        }
        return p
    }
}
