import Foundation

/// Tracks which subsystem currently holds the microphone or audio output.
///
/// All callers run on the main actor, so there is no need for an explicit
/// lock — serial execution is already guaranteed. The coordinator's value
/// is observability: every mode change is logged with a `[AudioSession]`
/// prefix so race conditions can be diagnosed from log output alone.
///
/// Modes are mutually exclusive by convention. A subsystem must call
/// `transition(to:from:)` before starting audio work and again when it
/// finishes, so the current mode always reflects live hardware state.
@MainActor final class AudioSessionCoordinator {

    static let shared = AudioSessionCoordinator()

    enum CaptureMode: String {
        /// No audio hardware is in use.
        case idle
        /// AppleWakeWordService is running its continuous detection loop.
        case passiveWake
        /// AppleSpeechRecognizer is running an active STT session.
        case activeSTT
        /// TextToSpeechService is actively producing audio output.
        case ttsSpeaking
        /// A news or media stream is playing back through the system.
        case newsPlayback
    }

    private(set) var currentMode: CaptureMode = .idle

    /// Mark a mode transition. Safe to call from any context that is
    /// guaranteed to be executing on the main thread — the callers
    /// (AppleWakeWordService, AppleSpeechRecognizer) document that their
    /// start/stop methods must be called from the main thread, matching
    /// JarvisController's @MainActor isolation.
    nonisolated func transition(to newMode: CaptureMode, from requestor: String) {
        MainActor.assumeIsolated { [self] in
            guard self.currentMode != newMode else { return }
            Log.audio.info("[AudioSession] \(self.currentMode.rawValue, privacy: .public) → \(newMode.rawValue, privacy: .public) requestor=\(requestor, privacy: .public)")
            self.currentMode = newMode
        }
    }
}
