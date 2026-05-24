import Foundation
import CoreGraphics
import ImageIO

/// Vision analyzer for **background watch** tasks — backed by `LLMRouter`
/// (MiniMax, Gemini, or whichever provider is configured).
///
/// ## Role in the vision architecture
///
/// JarvisController maintains TWO vision pipelines:
///
/// 1. **`LLMVisionAnalyzer`** (this class) — used by `CameraAwarenessService.captureScene()`,
///    `CameraOCRService`, and `PresenceDetectionService`.  Routes through `LLMRouter` so
///    that background watch tasks share the same circuit-breaker and provider selection
///    logic as the chat pipeline.
///
/// 2. **`MiniMaxVisionProvider`** — used by `CameraAwarenessService.captureDescription()`,
///    the user-facing "what can you see" path.  Bypasses `LLMRouter` to use an independent
///    `OpenAIChatClient` with its own timeout and circuit, so a slow vision response can't
///    break the text-chat circuit-breaker.
///
/// Falls back to `AppleVisionAnalyzer` on any error — network, auth, or
/// when the LLM provider is unavailable.
///
/// Latency breakdowns (capture / encode / request / total) are written back
/// to `AppState` so they appear in the debug HUD.
final class LLMVisionAnalyzer: VisionAnalyzing {

    private let llm: LLMRouter
    private let fallback: AppleVisionAnalyzer
    private let state: AppState
    private let maxWidth: () -> Int      // from PreferencesStore
    /// Checked at call time — if false, all requests go straight to Apple Vision.
    /// Lets the user toggle "Use MiniMax for camera" in Settings with zero restart.
    private let isEnabled: () -> Bool

    init(llm: LLMRouter,
         fallback: AppleVisionAnalyzer = AppleVisionAnalyzer(),
         state: AppState,
         maxWidth: @escaping () -> Int,
         isEnabled: @escaping () -> Bool) {
        self.llm       = llm
        self.fallback  = fallback
        self.state     = state
        self.maxWidth  = maxWidth
        self.isEnabled = isEnabled
    }

    // MARK: - VisionAnalyzing

    func analyze(_ frame: CGImage, mode: VisionMode) async throws -> VisionResult {
        // Fast path: if LLM vision is disabled, use Apple Vision directly.
        guard isEnabled() else {
            return try await fallback.analyze(frame, mode: mode)
        }

        let totalStart = Date()

        // 1. Encode to JPEG ── ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
        let encodeStart = Date()
        guard let jpeg = encodeJPEG(frame, maxWidth: maxWidth()) else {
            Log.vision.warning("LLMVisionAnalyzer: JPEG encode failed, falling back to Apple Vision")
            await updateDiagnostics(provider: "apple(encode-fail)", sizeKB: 0,
                                    captureMs: 0, encodeMs: 0, requestMs: 0, totalMs: 0, error: "JPEG encode failed")
            return try await fallback.analyze(frame, mode: mode)
        }
        let encodeMs = Int(-encodeStart.timeIntervalSinceNow * 1000)
        let sizeKB   = jpeg.count / 1024

        // 2. Build prompt for the requested mode ── ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
        let userPrompt: String
        switch mode {
        case .describe:
            userPrompt = "Describe the scene in this image in 1–2 natural, conversational sentences. Mention who is there, what they are doing, and any notable objects or setting. Be vivid and direct — as if you are the camera narrating what you see."
        case .describePerson:
            userPrompt = "Describe the person visible in this image in 1–2 natural sentences. Include their approximate age, what they are wearing, their expression or posture, and anything they are doing. If no person is visible, say so clearly."
        case .describeDesk:
            userPrompt = "What objects can you see in this image? List the most prominent items in a natural sentence or two, as if describing what's on a desk or workspace. Mention devices, papers, food, drinks, or anything notable. Be specific about what you see."
        case .readText:
            userPrompt = "Read all visible text in this image. List each piece of text on a new line, preserving the original wording exactly. If you see no text, say so."
        case .detectPeople:
            userPrompt = "How many people are visible in this image? Answer with a short natural sentence (e.g. 'I can see two people.' or 'No one is in frame.')."
        case .detectHeldObject:
            userPrompt = "What is the person in this image holding in their hands? Name the object precisely (e.g. 'iPhone', 'coffee mug', 'TV remote', 'book'). If nothing is held, say 'I don't see anything in their hands.' Be concise — one or two sentences maximum."
        }

        var request = LLMRequest(
            systemPrompt:  "You are a camera vision assistant. Answer concisely based only on what you can see in the image.",
            userPrompt:    userPrompt,
            contextSummary: nil,
            temperature:   0.2,
            maxTokens:     200,
            responseFormat: .text,
            timeoutSeconds: 25
        )
        request.visionImageData = jpeg

        // 3. Call LLM ── ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
        let requestStart = Date()
        do {
            let response = try await llm.complete(request)
            let requestMs = Int(-requestStart.timeIntervalSinceNow * 1000)
            let totalMs   = Int(-totalStart.timeIntervalSinceNow * 1000)

            Log.vision.info("""
                LLMVisionAnalyzer: OK \
                provider=\(response.providerID, privacy: .public) \
                encode=\(encodeMs)ms request=\(requestMs)ms total=\(totalMs)ms \
                sizeKB=\(sizeKB)
                """)

            await updateDiagnostics(
                provider:  response.providerID,
                sizeKB:    sizeKB,
                captureMs: 0,
                encodeMs:  encodeMs,
                requestMs: requestMs,
                totalMs:   totalMs,
                error:     nil
            )

            return VisionResult(
                summary:        response.text.trimmingCharacters(in: .whitespacesAndNewlines),
                recognizedText: [],
                labels:         [],
                faceCount:      0,
                timestamp:      Date()
            )

        } catch {
            let requestMs = Int(-requestStart.timeIntervalSinceNow * 1000)
            let totalMs   = Int(-totalStart.timeIntervalSinceNow * 1000)
            Log.vision.warning("""
                LLMVisionAnalyzer: LLM failed (\(error.localizedDescription, privacy: .public)), \
                falling back to Apple Vision. encode=\(encodeMs)ms request=\(requestMs)ms
                """)
            await updateDiagnostics(
                provider:  "apple(fallback)",
                sizeKB:    sizeKB,
                captureMs: 0,
                encodeMs:  encodeMs,
                requestMs: requestMs,
                totalMs:   totalMs,
                error:     error.localizedDescription
            )
            return try await fallback.analyze(frame, mode: mode)
        }
    }

    // MARK: - JPEG encode

    /// Downscales `image` so its longest edge ≤ `maxWidth`, then JPEG-encodes.
    /// Returns nil only on catastrophic CFData / CGContext failure.
    private func encodeJPEG(_ image: CGImage, maxWidth: Int) -> Data? {
        let src = image
        let (w, h) = scaledDimensions(width: src.width,
                                       height: src.height,
                                       maxSide: maxWidth)

        // Downscale if needed
        let target: CGImage
        if w < src.width || h < src.height {
            let colorSpace = src.colorSpace ?? CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(data: nil,
                                      width: w, height: h,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                return nil
            }
            ctx.interpolationQuality = .medium
            ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let scaled = ctx.makeImage() else { return nil }
            target = scaled
        } else {
            target = src
        }

        // JPEG encode via ImageIO
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
                data as CFMutableData, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.75
        ]
        CGImageDestinationAddImage(dest, target, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    private func scaledDimensions(width: Int, height: Int, maxSide: Int) -> (Int, Int) {
        guard maxSide > 0, width > 0, height > 0 else { return (width, height) }
        let longest = max(width, height)
        guard longest > maxSide else { return (width, height) }
        let scale = Double(maxSide) / Double(longest)
        return (max(1, Int(Double(width) * scale)),
                max(1, Int(Double(height) * scale)))
    }

    // MARK: - Diagnostics

    @MainActor
    private func updateDiagnostics(provider: String,
                                   sizeKB: Int,
                                   captureMs: Int,
                                   encodeMs: Int,
                                   requestMs: Int,
                                   totalMs: Int,
                                   error: String?) {
        state.lastVisionProvider     = provider
        state.lastVisionImageSizeKB  = sizeKB
        state.lastVisionCaptureMs    = captureMs
        state.lastVisionEncodeMs     = encodeMs
        state.lastVisionRequestMs    = requestMs
        state.lastVisionTotalMs      = totalMs
        state.lastVisionError        = error
    }
}
