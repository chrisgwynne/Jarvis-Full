import XCTest
@testable import JarvisMac

/// Locks down the provider ordering for each `LLMProviderMode`.
/// `selectChain()` is the source of truth for which providers get tried
/// first; if it ever regresses, the user sees the wrong model answering
/// their question.  These tests use the real router with no-op
/// providers — no network is touched.
@MainActor
final class LLMRouterChainTests: XCTestCase {

    func test_auto_chain_startsWithXAI() {
        let r = makeRouter(mode: .auto)
        let ids = r.selectChain().map(\.id)
        XCTAssertEqual(ids, ["xai", "minimax", "gemini", "lm_studio"])
    }

    func test_xaiFirst_putsXAIFirst() {
        let r = makeRouter(mode: .xaiFirst)
        XCTAssertEqual(r.selectChain().first?.id, "xai")
    }

    func test_xaiOnly_yieldsOnlyXAI() {
        let r = makeRouter(mode: .xaiOnly)
        XCTAssertEqual(r.selectChain().map(\.id), ["xai"])
    }

    func test_miniMaxFirst_putsMiniMaxFirst() {
        let r = makeRouter(mode: .miniMaxFirst)
        XCTAssertEqual(r.selectChain().first?.id, "minimax")
    }

    func test_geminiFirst_putsGeminiFirst() {
        let r = makeRouter(mode: .geminiFirst)
        XCTAssertEqual(r.selectChain().first?.id, "gemini")
    }

    func test_localFirst_putsLocalFirst() {
        let r = makeRouter(mode: .localFirst)
        XCTAssertEqual(r.selectChain().first?.id, "lm_studio")
    }

    func test_geminiOnly_yieldsOnlyGemini() {
        let r = makeRouter(mode: .geminiOnly)
        XCTAssertEqual(r.selectChain().map(\.id), ["gemini"])
    }

    func test_miniMaxOnly_yieldsOnlyMiniMax() {
        let r = makeRouter(mode: .miniMaxOnly)
        XCTAssertEqual(r.selectChain().map(\.id), ["minimax"])
    }

    func test_localOnly_yieldsOnlyLMStudio() {
        let r = makeRouter(mode: .localOnly)
        XCTAssertEqual(r.selectChain().map(\.id), ["lm_studio"])
    }

    func test_disabled_yieldsEmptyChain() {
        let r = makeRouter(mode: .disabled)
        XCTAssertTrue(r.selectChain().isEmpty)
    }

    // MARK: - Helpers

    private func makeRouter(mode: LLMProviderMode) -> LLMRouter {
        let xai = XAIProvider(
            baseURL:   { "https://api.x.ai/v1" },
            modelName: { "grok-3-mini" },
            enabled:   { false },
            apiKey:    { nil })
        let miniMax = MiniMaxProvider(
            baseURL:   { "https://api.minimax.io/v1" },
            modelName: { "MiniMax-M2.7" },
            enabled:   { false },
            apiKey:    { nil })
        let gemini = GeminiProvider(
            baseURL:     { "https://generativelanguage.googleapis.com/v1beta" },
            modelName:   { "gemini-1.5-flash" },
            visionModel: { "gemini-1.5-flash" },
            enabled:     { false },
            apiKey:      { nil })
        let lmStudio = LMStudioProvider(
            baseURL:   { "http://localhost:1234/v1" },
            modelName: { "local" },
            enabled:   { false })
        let r = LLMRouter(xai: xai, miniMax: miniMax, gemini: gemini, lmStudio: lmStudio)
        r.mode = mode
        return r
    }
}
