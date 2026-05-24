import Foundation
import CoreGraphics

/// `VisionProvider` implementation backed by Apple's on-device Vision framework.
///
/// Used as the fallback when MiniMax vision is unavailable or fails.
/// Provides basic structural descriptions (people count, OCR text) but
/// cannot produce the rich natural-language understanding of an LLM.
///
/// All results are honest about capability limits — we never fake rich
/// descriptions when only primitive detection is available.
final class AppleVisionFallbackProvider: VisionProvider {

    var providerName: String { "Apple Vision" }

    private let analyzer = AppleVisionAnalyzer()

    func isAvailable() async -> Bool { true }    // always available (on-device)

    func describeScene(image: CGImage) async -> VisionProviderResult {
        await analyze(image: image, mode: .describe)
    }

    func describePerson(image: CGImage) async -> VisionProviderResult {
        await analyze(image: image, mode: .describePerson)
    }

    func describeDesk(image: CGImage) async -> VisionProviderResult {
        await analyze(image: image, mode: .describeDesk)
    }

    func extractText(image: CGImage) async -> VisionProviderResult {
        await analyze(image: image, mode: .readText)
    }

    func detectObjects(image: CGImage) async -> VisionProviderResult {
        await analyze(image: image, mode: .detectPeople)
    }

    func detectHeldObject(image: CGImage) async -> VisionProviderResult {
        // Apple Vision doesn't have a specific hand/held-object model.
        // Fall through to detectPeople (which runs rectangle + face detection)
        // and note the limitation in the response.
        let base = await analyze(image: image, mode: .detectPeople)
        // Wrap with a note so the user knows on-device limits.
        let note = base.description.isEmpty
            ? "On-device analysis couldn't identify a held object. Try enabling cloud vision for richer results."
            : base.description + " (On-device analysis — held object detection is limited without cloud vision.)"
        return VisionProviderResult(
            description:      note,
            providerUsed:     providerName,
            modelUsed:        nil,
            latencyMs:        base.latencyMs,
            imageWidthPx:     base.imageWidthPx,
            imageSizeKB:      base.imageSizeKB,
            error:            base.error,
            timestamp:        base.timestamp,
            detectedEntities: [],
            confidenceScore:  nil
        )
    }

    // MARK: - Internal

    private func analyze(image: CGImage, mode: VisionMode) async -> VisionProviderResult {
        let start = Date()
        do {
            let result = try await analyzer.analyze(image, mode: mode)
            let ms = Int(-start.timeIntervalSinceNow * 1000)
            return VisionProviderResult(
                description:      result.summary,
                providerUsed:     providerName,
                modelUsed:        nil,
                latencyMs:        ms,
                imageWidthPx:     image.width,
                imageSizeKB:      0,
                error:            nil,
                timestamp:        result.timestamp,
                detectedEntities: [],
                confidenceScore:  nil
            )
        } catch {
            return VisionProviderResult.failure(
                provider: providerName,
                error: error.localizedDescription
            )
        }
    }
}
