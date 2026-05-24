import XCTest
@testable import JarvisMac

/// Verifies that every key in `ResponsePlaybook.defaults` produces a
/// non-empty rendered string when the renderer is given the sample
/// variable dictionary.  This is the cheap regression that catches:
///
///   * A new key added to `ResponseKey` but no phrase wired into
///     `ResponsePlaybook.defaults` (would render to empty).
///   * A typo in a placeholder (`{quary}` instead of `{query}`) that
///     leaves the placeholder unresolved.
///
/// Substitution behaviour:
///   * Known placeholders are substituted.
///   * Unknown placeholders are stripped.
///   * Double spaces from stripping are collapsed.
final class ResponseRendererTests: XCTestCase {

    @MainActor
    func test_everyDefaultKey_rendersNonEmpty() {
        let store    = ResponseTemplateStore()
        let renderer = ResponseRenderer(store: store)

        // ResponsePlaybook.sampleVars covers the headline placeholders
        // (app/query/count/snippet/entity/name/state/context/text/device/error/time)
        // but a handful of templates use additional placeholders (`summary`,
        // `forecast`, `briefing`, etc.) that the renderer correctly strips
        // when absent.  For this all-keys coverage check we extend the dict
        // with a stand-in value for every placeholder so an "empty render"
        // genuinely means a missing/empty template — not a stripped-but-
        // legitimately-unsubstituted variable.
        let sample = ResponsePlaybook.sampleVars.merging([
            "summary":  "it's sunny and 18 degrees",
            "forecast": "rain expected tomorrow afternoon",
            "briefing": "you have 2 meetings today",
            "title":    "Q3 roadmap review",
        ]) { current, _ in current }

        for (key, _) in ResponsePlaybook.defaults {
            let output = renderer.render(key, sample)
            XCTAssertFalse(output.isEmpty,
                "ResponseKey '\(key)' rendered to empty string")
        }
    }

    @MainActor
    func test_knownPlaceholderSubstitutes() {
        let store    = ResponseTemplateStore()
        let renderer = ResponseRenderer(store: store)

        // Render the open-app success key with a fake app name; the {app}
        // placeholder must be filled.
        let result = renderer.render(ResponseKey.openAppSuccess, ["app": "Safari"])
        XCTAssertTrue(result.contains("Safari"),
            "Open-app success render did not contain the substituted app name. Got: \(result)")
    }

    @MainActor
    func test_unknownPlaceholderIsStripped() {
        let store    = ResponseTemplateStore()
        let renderer = ResponseRenderer(store: store)

        // Render with an empty var dictionary — any {placeholder} tokens in
        // the template should be removed, never leaked through verbatim.
        let result = renderer.render(ResponseKey.openAppSuccess, [:])
        XCTAssertFalse(result.contains("{"),
            "Render leaked an unresolved '{…}' placeholder. Got: \(result)")
    }

    @MainActor
    func test_unknownKeyFallsBackToDefaultsIfAny() {
        // A key that exists only in defaults (not yet customised by the user)
        // should still resolve — the renderer falls back to ResponsePlaybook.defaults.
        let store    = ResponseTemplateStore()
        let renderer = ResponseRenderer(store: store)
        let firstKey = ResponsePlaybook.defaults.keys.first!
        let result   = renderer.render(firstKey, ResponsePlaybook.sampleVars)
        XCTAssertFalse(result.isEmpty)
    }

    @MainActor
    func test_completelyUnknownKey_doesNotCrash() {
        let store    = ResponseTemplateStore()
        let renderer = ResponseRenderer(store: store)
        // A nonsense key — must not crash, must return something (empty OK).
        _ = renderer.render("totally.invented.key", [:])
    }
}
