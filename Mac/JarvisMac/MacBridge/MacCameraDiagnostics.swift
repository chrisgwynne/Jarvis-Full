import Foundation
import Observation

/// Structured diagnostic log events — mirrors the spec's CAMERA_* constants.
enum CameraLogEvent {
    case serverEnabled, serverDisabled
    case healthRequest, snapshotRequest
    case streamStarted, streamStopped
    case clientConnected, clientDisconnected
    case permissionDenied
    case captureStarted, captureStopped
    case frameEncoded
    case error(String)
}

/// Observable status for the camera server — drives MacCameraSettingsView.
@Observable
@MainActor
final class MacCameraDiagnostics {

    var isEnabled       = false
    var permission      = "notDetermined"   // "notDetermined" | "granted" | "denied"
    var isCapturing     = false
    var activeViewers   = 0
    var lastFrameTime:  Date?  = nil
    var lastStreamError: String? = nil
    var totalFrames     = 0
    var snapshotPath    = "/camera/snapshot"
    var streamPath      = "/camera/stream"

    func log(_ event: CameraLogEvent) {
        switch event {
        case .serverEnabled:       isEnabled = true
        case .serverDisabled:      isEnabled = false; isCapturing = false; activeViewers = 0
        case .captureStarted:      isCapturing = true
        case .captureStopped:      isCapturing = false; lastFrameTime = nil
        case .clientConnected:     activeViewers += 1
        case .clientDisconnected:  activeViewers = max(0, activeViewers - 1)
        case .permissionDenied:    permission = "denied"
        case .frameEncoded:        totalFrames += 1; lastFrameTime = Date()
        case .error(let msg):      lastStreamError = msg
        default: break
        }
    }

    var statusLine: String {
        guard isEnabled else { return "Disabled" }
        if isCapturing { return "Capturing · \(activeViewers) viewer\(activeViewers == 1 ? "" : "s")" }
        return "Ready (camera idle)"
    }
}
