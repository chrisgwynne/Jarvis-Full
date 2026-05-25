import XCTest
@testable import JarvisMac

// MARK: - TTS Backend System Tests
// Covers: PiperTTSBackend, SystemTTSBackend, SupertonicTTSBackend,
//         TTSBackendRouter (fallback chain, benchmarking, tag stripping).

@MainActor
final class TTSBackendTests: XCTestCase {

    // MARK: - SystemTTSBackend

    func testSystemAlwaysAvailable() {
        let apple  = AVSpeechTTS()
        let system = SystemTTSBackend(apple: apple)
        XCTAssertTrue(system.isAvailable, "System backend is always available on macOS")
    }

    func testSystemIdAndDisplayName() {
        let system = SystemTTSBackend(apple: AVSpeechTTS())
        XCTAssertEqual(system.id, "system_apple")
        XCTAssertFalse(system.displayName.isEmpty)
    }

    func testSystemDoesNotSupportExpressionTags() {
        let system = SystemTTSBackend(apple: AVSpeechTTS())
        XCTAssertFalse(system.supportsExpressionTags)
    }

    // MARK: - PiperTTSBackend

    func testPiperUnavailableWhenPathsEmpty() {
        let piper   = PiperTTS()
        let backend = PiperTTSBackend(piper: piper)
        // Fresh PiperTTS with no paths configured → isAvailable = false
        XCTAssertFalse(backend.isAvailable,
                       "Piper should be unavailable when executable and model paths are empty")
    }

    func testPiperIdAndDisplayName() {
        let backend = PiperTTSBackend(piper: PiperTTS())
        XCTAssertEqual(backend.id, "piper_onnx")
        XCTAssertFalse(backend.displayName.isEmpty)
    }

    func testPiperDoesNotSupportExpressionTags() {
        let backend = PiperTTSBackend(piper: PiperTTS())
        XCTAssertFalse(backend.supportsExpressionTags)
    }

    // MARK: - SupertonicTTSBackend

    func testSupertonicUnavailableWhenNotEnabled() {
        // In non-SUPERTONIC_ENABLED builds, isAvailable must always be false.
        let supertonic = SupertonicTTSBackend()
        // This passes in both build configurations:
        // - In non-enabled builds, isAvailable is hardcoded false.
        // - In enabled builds, the model directory is absent in CI.
        XCTAssertFalse(supertonic.isAvailable || {
            // Allow true ONLY if build flag is set AND model files actually exist.
#if SUPERTONIC_ENABLED
            return FileManager.default.fileExists(atPath:
                SupertonicTTSBackend.modelDirectory.path)
#else
            return false
#endif
        }(), "Supertonic should not be available in CI / unconfigured builds")
    }

    func testSupertonicUnavailableDoesNotCrashOnSpeak() {
        // speak() on an unavailable backend must be a safe no-op.
        let supertonic = SupertonicTTSBackend()
        XCTAssertFalse(supertonic.isAvailable)
        supertonic.speak("Hello, world.")
        supertonic.stop()
    }

    func testSupertonicDiagnosticsHasUnavailableReason() {
        let supertonic = SupertonicTTSBackend()
        if !supertonic.isAvailable {
            XCTAssertNotNil(supertonic.diagnostics.unavailableReason,
                            "Unavailable backend must supply an unavailableReason")
        }
    }

    // MARK: - TTSTagStripper

    func testTagsStrippedForNonExpressiveBackend() {
        let system = SystemTTSBackend(apple: AVSpeechTTS())
        XCTAssertFalse(system.supportsExpressionTags)
        let out = TTSTagStripper.prepare("<happy>Hello</happy>, <break/> world.", for: system)
        XCTAssertEqual(out, "Hello, world.",
                       "Tags should be stripped for non-expressive backends")
    }

    func testTagStrippingCollapsesWhitespace() {
        let stripped = TTSTagStripper.strip("One <tag/> two  <other>   </other> three")
        XCTAssertFalse(stripped.contains("  "), "Multiple spaces should be collapsed")
    }

    // MARK: - TTSBackendRouter — fallback chain

    func testRouterUsesSystemFallbackWhenPiperUnavailable() {
        let router = makeRouter(preferredId: "piper_onnx")
        // Piper has no paths → unavailable; system is always available.
        XCTAssertEqual(router.resolvedBackend.id, "system_apple",
                       "Router must fall back to system when piper is unavailable")
    }

    func testRouterUsesSystemWhenPreferredIdIsSystem() {
        let router = makeRouter(preferredId: "system_apple")
        XCTAssertEqual(router.resolvedBackend.id, "system_apple")
    }

    func testRouterFallsBackToSystemForUnknownBackendId() {
        let router = makeRouter(preferredId: "nonexistent_backend")
        // Unknown → not found → piper (unavailable) → system.
        XCTAssertEqual(router.resolvedBackend.id, "system_apple",
                       "Unknown backend ID should ultimately reach system fallback")
    }

    func testRouterSetActiveBackendChangesPreference() {
        let router = makeRouter(preferredId: "piper_onnx")
        router.setActiveBackend(id: "system_apple")
        XCTAssertEqual(router.preferredBackendId, "system_apple")
    }

    func testRouterAllBackendsContainsThree() {
        let router = makeRouter(preferredId: "system_apple")
        XCTAssertEqual(router.allBackends.count, 3)
    }

    // MARK: - TTSBackendRouter — speak() does not crash

    func testRouterSpeakDoesNotCrash() {
        let router = makeRouter(preferredId: "system_apple")
        router.start()
        router.speak("Hello, Jarvis.")
        router.stop()
    }

    // MARK: - TTSBenchmarkStore

    func testBenchmarkStoreAddsRecord() {
        let store = TTSBenchmarkStore()
        let r = TTSBenchmarkRecord(
            id: UUID(), backendId: "test", backendName: "Test", textLength: 10,
            preloadMs: 0, firstAudioMs: 100, totalPlaybackMs: 500,
            synthesisDoneMs: 400, error: nil, timestamp: Date(),
            memoryMB: nil, cpuPercent: nil)
        store.add(r)
        XCTAssertEqual(store.all().count, 1)
    }

    func testBenchmarkStoreSucceededFlag() {
        let ok = makeRecord(error: nil)
        let fail = makeRecord(error: "timeout")
        XCTAssertTrue(ok.succeeded)
        XCTAssertFalse(fail.succeeded)
    }

    func testBenchmarkStoreClearWorks() {
        let store = TTSBenchmarkStore()
        store.add(makeRecord(error: nil))
        store.clear()
        XCTAssertEqual(store.all().count, 0)
    }

    func testBenchmarkStoreCapAt200() {
        let store = TTSBenchmarkStore()
        for _ in 0..<220 { store.add(makeRecord(error: nil)) }
        XCTAssertLessThanOrEqual(store.all().count, 200)
    }

    // MARK: - Helpers

    private func makeRouter(preferredId: String) -> TTSBackendRouter {
        TTSBackendRouter(
            piper:      PiperTTSBackend(piper: PiperTTS()),
            system:     SystemTTSBackend(apple: AVSpeechTTS()),
            supertonic: SupertonicTTSBackend(),
            preferredBackendId: preferredId
        )
    }

    private func makeRecord(error: String?) -> TTSBenchmarkRecord {
        TTSBenchmarkRecord(
            id: UUID(), backendId: "x", backendName: "X", textLength: 5,
            preloadMs: 0, firstAudioMs: 80, totalPlaybackMs: 300,
            synthesisDoneMs: 200, error: error, timestamp: Date(),
            memoryMB: nil, cpuPercent: nil)
    }
}
