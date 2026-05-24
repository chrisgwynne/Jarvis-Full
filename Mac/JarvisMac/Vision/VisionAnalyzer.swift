import Foundation
import CoreGraphics

/// What `VisionAnalyzing` returns. Each mode produces a natural-language
/// `summary` plus structured fields for the widget.
struct VisionResult: Equatable {
    let summary: String
    let recognizedText: [String]
    let labels: [String]
    let faceCount: Int
    let timestamp: Date

    static let empty = VisionResult(summary: "",
                                    recognizedText: [],
                                    labels: [],
                                    faceCount: 0,
                                    timestamp: Date())
}

enum VisionMode: Equatable {
    case describe          // "what can you see" — general scene
    case describePerson    // "describe me" — focus on appearance: clothing, glasses, accessories
    case describeDesk      // "what's on my desk" — focus on objects/items in the scene
    case readText          // "read this"
    case detectPeople      // "is anyone there"
    case detectHeldObject  // "what am I holding?" — focus on hands and handheld items
}

protocol VisionAnalyzing: AnyObject {
    func analyze(_ frame: CGImage, mode: VisionMode) async throws -> VisionResult
    /// Convenience for Phase-1 callers that just want a sentence.
    func describe(frame: CGImage) async throws -> String
}

extension VisionAnalyzing {
    func describe(frame: CGImage) async throws -> String {
        try await analyze(frame, mode: .describe).summary
    }
}

/// Phase-2: stays around as a safe default for previews / unit tests.
final class PlaceholderVisionAnalyzer: VisionAnalyzing {
    func analyze(_ frame: CGImage, mode: VisionMode) async throws -> VisionResult {
        let w = frame.width, h = frame.height
        return VisionResult(
            summary: "Vision placeholder: \(w)×\(h) frame captured.",
            recognizedText: [],
            labels: [],
            faceCount: 0,
            timestamp: Date()
        )
    }
}
