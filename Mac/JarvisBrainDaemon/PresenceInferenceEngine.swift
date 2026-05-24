import Foundation
import OSLog

private let inferenceLogger = Logger(subsystem: "com.jarvis.brain", category: "inference")

// MARK: - PresenceConfidence

/// Confidence score for an inferred state. Decays linearly to 0 after decaySeconds.
struct PresenceConfidence {
    let label: String
    var score: Float
    let inferredAt: Date
    let decaySeconds: TimeInterval

    var isValid: Bool { Date().timeIntervalSince(inferredAt) < decaySeconds }

    var decayedScore: Float {
        let age = Date().timeIntervalSince(inferredAt)
        guard age < decaySeconds else { return 0 }
        return score * Float(1 - age / decaySeconds)
    }
}

// MARK: - InferredState

enum InferredState: String {
    case probablyDriving           // activityState=="driving" || focusMode=="driving"
    case probablyWalking           // activityState=="walking", not charging
    case probablyCoding            // windows platform active, or mac with long session
    case probablyIdle              // all devices: isAppForeground=false, screen locked, battery not draining fast
    case probablySleeping          // quiet hours (22:00–06:59) or focusMode=="sleep"
    case probablyInMeeting         // focusMode=="meeting"
    case probablyAvailableForVoice // hasHeadset=true or mac unlocked and not screenlocked
    case probablyHeadphonesOnly    // hasHeadset=true on android, mac unavailable
    case probablyAtDesktop         // mac presence updated recently and not locked
    case probablyUsingPhone        // android isAppForeground=true
}

// MARK: - OutputMode

enum OutputMode: String {
    case voiceOnAndroid  // headset present on android
    case voiceOnMac      // mac unlocked, not driving
    case silentOverlay   // coding/meeting — silent visual only
    case voiceOnly       // driving — voice, no visual
    case suppress        // sleeping / deep quiet
    case auto            // no strong signal
}

// MARK: - PresenceInferenceEngine

final class PresenceInferenceEngine {
    static let shared = PresenceInferenceEngine()
    private init() {}

    // MARK: - Main inference

    /// Returns current inferred states with confidence scores derived from PresenceStore snapshot.
    func infer() -> [InferredState: PresenceConfidence] {
        let devices = PresenceStore.shared.allPresence
        var results: [InferredState: PresenceConfidence] = [:]
        let now = Date()

        // probablyDriving: any device has activityState=="driving" OR focusMode=="driving"
        if devices.contains(where: { $0.activityState == "driving" || $0.focusMode == "driving" }) {
            results[.probablyDriving] = PresenceConfidence(
                label: "probably_driving",
                score: 0.95,
                inferredAt: now,
                decaySeconds: 300
            )
        }

        // probablyWalking: any android device has activityState=="walking" and NOT charging
        if devices.contains(where: {
            $0.platform == "android" &&
            $0.activityState == "walking" &&
            ($0.isCharging == nil || $0.isCharging == false)
        }) {
            results[.probablyWalking] = PresenceConfidence(
                label: "probably_walking",
                score: 0.75,
                inferredAt: now,
                decaySeconds: 120
            )
        }

        // probablySleeping: quiet hours (22:00–06:59 local) OR any focusMode=="sleep"
        let isSleepHour = isSleepingHour()
        let hasSleepFocus = devices.contains(where: { $0.focusMode == "sleep" })
        if isSleepHour || hasSleepFocus {
            results[.probablySleeping] = PresenceConfidence(
                label: "probably_sleeping",
                score: 0.85,
                inferredAt: now,
                decaySeconds: 3600
            )
        }

        // probablyInMeeting: any focusMode=="meeting"
        if devices.contains(where: { $0.focusMode == "meeting" }) {
            results[.probablyInMeeting] = PresenceConfidence(
                label: "probably_in_meeting",
                score: 0.90,
                inferredAt: now,
                decaySeconds: 600
            )
        }

        // probablyAvailableForVoice: any device hasHeadset=true OR (mac exists, not screenlocked, isAppForeground=true)
        let macAvailable = devices.contains(where: {
            $0.platform == "mac" && !$0.isScreenLocked && $0.isAppForeground
        })
        if devices.contains(where: { $0.hasHeadset }) || macAvailable {
            results[.probablyAvailableForVoice] = PresenceConfidence(
                label: "probably_available_for_voice",
                score: 0.80,
                inferredAt: now,
                decaySeconds: 180
            )
        }

        // probablyAtDesktop: mac device presence updated within last 120s and not screenlocked
        if devices.contains(where: {
            $0.platform == "mac" &&
            !$0.isScreenLocked &&
            now.timeIntervalSince($0.updatedAt) < 120
        }) {
            results[.probablyAtDesktop] = PresenceConfidence(
                label: "probably_at_desktop",
                score: 0.85,
                inferredAt: now,
                decaySeconds: 120
            )
        }

        // probablyUsingPhone: android isAppForeground=true
        if devices.contains(where: { $0.platform == "android" && $0.isAppForeground }) {
            results[.probablyUsingPhone] = PresenceConfidence(
                label: "probably_using_phone",
                score: 0.75,
                inferredAt: now,
                decaySeconds: 60
            )
        }

        // probablyIdle: all devices have isAppForeground=false AND screen locked AND batteryPercent stable
        if !devices.isEmpty &&
           devices.allSatisfy({ !$0.isAppForeground }) &&
           devices.allSatisfy({ $0.isScreenLocked }) &&
           devices.allSatisfy({ $0.isCharging == nil || $0.isCharging == false }) {
            results[.probablyIdle] = PresenceConfidence(
                label: "probably_idle",
                score: 0.70,
                inferredAt: now,
                decaySeconds: 240
            )
        }

        // probablyHeadphonesOnly: android hasHeadset=true AND mac either absent or screenlocked
        let macAbsentOrLocked = !devices.contains(where: {
            $0.platform == "mac" && !$0.isScreenLocked
        })
        if devices.contains(where: { $0.platform == "android" && $0.hasHeadset }) && macAbsentOrLocked {
            results[.probablyHeadphonesOnly] = PresenceConfidence(
                label: "probably_headphones_only",
                score: 0.85,
                inferredAt: now,
                decaySeconds: 180
            )
        }

        // probablyCoding: windows device present OR mac isAppForeground=true and activityState=="stationary"
        let windowsPresent = devices.contains(where: { $0.platform == "windows" })
        let macCoding = devices.contains(where: {
            $0.platform == "mac" && $0.isAppForeground && $0.activityState == "stationary"
        })
        if windowsPresent || macCoding {
            results[.probablyCoding] = PresenceConfidence(
                label: "probably_coding",
                score: 0.65,
                inferredAt: now,
                decaySeconds: 300
            )
        }

        return results
    }

    // MARK: - Suppression check

    /// Returns true if proactive prompts should be suppressed based on inferred states.
    func shouldSuppressProactivePrompts() -> Bool {
        let states = infer()

        if let driving = states[.probablyDriving], driving.decayedScore > 0.7 {
            inferenceLogger.debug("inference: suppressing — probablyDriving score=\(driving.decayedScore)")
            return true
        }
        if let sleeping = states[.probablySleeping], sleeping.decayedScore > 0.8 {
            inferenceLogger.debug("inference: suppressing — probablySleeping score=\(sleeping.decayedScore)")
            return true
        }
        if let meeting = states[.probablyInMeeting], meeting.decayedScore > 0.7 {
            inferenceLogger.debug("inference: suppressing — probablyInMeeting score=\(meeting.decayedScore)")
            return true
        }
        return false
    }

    // MARK: - Output mode

    /// Returns the preferred output modality for the current context.
    func preferredOutputMode() -> OutputMode {
        let states = infer()

        if let driving = states[.probablyDriving], driving.decayedScore > 0.7 {
            return .voiceOnly
        }
        if let sleeping = states[.probablySleeping], sleeping.decayedScore > 0.8 {
            return .suppress
        }
        if let meeting = states[.probablyInMeeting], meeting.decayedScore > 0.7 {
            return .silentOverlay
        }
        if let headphones = states[.probablyHeadphonesOnly], headphones.decayedScore > 0.7 {
            return .voiceOnAndroid
        }
        if let desktop = states[.probablyAtDesktop], desktop.decayedScore > 0.7 {
            return .voiceOnMac
        }
        return .auto
    }

    // MARK: - Diagnostics

    var diagnosticsSummary: String {
        let states = infer()
        if states.isEmpty { return "inference: no_signals" }
        let parts = states
            .sorted { $0.value.decayedScore > $1.value.decayedScore }
            .map { "\($0.key.rawValue)=\(String(format: "%.2f", $0.value.decayedScore))" }
        return "inference: " + parts.joined(separator: " ")
    }

    // MARK: - Private helpers

    private func isSleepingHour() -> Bool {
        let cal = Calendar.current
        let hour = cal.component(.hour, from: Date())
        // Quiet hours: 22:00–06:59 (spans midnight)
        return hour >= 22 || hour < 7
    }
}
