import Foundation
import CoreGraphics

// MARK: - VisionProviderResult

/// Result from any `VisionProvider` call.
/// Always succeeds structurally — errors are surfaced in `error`, never thrown,
/// so call sites don't need do/catch boilerplate.
struct VisionProviderResult {
    /// The natural-language description or extracted text.
    let description: String
    /// Human-readable name of the provider that answered (e.g. "MiniMax Vision", "Apple Vision").
    let providerUsed: String
    /// Model name if available (nil for Apple Vision).
    let modelUsed: String?
    /// End-to-end latency in milliseconds (capture → response).
    let latencyMs: Int
    /// Width of the image that was sent to the provider (after downscaling).
    let imageWidthPx: Int
    /// Approximate JPEG payload size in kilobytes.
    let imageSizeKB: Int
    /// Non-nil if the primary provider failed; describes what went wrong.
    let error: String?
    let timestamp: Date

    // MARK: Structured entity fields (populated by providers that return JSON)

    /// All notable visual observations extracted from the scene.
    /// e.g. ["black thick-framed glasses", "dark grey zip-up hoodie", "iPhone in left hand"]
    let detectedEntities: [String]

    /// 0.0–1.0 provider-reported confidence. nil = not available.
    let confidenceScore: Float?

    // MARK: Derived

    var succeeded: Bool { error == nil }

    /// A concise one-line diagnostic for the debug HUD.
    var diagnostic: String {
        var parts = ["\(providerUsed)"]
        if let m = modelUsed { parts.append(m) }
        parts.append("\(latencyMs)ms")
        parts.append("\(imageSizeKB)KB")
        if let c = confidenceScore { parts.append("conf:\(Int(c * 100))%") }
        if let e = error { parts.append("⚠ \(e.prefix(40))") }
        return parts.joined(separator: " · ")
    }

    // MARK: Factory

    static func failure(provider: String, error: String) -> VisionProviderResult {
        VisionProviderResult(
            description:      "I couldn't get a visual description right now.",
            providerUsed:     provider,
            modelUsed:        nil,
            latencyMs:        0,
            imageWidthPx:     0,
            imageSizeKB:      0,
            error:            error,
            timestamp:        Date(),
            detectedEntities: [],
            confidenceScore:  nil
        )
    }
}

// MARK: - VisionProvider

/// Protocol for any component that can produce natural-language descriptions
/// from camera frames.
///
/// All methods are async and never throw — errors are contained in the
/// returned `VisionProviderResult.error` field.  This keeps call sites clean.
///
/// **Implementations:**
///   - `MiniMaxVisionProvider`  — multimodal LLM via MiniMax API (primary)
///   - `AppleVisionFallbackProvider` — on-device Vision framework (fallback)
protocol VisionProvider: AnyObject {
    /// Display name shown in Settings/diagnostics.
    var providerName: String { get }

    /// Async availability check — true if credentials and model are present.
    func isAvailable() async -> Bool

    /// General scene description: people, objects, environment, lighting.
    func describeScene(image: CGImage) async -> VisionProviderResult

    /// Person-focused description: clothing, posture, expression, activity.
    /// Safety: must NOT identify, infer identity, or infer sensitive traits.
    func describePerson(image: CGImage) async -> VisionProviderResult

    /// Desk/workspace description: devices, papers, objects, drinks, food.
    func describeDesk(image: CGImage) async -> VisionProviderResult

    /// OCR: extract all visible readable text from the image.
    func extractText(image: CGImage) async -> VisionProviderResult

    /// Object detection: list notable objects visible in the frame.
    func detectObjects(image: CGImage) async -> VisionProviderResult

    /// Handheld-object detection: focus specifically on what is in the person's hands.
    func detectHeldObject(image: CGImage) async -> VisionProviderResult
}

// MARK: - VisionMode → VisionProvider bridge

extension VisionProvider {
    /// Dispatch a `VisionMode` enum value to the correct named method.
    func analyze(image: CGImage, mode: VisionMode) async -> VisionProviderResult {
        switch mode {
        case .describe:           return await describeScene(image: image)
        case .describePerson:     return await describePerson(image: image)
        case .describeDesk:       return await describeDesk(image: image)
        case .readText:           return await extractText(image: image)
        case .detectPeople:       return await detectObjects(image: image)
        case .detectHeldObject:   return await detectHeldObject(image: image)
        }
    }
}
