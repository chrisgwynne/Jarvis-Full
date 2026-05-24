import Foundation

// MARK: - CameraScene

/// Structured result from a single on-demand camera analysis pass.
struct CameraScene: Equatable {
    let summary: String          // natural-language scene description
    let ocrLines: [String]       // OCR text found in frame
    let peopleCount: Int         // 0 = empty room
    let motionDelta: Double      // 0.0–1.0 from MotionDetector
    let timestamp: Date

    static let empty = CameraScene(
        summary: "", ocrLines: [], peopleCount: 0, motionDelta: 0, timestamp: Date()
    )
}

// MARK: - PresenceState

struct PresenceState: Equatable {
    let peopleCount: Int
    let summary: String          // "One person visible", "No one in frame", etc.
    let timestamp: Date

    static let empty = PresenceState(peopleCount: 0, summary: "", timestamp: Date())
}

// MARK: - CameraWatchEvent

struct CameraWatchEvent {
    let scene: CameraScene
    let previousScene: CameraScene
    let sceneChanged: Bool        // true if summary diverged significantly
    let motionDetected: Bool
}

// MARK: - CameraMotionEvent

struct CameraMotionEvent {
    let delta: Double
    let summary: String
    let timestamp: Date
}
