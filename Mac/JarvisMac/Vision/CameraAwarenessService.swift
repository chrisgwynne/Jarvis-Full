import Foundation
import CoreGraphics
import os

/// Orchestrates on-demand camera captures + an optional low-frequency watch
/// loop. No raw frames are persisted. All state mutations happen on MainActor.
///
/// Two vision paths co-exist for a smooth transition:
///  - **`visionProvider`** (new, preferred) — `VisionProvider` protocol used for
///    all user-facing on-demand description calls.  Supports `MiniMaxVisionProvider`
///    and `AppleVisionFallbackProvider`.
///  - **`vision`** (legacy) — `VisionAnalyzing` used by `CameraOCRService`,
///    `PresenceDetectionService`, and the background watch tick.
@MainActor
final class CameraAwarenessService {

    private let camera: CameraManager
    private let vision: VisionAnalyzing
    private let motion: MotionDetector
    private let ocr: CameraOCRService
    private let presence: PresenceDetectionService
    private let analyzer = CameraSceneAnalyzer()

    /// Primary vision provider for user-facing description commands.
    /// When set, takes priority over the legacy `vision: VisionAnalyzing` path
    /// for `captureDescription()`.  Inject `MiniMaxVisionProvider` here.
    var visionProvider: VisionProvider?

    private(set) var lastScene: CameraScene = .empty
    private(set) var lastPresence: PresenceState = .empty
    private(set) var isWatching = false

    // Callbacks for callers (JarvisController)
    var onSceneChange: ((CameraWatchEvent) -> Void)?
    var onMotionEvent: ((CameraMotionEvent) -> Void)?

    private var watchTask: Task<Void, Never>?

    init(camera: CameraManager, vision: VisionAnalyzing, motion: MotionDetector) {
        self.camera = camera
        self.vision = vision
        self.motion = motion
        self.ocr = CameraOCRService(vision: vision)
        self.presence = PresenceDetectionService(vision: vision)
    }

    // MARK: - On-demand capture

    /// Full analysis: OCR + presence + scene description.
    func captureScene() async -> CameraScene {
        guard let image = camera.captureStill() else {
            Log.vision.warning("captureScene: no frame available")
            return CameraScene(
                summary: ResponsePlaybook.defaults[ResponseKey.cameraNotReady]?.first
                    ?? "Camera isn't ready.",
                ocrLines: [], peopleCount: 0, motionDelta: 0, timestamp: Date()
            )
        }

        do {
            let result = try await vision.analyze(image, mode: .describe)
            let motionReading = motion.evaluate(image)
            let summary = analyzer.analyze(
                visionSummary: result.summary,
                ocrLines: result.recognizedText,
                peopleCount: result.faceCount,
                motionDelta: motionReading.delta
            )
            let scene = CameraScene(
                summary: summary,
                ocrLines: result.recognizedText,
                peopleCount: result.faceCount,
                motionDelta: motionReading.delta,
                timestamp: result.timestamp
            )
            lastScene = scene
            Log.vision.info("captureScene: people=\(result.faceCount), ocr=\(result.recognizedText.count) lines")
            return scene
        } catch {
            Log.vision.error("captureScene failed: \(error.localizedDescription)")
            return CameraScene(
                summary: "Vision analysis failed: \(error.localizedDescription)",
                ocrLines: [], peopleCount: 0, motionDelta: 0, timestamp: Date()
            )
        }
    }

    /// Natural-language description pass. Bypasses `CameraSceneAnalyzer` entirely.
    ///
    /// Uses `visionProvider` (MiniMax or Apple fallback) when injected;
    /// falls back to the legacy `VisionAnalyzing` path if no provider is set.
    ///
    /// Returns the description string AND the provider result for diagnostics.
    func captureDescription(mode: VisionMode = .describe) async -> (summary: String, result: VisionProviderResult?) {
        guard let image = camera.captureStill() else {
            let msg = ResponsePlaybook.defaults[ResponseKey.cameraNotReady]?.first
                ?? "Camera isn't ready."
            return (msg, nil)
        }

        // ── New VisionProvider path (preferred) ───────────────────────────────
        if let provider = visionProvider {
            let result = await provider.analyze(image: image, mode: mode)
            let summary = result.description.trimmingCharacters(in: .whitespacesAndNewlines)
            lastScene = CameraScene(
                summary:     summary,
                ocrLines:    [],
                peopleCount: 0,
                motionDelta: 0,
                timestamp:   result.timestamp
            )
            Log.vision.info("""
                captureDescription: provider=\(result.providerUsed, privacy: .public) \
                latency=\(result.latencyMs)ms \
                error=\(result.error ?? "none", privacy: .public)
                """)
            return (summary, result)
        }

        // ── Legacy VisionAnalyzing path ───────────────────────────────────────
        do {
            let result = try await vision.analyze(image, mode: mode)
            let summary = result.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            lastScene = CameraScene(
                summary:     summary,
                ocrLines:    result.recognizedText,
                peopleCount: result.faceCount,
                motionDelta: 0,
                timestamp:   result.timestamp
            )
            return (summary, nil)
        } catch {
            Log.vision.error("captureDescription failed: \(error.localizedDescription)")
            return ("Vision analysis failed.", nil)
        }
    }

    /// OCR-only pass.
    func captureOCR() async -> [String] {
        guard let image = camera.captureStill() else { return [] }
        return (try? await ocr.extractText(from: image)) ?? []
    }

    /// Presence-only pass.
    func capturePresence() async -> PresenceState {
        guard let image = camera.captureStill() else {
            return PresenceState(peopleCount: 0, summary: "Camera unavailable.", timestamp: Date())
        }
        let state = (try? await presence.detect(in: image)) ?? .empty
        lastPresence = state
        return state
    }

    // MARK: - Watch mode

    func startWatching(intervalSeconds: Double = 15.0) {
        guard !isWatching else { return }
        isWatching = true
        motion.reset()
        Log.vision.info("camera watch started, interval=\(intervalSeconds)s")

        watchTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.performWatchTick()
                try? await Task.sleep(nanoseconds: UInt64(intervalSeconds * 1_000_000_000))
            }
        }
    }

    func stopWatching() {
        watchTask?.cancel()
        watchTask = nil
        isWatching = false
        Log.vision.info("camera watch stopped")
    }

    // MARK: - Private

    private func performWatchTick() async {
        let prev = lastScene
        let scene = await captureScene()

        let sceneChanged = !prev.summary.isEmpty && scene.summary != prev.summary
        let motionDetected = scene.motionDelta > 0.04

        if motionDetected {
            let event = CameraMotionEvent(
                delta: scene.motionDelta,
                summary: "Motion detected (delta \(String(format: "%.2f", scene.motionDelta)))",
                timestamp: scene.timestamp
            )
            onMotionEvent?(event)
        }

        let watchEvent = CameraWatchEvent(
            scene: scene,
            previousScene: prev,
            sceneChanged: sceneChanged,
            motionDetected: motionDetected
        )
        onSceneChange?(watchEvent)
    }
}
