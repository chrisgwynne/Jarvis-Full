import Foundation
import Observation

/// Picks a provider, runs the request, falls back on failure when
/// allowed by the active mode. Exposes "last used" diagnostics for the
/// UI so the user can see at a glance which provider answered.
@Observable
@MainActor
final class LLMRouter {

    var mode: LLMProviderMode = .auto
    var lastProviderUsed: String = ""
    var lastModelUsed: String = ""
    var lastLatencyMs: Int = 0
    var lastError: String?

    // Concrete types exposed so callers (e.g. SettingsView) can access
    // provider-specific helpers like `previewEndpointURL` without casting.
    let xai:     XAIProvider
    let miniMax: MiniMaxProvider
    let gemini:  GeminiProvider
    let lmStudio: LLMProvider

    init(xai: XAIProvider, miniMax: MiniMaxProvider,
         gemini: GeminiProvider, lmStudio: LLMProvider) {
        self.xai      = xai
        self.miniMax  = miniMax
        self.gemini   = gemini
        self.lmStudio = lmStudio
    }

    /// Whether at least one provider is enabled and looks reachable.
    /// Used by JarvisController to decide if the LLM fallback is even
    /// worth trying — saves an obviously-doomed round trip.
    func isAnyEnabled() async -> Bool {
        guard mode != .disabled else { return false }
        if await xai.isAvailable()     { return true }
        if await miniMax.isAvailable() { return true }
        if await gemini.isAvailable()  { return true }
        if await lmStudio.isAvailable() { return true }
        return false
    }

    /// Try providers in priority order. Returns the first success.
    /// Pass a `circuitBreaker` to skip providers whose circuit is open.
    func complete(
        _ request: LLMRequest,
        circuitBreaker: LLMProviderCircuitBreaker? = nil
    ) async throws -> LLMResponse {
        guard mode != .disabled else {
            lastError = "LLM disabled in Settings"
            throw LLMError.providerDisabled("LLM disabled in Settings")
        }
        let allProviders = selectChain()
        let chain: [LLMProvider]
        if let cb = circuitBreaker {
            chain = allProviders.filter { !cb.isOpen($0.id) }
        } else {
            chain = allProviders
        }
        guard !chain.isEmpty else {
            lastError = allProviders.isEmpty
                ? "No LLM provider configured"
                : "All providers temporarily unavailable (circuit open)"
            throw LLMError.notConfigured(lastError ?? "")
        }

        var lastErr: Error?
        for provider in chain {
            do {
                let response = try await provider.complete(request)
                lastProviderUsed = provider.id
                lastModelUsed   = response.model
                lastLatencyMs   = response.latencyMs
                lastError       = nil
                circuitBreaker?.recordSuccess(provider.id)
                return response
            } catch {
                lastErr = error
                lastError = "\(provider.id): \(error.localizedDescription)"
                circuitBreaker?.recordFailure(provider.id)
                // Telemetry — provider id + short error class only.  No prompt,
                // no token, no model output is included.
                JarvisTelemetry.shared.record(.providerFailed, [
                    "provider": provider.id,
                    "reason":   (error as? LLMError)?.errorDescription
                        ?? String(describing: error).prefix(60).description,
                ])
                continue
            }
        }
        throw lastErr ?? LLMError.notConfigured("All providers failed")
    }

    /// Provider order for the active mode. Modes that only permit one
    /// provider return a single-element list so a failure surfaces
    /// cleanly instead of silently rolling over to the other.
    ///
    /// `internal` (not private) so unit tests can pin down the routing
    /// table without standing up a real network — see
    /// `LLMRouterChainTests` in JarvisMacTests.
    func selectChain() -> [LLMProvider] {
        switch mode {
        case .auto:          return [xai, miniMax, gemini, lmStudio]
        case .xaiFirst:      return [xai, miniMax, gemini, lmStudio]
        case .xaiOnly:       return [xai]
        case .miniMaxFirst:  return [miniMax, xai, gemini, lmStudio]
        case .geminiFirst:   return [gemini, xai, miniMax, lmStudio]
        case .localFirst:    return [lmStudio, xai, miniMax, gemini]
        case .localOnly:     return [lmStudio]
        case .miniMaxOnly:   return [miniMax]
        case .geminiOnly:    return [gemini]
        case .disabled:      return []
        }
    }

    // MARK: - Streaming

    /// Returns a streaming text stream from the first available provider.
    /// Falls back to the default (non-streaming) implementation automatically
    /// if a provider doesn't override `stream()`.
    func stream(
        _ request: LLMRequest,
        circuitBreaker: LLMProviderCircuitBreaker? = nil
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                guard mode != .disabled else {
                    continuation.finish(throwing: LLMError.providerDisabled("LLM disabled"))
                    return
                }
                let allProviders = self.selectChain()
                let chain: [LLMProvider]
                if let cb = circuitBreaker {
                    chain = allProviders.filter { !cb.isOpen($0.id) }
                } else {
                    chain = allProviders
                }
                guard !chain.isEmpty else {
                    continuation.finish(throwing: LLMError.notConfigured("No providers available"))
                    return
                }

                // Try the first provider's stream; fall back to complete() wrapping if it fails.
                var lastError: Error?
                for provider in chain {
                    let inner = provider.stream(request)
                    do {
                        for try await chunk in inner { continuation.yield(chunk) }
                        circuitBreaker?.recordSuccess(provider.id)
                        continuation.finish()
                        return
                    } catch {
                        lastError = error
                        circuitBreaker?.recordFailure(provider.id)
                    }
                }
                continuation.finish(throwing: lastError ?? LLMError.notConfigured("All providers failed"))
            }
        }
    }
}

// MARK: - GHLLMCapable

extension LLMRouter: GHLLMCapable {
    func complete(prompt: String, maxTokens: Int) async throws -> String {
        let request = LLMRequest(
            systemPrompt: "",
            userPrompt: prompt,
            maxTokens: maxTokens
        )
        let response = try await complete(request)
        return response.text
    }
}
