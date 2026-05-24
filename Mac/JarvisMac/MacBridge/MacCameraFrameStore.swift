import Foundation

/// Holds at most ONE JPEG frame — the latest captured image.
/// Updated from the AVCapture delegate via `Task { @MainActor in }`.
/// All reads happen on @MainActor, so no extra locking is needed.
@MainActor
final class MacCameraFrameStore {
    private(set) var latestJPEG: Data?
    private(set) var lastFrameTime: Date?

    func update(jpeg: Data) {
        latestJPEG = jpeg
        lastFrameTime = Date()
    }

    func clear() {
        latestJPEG = nil
        lastFrameTime = nil
    }
}
