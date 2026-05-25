import XCTest
@testable import JarvisMac

// MARK: - TTS Backend System Tests
// Covers: PiperTTSBackend, SystemTTSBackend, SupertonicTTSBackend,
//         TTSBackendRouter (fallback chain, benchmarking, tag stripping).

@MainActor
final class TTSBackendTests: XCTestCase {

    // MARK: - SystemTTSBackend

    func testSystemAlwaysAvailable() {
        let system = SystemTTSBackend(apple: AVSpeechTTS())
        XCTAssertTrue(system.isAvailable)
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
        let backend = PiperTTSBackend(piper: PiperTTS())
        XCTAssertFalse(backend.isAvailable,
                       "Piper should be unavailable when paths are empty")
    }

    func testPiperIdAndDisplayName() {
        let backend = PiperTTSBackend(piper: PiperTTS())
        XCTAssertEqual(backend.id, "piper_onnx")
        XCTAssertFalse(backend.displayName.isEmpty)
    }

    func testPiperDoesNotSupportExpressionTags() {
        XCTAssertFalse(PiperTTSBackend(piper: PiperTTS()).supportsExpressionTags)
    }

    // MARK: - SupertonicTTSBackend — identity

    func testSupertonicId() {
        XCTAssertEqual(SupertonicTTSBackend().id, "supertonic")
    }

    func testSupertonicDisplayNameNotEmpty() {
        XCTAssertFalse(SupertonicTTSBackend().displayName.isEmpty)
    }

    /// Supertonic 3 natively handles <laugh>, <breath>, <sigh> — tags must NOT be stripped.
    func testSupertonicSupportsExpressionTags() {
        XCTAssertTrue(SupertonicTTSBackend().supportsExpressionTags,
                      "Supertonic 3 supports expression tags — supportsExpressionTags must be true")
    }

    // MARK: - SupertonicTTSBackend — availability is runtime-detected (no hardwired false)

    /// isAvailable must reflect real conditions, not a compile-time constant.
    /// In CI the model directory is absent → unavailable.
    /// With models present → available. Never hardwired false.
    func testSupertonicAvailabilityReflectsModelDirectory() {
        let supertonic = SupertonicTTSBackend()
        let modelDir   = supertonic.modelDirectory
        let expected   = modelDir.allRequiredFilesPresent
        XCTAssertEqual(supertonic.isAvailable, expected,
                       "isAvailable must match allRequiredFilesPresent — no hardwired false")
    }

    func testSupertonicUnavailableWhenModelDirectoryEmpty() {
        // Point at a non-existent directory → unavailable.
        let missing = SupertonicModelDirectory(base: URL(fileURLWithPath: "/tmp/nonexistent_supertonic_\(UUID().uuidString)"))
        let backend = SupertonicTTSBackend(modelDirectory: missing)
        XCTAssertFalse(backend.isAvailable,
                       "Backend must be unavailable when model directory does not exist")
    }

    func testSupertonicMissingFilesListedInDiagnostics() {
        let missing = SupertonicModelDirectory(base: URL(fileURLWithPath: "/tmp/nonexistent_\(UUID().uuidString)"))
        let backend = SupertonicTTSBackend(modelDirectory: missing)
        XCTAssertFalse(backend.isAvailable)
        XCTAssertNotNil(backend.diagnostics.unavailableReason,
                        "Unavailable backend must supply an unavailableReason")
    }

    func testSupertonicMissingFilesReturnsMeaningfulList() {
        let dir     = SupertonicModelDirectory(base: URL(fileURLWithPath: "/tmp/nonexistent_\(UUID().uuidString)"))
        let missing = dir.missingFiles()
        XCTAssertFalse(missing.isEmpty,
                       "missingFiles() must list required files when directory doesn't exist")
        XCTAssertTrue(missing.contains(where: { $0.contains("duration_predictor") }),
                      "Missing files must include duration_predictor.onnx")
        XCTAssertTrue(missing.contains(where: { $0.contains("vocoder") }),
                      "Missing files must include vocoder.onnx")
    }

    /// speak() on an unavailable backend must be a safe no-op — must not crash.
    func testSupertonicUnavailableSpeakIsNoOp() {
        let dir     = SupertonicModelDirectory(base: URL(fileURLWithPath: "/tmp/nonexistent_\(UUID().uuidString)"))
        let backend = SupertonicTTSBackend(modelDirectory: dir)
        XCTAssertFalse(backend.isAvailable)
        backend.speak("Hello")   // must not crash
        backend.stop()
        XCTAssertFalse(backend.isSpeaking)
    }

    // MARK: - SupertonicModelDirectory

    func testModelDirectoryDefaultURL() {
        let dir = SupertonicModelDirectory.defaultURL
        XCTAssertTrue(dir.path.contains("JarvisMac/TTS/Supertonic"),
                      "Default URL must contain expected path components")
    }

    func testModelDirectoryRequiredONNXFilesCount() {
        let dir = SupertonicModelDirectory(base: URL(fileURLWithPath: "/tmp/test"))
        XCTAssertEqual(dir.requiredONNXFiles.count, 4,
                       "Must require exactly 4 ONNX model files")
    }

    func testModelDirectoryAllRequiredFilenames() {
        let dir   = SupertonicModelDirectory(base: URL(fileURLWithPath: "/tmp/test"))
        let names = dir.requiredONNXFiles.map { $0.lastPathComponent }
        XCTAssertTrue(names.contains("duration_predictor.onnx"))
        XCTAssertTrue(names.contains("text_encoder.onnx"))
        XCTAssertTrue(names.contains("vector_estimator.onnx"))
        XCTAssertTrue(names.contains("vocoder.onnx"))
    }

    // MARK: - TTSTagStripper

    func testTagsStrippedForNonExpressiveBackend() {
        let system = SystemTTSBackend(apple: AVSpeechTTS())
        XCTAssertFalse(system.supportsExpressionTags)
        let out = TTSTagStripper.prepare("<happy>Hello</happy>, <break/> world.", for: system)
        XCTAssertEqual(out, "Hello, world.")
    }

    func testTagStrippingCollapsesWhitespace() {
        let stripped = TTSTagStripper.strip("One <tag/> two  <other>   </other> three")
        XCTAssertFalse(stripped.contains("  "))
    }

    /// Supertonic supports expression tags — they must be preserved, not stripped.
    func testSupertonicTagsArePreserved() {
        let backend = SupertonicTTSBackend()
        let input   = "Hello <laugh/> world <breath/> test."
        let output  = TTSTagStripper.prepare(input, for: backend)
        XCTAssertEqual(output, input,
                       "Expression tags must not be stripped for Supertonic backend")
    }

    // MARK: - TTSBackendRouter — fallback chain

    func testRouterUsesSystemFallbackWhenPiperUnavailable() {
        // Piper has no paths → unavailable; system is always available.
        let router = makeRouter(preferredId: "piper_onnx")
        XCTAssertEqual(router.resolvedBackend.id, "system_apple",
                       "Router must fall back to system when piper is unavailable")
    }

    func testRouterUsesSystemWhenPreferredIdIsSystem() {
        let router = makeRouter(preferredId: "system_apple")
        XCTAssertEqual(router.resolvedBackend.id, "system_apple")
    }

    func testRouterFallsBackToSystemForUnknownBackendId() {
        let router = makeRouter(preferredId: "nonexistent")
        XCTAssertEqual(router.resolvedBackend.id, "system_apple")
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

    func testRouterContainsSupertonicBackend() {
        let router = makeRouter(preferredId: "system_apple")
        XCTAssertTrue(router.allBackends.contains(where: { $0.id == "supertonic" }))
    }

    func testRouterSupertonicUnavailableFallsBackToSystem() {
        // Supertonic model dir absent → router falls back to system (piper also unconfigured).
        let router = makeRouter(preferredId: "supertonic")
        XCTAssertNotEqual(router.resolvedBackend.id, "supertonic",
                          "Router must not use Supertonic when it is unavailable")
    }

    // MARK: - TTSBackendRouter — speak() does not crash

    func testRouterSpeakDoesNotCrash() {
        let router = makeRouter(preferredId: "system_apple")
        router.start()
        router.speak("Hello, Jarvis.")
        router.stop()
    }

    // MARK: - SupertonicTextChunker

    func testChunkerShortTextReturnsSingle() {
        let chunks = SupertonicTextChunker.chunk("Hello world.", maxSize: 300)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first, "Hello world.")
    }

    func testChunkerSplitsLongText() {
        let long = String(repeating: "Word ", count: 100)  // 500 chars
        let chunks = SupertonicTextChunker.chunk(long, maxSize: 300)
        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.count, 300, "Each chunk must be ≤ 300 chars")
        }
    }

    func testChunkerNoEmptyChunks() {
        let text   = "First sentence. Second sentence. Third sentence."
        let chunks = SupertonicTextChunker.chunk(text, maxSize: 20)
        XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty })
    }

    // MARK: - SupertonicAudioWriter

    func testWAVHasCorrectRIFFHeader() {
        let samples: [Float] = (0..<100).map { _ in Float.random(in: -1...1) }
        let wav = SupertonicAudioWriter.toWAV(samples: samples, sampleRate: 44100)
        XCTAssertGreaterThan(wav.count, 44, "WAV must have header + data")
        let riff = String(bytes: wav.prefix(4), encoding: .ascii)
        let wave = String(bytes: wav[8..<12], encoding: .ascii)
        XCTAssertEqual(riff, "RIFF")
        XCTAssertEqual(wave, "WAVE")
    }

    func testWAVSilenceIsAllZeroSamples() {
        let silence = SupertonicAudioWriter.silenceSamples(sampleRate: 44100, seconds: 0.1)
        XCTAssertTrue(silence.allSatisfy { $0 == 0.0 })
    }

    // MARK: - TTSBenchmarkStore

    func testBenchmarkStoreAddsRecord() {
        let store = TTSBenchmarkStore()
        store.add(makeRecord(error: nil))
        XCTAssertEqual(store.all().count, 1)
    }

    func testBenchmarkStoreSucceededFlag() {
        XCTAssertTrue(makeRecord(error: nil).succeeded)
        XCTAssertFalse(makeRecord(error: "timeout").succeeded)
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
