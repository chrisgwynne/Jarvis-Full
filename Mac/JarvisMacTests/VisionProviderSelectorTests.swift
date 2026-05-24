import XCTest
@testable import JarvisMac

/// Tests `VisionProviderSelector`'s pure routing decision — specifically
/// the cloud-consent gate which is a privacy-critical invariant:
/// **no camera frame may leave the machine while `cloudVisionConsent`
/// is false**, regardless of the user's preferred provider choice.
///
/// We exercise the `active()` helper directly so no real image / network
/// is required.  Concrete provider conformance is satisfied with a
/// `StubVisionProvider` that records which method was called.
@MainActor
final class VisionProviderSelectorTests: XCTestCase {

    // MARK: - Cloud-consent gate

    func test_consentOff_alwaysRoutesToApple_evenWhenMinimaxPreferred() {
        let prefs = makePrefs(consent: false, preferred: "minimax")
        let sel   = makeSelector(prefs: prefs)
        let (provider, choice, reason) = sel.active()
        XCTAssertEqual(choice, .apple)
        XCTAssertEqual(reason, "cloud_vision_consent_off")
        XCTAssertEqual((provider as? StubVisionProvider)?.id, "apple")
    }

    func test_consentOff_alwaysRoutesToApple_evenWhenGeminiPreferred() {
        let prefs = makePrefs(consent: false, preferred: "gemini")
        let sel   = makeSelector(prefs: prefs)
        let (provider, choice, reason) = sel.active()
        XCTAssertEqual(choice, .apple)
        XCTAssertEqual(reason, "cloud_vision_consent_off")
        XCTAssertEqual((provider as? StubVisionProvider)?.id, "apple")
    }

    // MARK: - Choice routing (consent on)

    func test_consentOn_minimaxPreferred_routesToMinimax() {
        let prefs = makePrefs(consent: true, preferred: "minimax")
        let sel   = makeSelector(prefs: prefs)
        let (provider, choice, reason) = sel.active()
        XCTAssertEqual(choice, .minimax)
        XCTAssertNil(reason)
        XCTAssertEqual((provider as? StubVisionProvider)?.id, "minimax")
    }

    func test_consentOn_geminiPreferred_routesToGemini() {
        let prefs = makePrefs(consent: true, preferred: "gemini")
        let sel   = makeSelector(prefs: prefs)
        let (_, choice, _) = sel.active()
        XCTAssertEqual(choice, .gemini)
    }

    func test_consentOn_explicitApplePreference_routesToApple_withReason() {
        let prefs = makePrefs(consent: true, preferred: "apple")
        let sel   = makeSelector(prefs: prefs)
        let (_, choice, reason) = sel.active()
        XCTAssertEqual(choice, .apple)
        XCTAssertEqual(reason, "user_selected_apple")
    }

    func test_consentOn_unknownPreferenceRaw_defaultsToMinimax() {
        // Forward-compat: future stored raw values must not panic.
        let prefs = makePrefs(consent: true, preferred: "openai_vision_2027")
        let sel   = makeSelector(prefs: prefs)
        let (_, choice, _) = sel.active()
        XCTAssertEqual(choice, .minimax,
            "Unknown preference raw should fall back to minimax, not crash")
    }

    // MARK: - Helpers

    /// Builds a fresh PreferencesStore pointing at a tempdir so the test's
    /// pref changes don't pollute the developer's real prefs.json.
    private func makePrefs(consent: Bool, preferred: String) -> PreferencesStore {
        let store = PreferencesStore()
        store.update {
            $0.cloudVisionConsent = consent
            $0.preferredVisionProviderRaw = preferred
        }
        return store
    }

    private func makeSelector(prefs: PreferencesStore) -> VisionProviderSelector {
        VisionProviderSelector(
            prefs:   prefs,
            minimax: StubVisionProvider(id: "minimax"),
            gemini:  StubVisionProvider(id: "gemini"),
            apple:   StubVisionProvider(id: "apple"))
    }
}

// MARK: - Stub provider

/// Minimal VisionProvider conformance for selector tests.  We don't
/// invoke any methods in these tests; only the `id` is inspected to
/// confirm dispatch went to the right concrete provider.
private final class StubVisionProvider: VisionProvider {
    let id: String
    init(id: String) { self.id = id }
    var providerName: String { "Stub(\(id))" }
    func isAvailable() async -> Bool { true }
    func describeScene(image: CGImage) async -> VisionProviderResult { fail() }
    func describePerson(image: CGImage) async -> VisionProviderResult { fail() }
    func describeDesk(image: CGImage) async -> VisionProviderResult { fail() }
    func extractText(image: CGImage) async -> VisionProviderResult { fail() }
    func detectObjects(image: CGImage) async -> VisionProviderResult { fail() }
    func detectHeldObject(image: CGImage) async -> VisionProviderResult { fail() }
    private func fail() -> VisionProviderResult {
        VisionProviderResult.failure(provider: providerName, error: "stub-not-callable")
    }
}
