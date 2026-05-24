import Foundation
import CoreGraphics

// MARK: - ScreenCaptureResult

struct ScreenCaptureResult {
    let image: CGImage
    let activeWindowTitle: String
    let activeAppName: String
    let timestamp: Date
}

// MARK: - ScreenSummary

struct ScreenSummary: Equatable {
    let appName: String
    let windowTitle: String
    let recognizedText: [String]
    let ocrSummary: String
    let assistantSummary: String
    let timestamp: Date

    static let empty = ScreenSummary(
        appName: "", windowTitle: "", recognizedText: [],
        ocrSummary: "", assistantSummary: "", timestamp: Date()
    )
}

// MARK: - ScreenWatchEvent

struct ScreenWatchEvent {
    let summary: ScreenSummary
    let appChanged: Bool
    let significantChange: Bool
}
