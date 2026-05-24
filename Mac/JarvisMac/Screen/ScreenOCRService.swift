import Foundation
import CoreGraphics

/// Thin wrapper around VisionAnalyzing for screen OCR.
final class ScreenOCRService {
    private let vision: VisionAnalyzing

    init(vision: VisionAnalyzing) {
        self.vision = vision
    }

    func extractText(from image: CGImage) async throws -> [String] {
        let result = try await vision.analyze(image, mode: .readText)
        return result.recognizedText
    }
}
