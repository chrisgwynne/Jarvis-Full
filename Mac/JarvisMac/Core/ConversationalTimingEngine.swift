import Foundation

// MARK: - ConversationalTimingEngine

/// Tracks conversational silence gaps, speech rhythm, and computed "good time
/// to speak" windows so the ProactivityOrchestrator can gate delivery on
/// natural conversational breaks rather than fixed-interval cycles.
///
/// All state is @MainActor. JarvisController calls the update methods from its
/// existing speech/TTS hooks.
@MainActor
final class ConversationalTimingEngine {
    static let shared = ConversationalTimingEngine()

    // MARK: - Configuration

    /// Minimum silence after the user stops speaking before a proactive alert
    /// is considered "well-timed".
    var minSilenceForGoodTiming: Double = 4.0

    /// Any silence gap shorter than this after Jarvis finishes speaking is still
    /// in the "post-TTS recovery" window — avoid interrupting.
    var postTTSRecoverySeconds: Double = 1.5

    /// If the user has been silent for this many seconds they are likely idle,
    /// which is an even better time to surface low-priority events.
    var idleThresholdSeconds: Double = 30.0

    // MARK: - State

    private(set) var lastUserSpeechEndedAt: Date?
    private(set) var lastJarvisSpeechEndedAt: Date?
    private(set) var lastUserSpeechStartedAt: Date?
    private(set) var lastJarvisSpeechStartedAt: Date?

    private(set) var isSpeechActive: Bool = false
    private(set) var isTTSActive: Bool = false

    /// Rolling buffer of recent silence gaps (seconds) between turns.
    private var recentSilenceGaps: [Double] = []
    private let maxGapHistory = 20

    // MARK: - Update hooks (called by JarvisController)

    func userStartedSpeaking() {
        lastUserSpeechStartedAt = Date()
        isSpeechActive = true
    }

    func userStoppedSpeaking() {
        let now = Date()
        if let last = lastJarvisSpeechEndedAt {
            let gap = now.timeIntervalSince(last)
            recordGap(gap)
        }
        lastUserSpeechEndedAt = now
        isSpeechActive = false
    }

    func jarvisStartedSpeaking() {
        lastJarvisSpeechStartedAt = Date()
        isTTSActive = true
    }

    func jarvisStoppedSpeaking() {
        lastJarvisSpeechEndedAt = Date()
        isTTSActive = false
    }

    // MARK: - Timing queries

    /// Seconds since the user last spoke. `.infinity` if never.
    var secondsSinceUserSpeech: Double {
        guard let t = lastUserSpeechEndedAt else { return .infinity }
        return Date().timeIntervalSince(t)
    }

    /// Seconds since Jarvis last finished speaking. `.infinity` if never.
    var secondsSinceJarvisSpeech: Double {
        guard let t = lastJarvisSpeechEndedAt else { return .infinity }
        return Date().timeIntervalSince(t)
    }

    /// True when both user and Jarvis have been silent for `minSilenceForGoodTiming`.
    var isGoodTimeToSpeak: Bool {
        guard !isSpeechActive, !isTTSActive else { return false }
        let userSilence = secondsSinceUserSpeech
        let jarvisSilence = secondsSinceJarvisSpeech
        let silentLongEnough = min(userSilence, jarvisSilence) >= minSilenceForGoodTiming
        let pastRecovery = jarvisSilence >= postTTSRecoverySeconds
        return silentLongEnough && pastRecovery
    }

    /// True when the user appears idle (no speech for `idleThresholdSeconds`).
    var isUserIdle: Bool {
        secondsSinceUserSpeech >= idleThresholdSeconds
    }

    /// Rough estimate of the user's conversational pace (gaps per minute).
    /// Low pace → user is idle or thinking; high pace → active conversation.
    var conversationalPaceScore: Double {
        guard recentSilenceGaps.count >= 3 else { return 0 }
        let avgGap = recentSilenceGaps.suffix(10).reduce(0, +) / Double(min(10, recentSilenceGaps.count))
        // Shorter gaps = higher pace (more back-and-forth)
        return min(1.0, 5.0 / max(avgGap, 0.5))
    }

    /// Recommended delay (seconds) before surfacing a non-critical event.
    /// Returns 0 when it's already a good time to speak.
    func recommendedDelaySeconds(urgency: ProactiveUrgency) -> Double {
        if urgency == .critical { return 0 }
        if isTTSActive { return postTTSRecoverySeconds + 2 }
        if isSpeechActive { return minSilenceForGoodTiming }
        let silence = min(secondsSinceUserSpeech, secondsSinceJarvisSpeech)
        if silence >= minSilenceForGoodTiming { return 0 }
        return minSilenceForGoodTiming - silence
    }

    // MARK: - Private

    private func recordGap(_ gap: Double) {
        recentSilenceGaps.append(gap)
        if recentSilenceGaps.count > maxGapHistory {
            recentSilenceGaps.removeFirst()
        }
    }
}
