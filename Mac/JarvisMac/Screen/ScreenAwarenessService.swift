import Foundation
import CoreGraphics
import os

// MARK: - Service

/// Orchestrates screen capture + Vision OCR → ScreenSummary.
/// Also manages an optional watch mode that fires periodic captures
/// and emits ScreenWatchEvents when the app or content changes.
@MainActor
final class ScreenAwarenessService {

    private let capture: ScreenCaptureService
    private let ocr: ScreenOCRService
    private let analyzer = ScreenContextAnalyzer()

    private(set) var lastSummary: ScreenSummary = .empty

    // Watch mode
    private var watchTask: Task<Void, Never>?
    private(set) var isWatching = false
    var onWatchEvent: ((ScreenWatchEvent) -> Void)?

    init(capture: ScreenCaptureService, vision: VisionAnalyzing) {
        self.capture = capture
        self.ocr = ScreenOCRService(vision: vision)
    }

    // MARK: - Permission

    var permissionGranted: Bool { capture.permissionState == .granted }

    func checkPermission() async {
        await capture.checkPermission()
    }

    // MARK: - On-demand capture

    func analyse() async throws -> ScreenSummary {
        guard let result = try await capture.captureScreen() else {
            return ScreenSummary(
                appName: "", windowTitle: "",
                recognizedText: [], ocrSummary: "",
                assistantSummary: "Screen Recording permission is not granted. Please enable it in System Settings → Privacy → Screen Recording.",
                timestamp: Date()
            )
        }

        let textLines = try await ocr.extractText(from: result.image)
        let ocrSummary = analyzer.ocrSummary(from: textLines)
        let assistantSummary = analyzer.analyze(
            app: result.activeAppName,
            windowTitle: result.activeWindowTitle,
            textLines: textLines
        )

        let summary = ScreenSummary(
            appName: result.activeAppName,
            windowTitle: result.activeWindowTitle,
            recognizedText: textLines,
            ocrSummary: ocrSummary,
            assistantSummary: assistantSummary,
            timestamp: result.timestamp
        )

        lastSummary = summary
        Log.vision.info("screen analysed: app=\(result.activeAppName), \(textLines.count) text lines")
        return summary
    }

    // MARK: - Watch mode

    func startWatching(intervalSeconds: Double = 30.0) {
        guard !isWatching else { return }
        isWatching = true
        Log.vision.info("screen watch started, interval=\(intervalSeconds)s")
        watchTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let event = await self.captureWatchEvent() {
                    self.onWatchEvent?(event)
                }
                try? await Task.sleep(nanoseconds: UInt64(intervalSeconds * 1_000_000_000))
            }
        }
    }

    func stopWatching() {
        watchTask?.cancel()
        watchTask = nil
        isWatching = false
        Log.vision.info("screen watch stopped")
    }

    // MARK: - Private

    private func captureWatchEvent() async -> ScreenWatchEvent? {
        let prev = lastSummary
        guard let summary = try? await analyse() else { return nil }
        let appChanged = summary.appName != prev.appName
        // Significant if app changed or text content changed substantially
        let significantChange = appChanged || summary.ocrSummary != prev.ocrSummary
        return ScreenWatchEvent(
            summary: summary,
            appChanged: appChanged,
            significantChange: significantChange
        )
    }
}
