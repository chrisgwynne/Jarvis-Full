import Foundation

// MARK: - FastResponse

/// A deterministic spoken answer produced without calling the LLM.
/// Returned by `FastResponseRouter` for well-known conversational queries.
struct FastResponse {
    let text: String
    let speakImmediately: Bool
    let confidence: Double
    let source: Source

    enum Source: String {
        case capabilities  = "capabilities"
        case architecture  = "architecture"
        case runtimeState  = "runtime_state"
        case integrations  = "integrations"
    }
}

// MARK: - FastResponseRouter

/// Pre-LLM fast response layer that intercepts common conversational queries
/// — "what can you do", "how do you work", "are you local", "what models are
/// you using" — and answers them deterministically in < 5 ms from live data
/// in PreferencesStore and AppState.
///
/// Sits between the deterministic intent router and `tryLLMFallback` in
/// `handleTranscript`. If it returns a `FastResponse`, the LLM call is
/// skipped entirely and the answer is spoken immediately.
@MainActor
final class FastResponseRouter {

    // MARK: - Entry point

    func respond(
        normalized text: String,
        prefs: Preferences,
        state: AppState,
        llmMode: LLMProviderMode,
        capabilities: CapabilityRegistry
    ) -> FastResponse? {

        if matchesCapabilityQuery(text) {
            return FastResponse(
                text: capabilities.spokenSummary(state: state, prefs: prefs),
                speakImmediately: true, confidence: 0.93, source: .capabilities)
        }

        if matchesArchitectureQuery(text) {
            return FastResponse(
                text: buildArchitectureAnswer(prefs: prefs, state: state, llmMode: llmMode),
                speakImmediately: true, confidence: 0.91, source: .architecture)
        }

        if matchesRuntimeStateQuery(text) {
            return FastResponse(
                text: buildRuntimeAnswer(prefs: prefs, llmMode: llmMode),
                speakImmediately: true, confidence: 0.91, source: .runtimeState)
        }

        if matchesIntegrationQuery(text) {
            return FastResponse(
                text: buildIntegrationAnswer(prefs: prefs, state: state),
                speakImmediately: true, confidence: 0.89, source: .integrations)
        }

        return nil
    }

    // MARK: - Pattern matchers

    private func matchesCapabilityQuery(_ t: String) -> Bool {
        t == "what can you do" || t == "what do you do" ||
        t == "what are you capable of" || t == "capabilities" ||
        t == "help" || t == "what can you help with" ||
        t.hasPrefix("what can you do") ||
        t.contains("what are your capabilities") ||
        t.contains("what features do you have") ||
        t.contains("what can you help") ||
        t.contains("what can you control") ||
        t.contains("what can you do for me") ||
        t.contains("what do you support") ||
        t.contains("what do you offer")
    }

    private func matchesArchitectureQuery(_ t: String) -> Bool {
        t.contains("how do you work") ||
        t.contains("how are you built") ||
        t.contains("how does this work") ||
        t.contains("are you local") ||
        t.contains("are you cloud") ||
        t.contains("do you run locally") ||
        t.contains("where do you run") ||
        t.contains("are you on device") ||
        t.contains("do you send data") ||
        t.contains("what kind of ai are you") ||
        t.contains("are you an ai") ||
        t.contains("tell me how you work") ||
        t.contains("how do you function") ||
        t.contains("what are you based on")
    }

    private func matchesRuntimeStateQuery(_ t: String) -> Bool {
        t.contains("what model are you") ||
        t.contains("which model are you") ||
        t.contains("what llm") ||
        t.contains("which llm") ||
        t.contains("what speech engine") ||
        t.contains("what tts engine") ||
        t.contains("what voice engine") ||
        t.contains("how do you listen") ||
        t.contains("how do you hear") ||
        (t.contains("what are you using") &&
            (t.contains("model") || t.contains("engine") || t.contains("speech"))) ||
        (t.contains("what version") && (t.contains("model") || t.contains("ai")))
    }

    private func matchesIntegrationQuery(_ t: String) -> Bool {
        t.contains("what integrations") ||
        t.contains("what are you connected") ||
        t.contains("what can you connect") ||
        t.contains("what services do you") ||
        t.contains("what apps can you") ||
        (t.contains("smart home") && t.contains("what")) ||
        (t.contains("home assistant") && (t.contains("what") || t.contains("connect"))) ||
        t.contains("what are you connected to")
    }

    // MARK: - Answer builders

    private func buildArchitectureAnswer(
        prefs: Preferences, state: AppState, llmMode: LLMProviderMode
    ) -> String {
        let sttDesc: String
        switch prefs.speechEngine {
        case .apple:   sttDesc = "Apple on-device speech recognition"
        case .whisper: sttDesc = "Whisper, a local offline model"
        }
        let ttsDesc: String
        switch prefs.ttsEngine {
        case .appleSystem: ttsDesc = "Apple's built-in voice"
        case .piper:       ttsDesc = "Piper, a local neural voice"
        }
        let isFullyLocal = (llmMode == .localOnly || llmMode == .disabled)
        let cloudNote = isFullyLocal
            ? "I run entirely on your Mac — no cloud required."
            : "I use local processing first, with optional cloud reasoning when enabled."
        return "I'm a native macOS voice assistant. I listen using \(sttDesc) and speak using \(ttsDesc). \(cloudNote)"
    }

    private func buildRuntimeAnswer(prefs: Preferences, llmMode: LLMProviderMode) -> String {
        let sttName: String
        switch prefs.speechEngine {
        case .apple:   sttName = "Apple Speech"
        case .whisper: sttName = "Whisper"
        }
        let ttsName: String
        switch prefs.ttsEngine {
        case .appleSystem: ttsName = "Apple System Voice"
        case .piper:       ttsName = "Piper ONNX"
        }
        let llmDesc: String
        switch llmMode {
        case .auto, .xaiFirst:        llmDesc = "xAI (Grok) with MiniMax, Gemini, and local fallback"
        case .xaiOnly:                llmDesc = "xAI (Grok)"
        case .miniMaxFirst:           llmDesc = "MiniMax with xAI, Gemini, and local fallback"
        case .geminiFirst:            llmDesc = "Gemini with xAI, MiniMax, and local fallback"
        case .geminiOnly:             llmDesc = "Gemini"
        case .localFirst, .localOnly: llmDesc = "llama.cpp (local)"
        case .miniMaxOnly:            llmDesc = "MiniMax"
        case .disabled:               llmDesc = "none — fully offline"
        }
        return "I'm using \(sttName) for listening, \(ttsName) for speaking, and \(llmDesc) for reasoning."
    }

    private func buildIntegrationAnswer(prefs: Preferences, state: AppState) -> String {
        var parts: [String] = []
        if !(prefs.smartHomeBaseURL ?? "").isEmpty { parts.append("Home Assistant") }
        if !prefs.androidTrustedDeviceIDs.isEmpty  { parts.append("Android handoff") }
        if state.cameraStatus.isHealthy            { parts.append("live camera") }
        parts.append("screen awareness")
        parts.append("local memory")
        parts.append("news feeds")

        if parts.count == 1 { return "I'm connected to \(parts[0])." }
        var list = parts
        let last = list.removeLast()
        return "I'm connected to \(list.joined(separator: ", ")), and \(last)."
    }
}
