import Foundation
import ScreenCaptureKit
import CoreGraphics
import os

// MARK: - Service

/// Event-driven, on-demand screen capture using ScreenCaptureKit.
/// No continuous recording — callers request a single snapshot and await.
/// Requires `com.apple.security.screen-recording` entitlement (or explicit
/// user permission granted via System Settings → Privacy → Screen Recording).
@MainActor
final class ScreenCaptureService {

    enum PermissionState {
        case unknown, granted, denied
    }

    private(set) var permissionState: PermissionState = .unknown

    // MARK: - Permission

    func checkPermission() async {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            permissionState = .granted
            Log.vision.info("screen recording permission: granted")
        } catch {
            permissionState = .denied
            Log.vision.warning("screen recording permission: denied — \(error.localizedDescription)")
        }
    }

    // MARK: - Capture

    /// Capture the frontmost display. Returns nil if permission is denied or
    /// no display is available. The image is not stored — caller decides what
    /// to do with it.
    func captureScreen() async throws -> ScreenCaptureResult? {
        if permissionState == .unknown { await checkPermission() }
        guard permissionState == .granted else {
            Log.vision.warning("captureScreen: permission denied")
            return nil
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard let display = content.displays.first else {
            Log.vision.warning("captureScreen: no displays available")
            return nil
        }

        // Active window info (best-effort)
        let frontWindow = content.windows
            .filter { $0.isOnScreen }
            .sorted { ($0.frame.width * $0.frame.height) > ($1.frame.width * $1.frame.height) }
            .first
        let windowTitle  = frontWindow?.title ?? ""
        let appName      = frontWindow?.owningApplication?.applicationName ?? ""

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg    = SCStreamConfiguration()
        cfg.width  = Int(display.frame.width)
        cfg.height = Int(display.frame.height)
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        cfg.queueDepth = 1
        cfg.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)

        Log.vision.info("captureScreen: \(image.width)×\(image.height), app=\(appName)")

        return ScreenCaptureResult(
            image: image,
            activeWindowTitle: windowTitle,
            activeAppName: appName,
            timestamp: Date()
        )
    }
}
