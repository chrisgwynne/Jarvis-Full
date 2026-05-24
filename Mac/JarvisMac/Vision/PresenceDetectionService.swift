import Foundation
import CoreGraphics

/// Thin wrapper around VisionAnalyzing for presence / person detection.
final class PresenceDetectionService {
    private let vision: VisionAnalyzing

    init(vision: VisionAnalyzing) {
        self.vision = vision
    }

    func detect(in image: CGImage) async throws -> PresenceState {
        let result = try await vision.analyze(image, mode: .detectPeople)
        let count = result.faceCount
        let summary: String
        switch count {
        case 0:  summary = "No one in frame."
        case 1:  summary = "One person visible."
        default: summary = "\(count) people visible."
        }
        return PresenceState(peopleCount: count, summary: summary, timestamp: result.timestamp)
    }
}
