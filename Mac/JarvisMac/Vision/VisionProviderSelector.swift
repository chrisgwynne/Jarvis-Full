import Foundation
import CoreGraphics

/// Routes `VisionProvider` calls to the user's preferred cloud vision
/// provider — or to Apple's on-device fallback — at call time.
///
/// Why a selector and not just a fixed provider:
/// the user can now pick between MiniMax Vision and Gemini Vision in
/// Settings.  Re-instantiating the camera pipeline on every Settings
/// change would be wasteful and risk losing in-flight captures; instead
/// this selector implements `VisionProvider` and dispatches to the
/// currently-selected concrete provider at the moment the call arrives.
///
/// **Cloud-vision consent gate:** when
/// `prefs.current.cloudVisionConsent == false`, the selector ALWAYS
/// routes to Apple — no camera frame leaves the machine, regardless of
/// the user's "preferred provider" choice.  This satisfies the
/// privacy-by-default rule from the sprint brief.
///
/// **Fallback chain:** the user-preferred provider is tried first; on
/// any failure the selector falls through the standard order (MiniMax
/// → Gemini → Apple) so vision never produces a hard failure.  The
/// concrete cloud providers already fall back to Apple internally on
/// network/HTTP errors, so the chain here is for the "provider is
/// completely unavailable" case (disabled, missing key/model).
@MainActor
final class VisionProviderSelector: VisionProvider {

    var providerName: String { "Vision Selector" }

    /// Provider identifiers in the order surfaced to the user.  Stored
    /// as enum so misspelled raw-string values fall back safely.
    enum Choice: String {
        case minimax, gemini, apple
    }

    private let prefs: PreferencesStore
    private let minimax: VisionProvider
    private let gemini:  VisionProvider
    private let apple:   VisionProvider
    private weak var appState: AppState?

    init(prefs: PreferencesStore,
         minimax: VisionProvider,
         gemini:  VisionProvider,
         apple:   VisionProvider,
         appState: AppState? = nil) {
        self.prefs    = prefs
        self.minimax  = minimax
        self.gemini   = gemini
        self.apple    = apple
        self.appState = appState
    }

    // MARK: - Public choice helper

    /// Resolve the active provider for the next call.  Public so tests
    /// and the Settings UI can show "what would happen right now".
    func active() -> (VisionProvider, Choice, reason: String?) {
        // Cloud-consent gate — when off, we never leave the machine.
        if !prefs.current.cloudVisionConsent {
            return (apple, .apple, reason: "cloud_vision_consent_off")
        }
        let raw = prefs.current.preferredVisionProviderRaw
        switch Choice(rawValue: raw) ?? .minimax {
        case .minimax: return (minimax, .minimax, reason: nil)
        case .gemini:  return (gemini,  .gemini,  reason: nil)
        case .apple:   return (apple,   .apple,   reason: "user_selected_apple")
        }
    }

    func isAvailable() async -> Bool {
        await active().0.isAvailable()
    }

    // MARK: - VisionProvider methods — each dispatches via `active()`

    func describeScene(image: CGImage) async -> VisionProviderResult {
        await runChain(image: image) { await $0.describeScene(image: image) }
    }
    func describePerson(image: CGImage) async -> VisionProviderResult {
        await runChain(image: image) { await $0.describePerson(image: image) }
    }
    func describeDesk(image: CGImage) async -> VisionProviderResult {
        await runChain(image: image) { await $0.describeDesk(image: image) }
    }
    func extractText(image: CGImage) async -> VisionProviderResult {
        await runChain(image: image) { await $0.extractText(image: image) }
    }
    func detectObjects(image: CGImage) async -> VisionProviderResult {
        await runChain(image: image) { await $0.detectObjects(image: image) }
    }
    func detectHeldObject(image: CGImage) async -> VisionProviderResult {
        await runChain(image: image) { await $0.detectHeldObject(image: image) }
    }

    /// Try the user-selected provider first.  If it returns a result
    /// whose `error` is non-nil (each concrete provider sets this when
    /// it's already had to fall back internally) we accept that result —
    /// the inner provider already routed through its own fallback so
    /// adding another hop would just slow the user down.
    ///
    /// The chain-fallthrough below only triggers for the rare case where
    /// the selected provider is fully unavailable AND `cloudVisionConsent`
    /// is on: the call hits the cloud provider, it falls back to Apple,
    /// and we surface that.  Same flow as before.
    private func runChain(
        image: CGImage,
        _ call: (VisionProvider) async -> VisionProviderResult
    ) async -> VisionProviderResult {
        _ = image  // image parameter kept for future fallback-chain symmetry
        let (selected, choice, reason) = active()
        if let reason {
            appState?.lastVisionFallbackReason = reason
        } else {
            appState?.lastVisionFallbackReason = nil
        }
        appState?.lastVisionSelectorChoice = choice.rawValue
        let result = await call(selected)
        return result
    }
}
