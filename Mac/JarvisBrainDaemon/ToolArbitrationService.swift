import Foundation
import OSLog

private let arbitrationLogger = Logger(subsystem: "com.jarvis.brain", category: "arbitration")

// MARK: - ToolOutputKind

/// The kind of output a tool or action requires.
enum ToolOutputKind {
    case voice          // needs TTS
    case visual         // needs screen
    case voiceAndVisual // needs both
    case silent         // background action only
    case notification   // system notification
}

// MARK: - ArbitrationResult

/// The full result of device/modality arbitration.
struct ArbitrationResult {
    let executionDeviceId: String?   // device that should execute the tool (nil = mac/daemon)
    let outputDeviceId: String?      // device to output on (nil = no output)
    let outputMode: OutputMode       // from PresenceInferenceEngine
    let confidence: Float            // 0.0–1.0
    let rationale: String            // human-readable explanation for diagnostics
    let fallbackDeviceId: String?    // if primary output device unavailable
}

// MARK: - ToolArbitrationService

/// Decides the best device and output modality for a given tool/output request.
/// Consults `PresenceInferenceEngine` and `DeviceRegistry` to determine routing.
final class ToolArbitrationService {
    static let shared = ToolArbitrationService()
    private init() {}

    private let lock = NSLock()
    private(set) var lastArbitrationResult: ArbitrationResult?
    private(set) var arbitrationCount: Int = 0

    // MARK: - Main entry point

    /// Returns the best routing for the given output kind.
    ///
    /// Arbitration rules (in priority order):
    /// 1. Preferred device explicitly specified → use it if connected, else fall through
    /// 2. Driving detected → voice-only Android if available, else voice-only Mac
    /// 3. Sleeping detected → suppress everything
    /// 4. Meeting detected → silent overlay on Mac if available, else notification
    /// 5. Headphones on Android → Android voice output
    /// 6. Mac unlocked and recent → Mac voice+visual
    /// 7. Android foreground → Android voice+visual
    /// 8. Fallback: Mac if any connected, else any Android device
    /// 9. Nothing connected: executionDeviceId nil (daemon handles locally)
    func arbitrate(outputKind: ToolOutputKind,
                   preferredDeviceId: String? = nil) -> ArbitrationResult {
        let engine = PresenceInferenceEngine.shared
        let inferredStates = engine.infer()
        let outputMode = engine.preferredOutputMode()
        let registry = DeviceRegistry.shared

        let result = buildResult(
            outputKind: outputKind,
            preferredDeviceId: preferredDeviceId,
            states: inferredStates,
            outputMode: outputMode,
            registry: registry
        )

        lock.withLock {
            lastArbitrationResult = result
            arbitrationCount += 1
        }

        arbitrationLogger.debug("arbitration: outputKind=\(String(describing: outputKind)) outputDevice=\(result.outputDeviceId ?? "nil") mode=\(result.outputMode.rawValue) confidence=\(result.confidence) rationale=\(result.rationale)")

        return result
    }

    // MARK: - Diagnostics

    var diagnosticsSummary: String {
        lock.withLock {
            guard let last = lastArbitrationResult else {
                return "arbitration: count=\(arbitrationCount) last=none"
            }
            return "arbitration: count=\(arbitrationCount) " +
                "outputDevice=\(last.outputDeviceId ?? "nil") " +
                "mode=\(last.outputMode.rawValue) " +
                "confidence=\(String(format: "%.2f", last.confidence))"
        }
    }

    // MARK: - Private helpers

    private func buildResult(
        outputKind: ToolOutputKind,
        preferredDeviceId: String?,
        states: [InferredState: PresenceConfidence],
        outputMode: OutputMode,
        registry: DeviceRegistry
    ) -> ArbitrationResult {

        let connectedDevices = registry.connectedDevices
        let connectedAndroid = registry.connectedAndroid
        let connectedMac = connectedDevices.first(where: { $0.platform == "mac" })

        // Silent actions: no output device needed at all
        if outputKind == .silent {
            return ArbitrationResult(
                executionDeviceId: nil,
                outputDeviceId: nil,
                outputMode: .suppress,
                confidence: 1.0,
                rationale: "silent action — no output required",
                fallbackDeviceId: nil
            )
        }

        // Rule 1: preferred device explicitly specified → use it if connected
        if let preferred = preferredDeviceId {
            if let record = registry.record(for: preferred), record.isConnected {
                let mode = modeSuitableFor(outputKind: outputKind, platform: record.platform)
                arbitrationLogger.debug("arbitration: using preferred deviceId=\(preferred)")
                return ArbitrationResult(
                    executionDeviceId: preferred,
                    outputDeviceId: preferred,
                    outputMode: mode,
                    confidence: 0.95,
                    rationale: "preferred device '\(preferred)' is connected",
                    fallbackDeviceId: fallbackExcluding(preferred, from: connectedDevices)?.deviceId
                )
            }
            arbitrationLogger.debug("arbitration: preferred device '\(preferred)' not connected — falling through")
        }

        // Rule 2: driving detected → voice-only Android, else voice-only Mac
        if let driving = states[.probablyDriving], driving.decayedScore > 0.7 {
            if let android = connectedAndroid.first {
                return ArbitrationResult(
                    executionDeviceId: android.deviceId,
                    outputDeviceId: android.deviceId,
                    outputMode: .voiceOnly,
                    confidence: driving.decayedScore,
                    rationale: "driving detected — voice-only on Android '\(android.deviceId)'",
                    fallbackDeviceId: connectedMac?.deviceId
                )
            }
            if let mac = connectedMac {
                return ArbitrationResult(
                    executionDeviceId: mac.deviceId,
                    outputDeviceId: mac.deviceId,
                    outputMode: .voiceOnly,
                    confidence: driving.decayedScore,
                    rationale: "driving detected — voice-only on Mac (no Android connected)",
                    fallbackDeviceId: nil
                )
            }
        }

        // Rule 3: sleeping → suppress everything
        if let sleeping = states[.probablySleeping], sleeping.decayedScore > 0.8 {
            return ArbitrationResult(
                executionDeviceId: nil,
                outputDeviceId: nil,
                outputMode: .suppress,
                confidence: sleeping.decayedScore,
                rationale: "sleeping detected — suppressing all output",
                fallbackDeviceId: nil
            )
        }

        // Rule 4: meeting → silent overlay on Mac, else notification
        if let meeting = states[.probablyInMeeting], meeting.decayedScore > 0.7 {
            if let mac = connectedMac {
                return ArbitrationResult(
                    executionDeviceId: mac.deviceId,
                    outputDeviceId: mac.deviceId,
                    outputMode: .silentOverlay,
                    confidence: meeting.decayedScore,
                    rationale: "meeting detected — silent overlay on Mac '\(mac.deviceId)'",
                    fallbackDeviceId: connectedAndroid.first?.deviceId
                )
            }
            // No Mac: use notification on Android if available
            if let android = connectedAndroid.first {
                return ArbitrationResult(
                    executionDeviceId: android.deviceId,
                    outputDeviceId: android.deviceId,
                    outputMode: .silentOverlay,
                    confidence: meeting.decayedScore * 0.8,
                    rationale: "meeting detected — notification on Android '\(android.deviceId)' (no Mac)",
                    fallbackDeviceId: nil
                )
            }
        }

        // Rule 5: headphones on Android → Android voice output
        if let headphones = states[.probablyHeadphonesOnly], headphones.decayedScore > 0.7 {
            if let android = connectedAndroid.first(where: { _ in
                // Find an android device with headset
                PresenceStore.shared.allPresence.contains { $0.platform == "android" && $0.hasHeadset }
            }) {
                return ArbitrationResult(
                    executionDeviceId: android.deviceId,
                    outputDeviceId: android.deviceId,
                    outputMode: .voiceOnAndroid,
                    confidence: headphones.decayedScore,
                    rationale: "headphones-only detected — voice on Android '\(android.deviceId)'",
                    fallbackDeviceId: connectedMac?.deviceId
                )
            }
        }

        // Rule 6: Mac unlocked and recent → Mac voice+visual
        if let desktop = states[.probablyAtDesktop], desktop.decayedScore > 0.7 {
            if let mac = connectedMac {
                let mode: OutputMode = (outputKind == .voice) ? .voiceOnMac : .voiceOnMac
                return ArbitrationResult(
                    executionDeviceId: mac.deviceId,
                    outputDeviceId: mac.deviceId,
                    outputMode: mode,
                    confidence: desktop.decayedScore,
                    rationale: "Mac active and unlocked — using Mac '\(mac.deviceId)'",
                    fallbackDeviceId: connectedAndroid.first?.deviceId
                )
            }
        }

        // Rule 7: Android foreground → Android voice+visual
        if let phone = states[.probablyUsingPhone], phone.decayedScore > 0.7 {
            if let android = connectedAndroid.first {
                return ArbitrationResult(
                    executionDeviceId: android.deviceId,
                    outputDeviceId: android.deviceId,
                    outputMode: .auto,
                    confidence: phone.decayedScore,
                    rationale: "phone foreground — using Android '\(android.deviceId)'",
                    fallbackDeviceId: connectedMac?.deviceId
                )
            }
        }

        // Rule 8: Fallback — Mac if connected, else any Android
        if let mac = connectedMac {
            return ArbitrationResult(
                executionDeviceId: mac.deviceId,
                outputDeviceId: mac.deviceId,
                outputMode: outputMode,
                confidence: 0.50,
                rationale: "fallback — Mac '\(mac.deviceId)' is connected",
                fallbackDeviceId: connectedAndroid.first?.deviceId
            )
        }
        if let android = connectedAndroid.first {
            return ArbitrationResult(
                executionDeviceId: android.deviceId,
                outputDeviceId: android.deviceId,
                outputMode: outputMode,
                confidence: 0.45,
                rationale: "fallback — Android '\(android.deviceId)' is connected",
                fallbackDeviceId: nil
            )
        }

        // Rule 9: Nothing connected — daemon handles locally
        return ArbitrationResult(
            executionDeviceId: nil,
            outputDeviceId: nil,
            outputMode: .auto,
            confidence: 0.30,
            rationale: "no devices connected — daemon handles locally",
            fallbackDeviceId: nil
        )
    }

    /// Returns an output mode appropriate for the given output kind and device platform.
    private func modeSuitableFor(outputKind: ToolOutputKind, platform: String) -> OutputMode {
        switch outputKind {
        case .voice:
            return platform == "android" ? .voiceOnAndroid : .voiceOnMac
        case .visual, .voiceAndVisual:
            return platform == "mac" ? .voiceOnMac : .voiceOnAndroid
        case .notification:
            return .auto
        case .silent:
            return .suppress
        }
    }

    /// Returns a fallback device from the list, excluding the primary.
    private func fallbackExcluding(_ primaryId: String,
                                   from devices: [DeviceRecord]) -> DeviceRecord? {
        devices.first(where: { $0.deviceId != primaryId && $0.isConnected })
    }
}
