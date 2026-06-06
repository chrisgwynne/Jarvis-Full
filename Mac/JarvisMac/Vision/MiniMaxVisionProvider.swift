import Foundation
import CoreGraphics
import ImageIO
import os

// MARK: - MiniMaxVisionProvider

/// Vision provider backed by MiniMax's multimodal model.
///
/// Improvements over the previous iteration:
///
/// **Structured JSON responses** — all prompts request a JSON object with
/// `summary`, `confidence_score`, `detected_entities`, and `visual_context`
/// (clothing, accessories, held_objects, ocr_text).  The summary is used for
/// TTS; the structured fields populate `VisionProviderResult.detectedEntities`
/// and `.confidenceScore`.  Plain-text fallback is applied if JSON parsing fails.
///
/// **ROI crops via Apple Vision** — for `describePerson` and `detectHeldObject`,
/// `VisionROIExtractor` runs locally first to find face / hand bounding boxes.
/// The crop is JPEG-encoded and sent as a *second* user-message turn so the
/// model sees both the full frame and the zoomed region simultaneously.
///
/// **Confidence-aware replies** — responses with `confidence_score < 0.40`
/// are prepended with an uncertainty qualifier so Jarvis never confidently
/// asserts things it can't see clearly.
///
/// **Prompt specificity** — every `VisionMode` has its own highly targeted
/// system + user prompt.  Generic "describe this image" instructions are gone.
final class MiniMaxVisionProvider: VisionProvider {

    var providerName: String { "MiniMax Vision" }

    // MARK: - Configuration (closures evaluated at call time)

    private let baseURL:   () -> String
    private let modelName: () -> String
    private let apiKey:    () -> String?
    private let isEnabled: () -> Bool
    private let maxWidth:  () -> Int
    private let fallback:  AppleVisionFallbackProvider
    private let appState:  AppState?

    private let log = Logger(subsystem: "com.jarvis", category: "vision.minimax")

    init(baseURL:   @escaping () -> String,
         modelName: @escaping () -> String,
         apiKey:    @escaping () -> String?,
         isEnabled: @escaping () -> Bool,
         maxWidth:  @escaping () -> Int = { 1024 },
         appState:  AppState? = nil,
         fallback:  AppleVisionFallbackProvider = AppleVisionFallbackProvider()) {
        self.baseURL   = baseURL
        self.modelName = modelName
        self.apiKey    = apiKey
        self.isEnabled = isEnabled
        self.maxWidth  = maxWidth
        self.appState  = appState
        self.fallback  = fallback
    }

    // MARK: - Availability

    func isAvailable() async -> Bool {
        guard isEnabled() else { return false }
        guard let key = apiKey(), !key.isEmpty else { return false }
        guard !modelName().trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return true
    }

    // MARK: - VisionProvider — intent-specific entry points

    func describeScene(image: CGImage) async -> VisionProviderResult {
        await run(image: image, mode: .describe, roi: nil)
    }

    func describePerson(image: CGImage) async -> VisionProviderResult {
        // Run Apple Vision locally to get a face crop — extra resolution for
        // glasses, hat, beard, earrings, skin tone.
        let roi = await extractROI(image: image)
        return await run(image: image, mode: .describePerson, roi: roi.faceCrop)
    }

    func describeDesk(image: CGImage) async -> VisionProviderResult {
        await run(image: image, mode: .describeDesk, roi: nil)
    }

    func extractText(image: CGImage) async -> VisionProviderResult {
        await run(image: image, mode: .readText, roi: nil)
    }

    func detectObjects(image: CGImage) async -> VisionProviderResult {
        await run(image: image, mode: .detectPeople, roi: nil)
    }

    func detectHeldObject(image: CGImage) async -> VisionProviderResult {
        // Run Apple Vision locally to get a hand crop — extra resolution for
        // identifying phones, mugs, remotes, controllers.
        let roi = await extractROI(image: image)
        return await run(image: image, mode: .detectHeldObject, roi: roi.handCrop)
    }

    // MARK: - ROI extraction (background queue, non-blocking)

    private func extractROI(image: CGImage) async -> ROIResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = VisionROIExtractor.extract(from: image)
                continuation.resume(returning: result)
            }
        }
    }

    // MARK: - Core request

    /// All public VisionProvider methods funnel here.
    ///
    /// - Parameters:
    ///   - image: Full-resolution source frame.
    ///   - mode:  Which analysis mode to run (determines system + user prompt).
    ///   - roi:   Optional locally-extracted crop (face or hand region).
    ///            When non-nil it is JPEG-encoded and appended as a second
    ///            image in the user message, giving the model a zoomed view.
    private func run(image: CGImage,
                     mode: VisionMode,
                     roi: CGImage?) async -> VisionProviderResult {
        let totalStart = Date()

        // ── Availability gate ──────────────────────────────────────────────
        let configuredModel = modelName().trimmingCharacters(in: .whitespaces)
        let provEnabled = isEnabled()
        log.info("[MiniMaxVision] configuredModel=\(configuredModel) providerEnabled=\(provEnabled)")
        guard isEnabled() else {
            return await earlyFallback(image: image, mode: mode, reason: "MiniMax vision not enabled")
        }
        guard let key = apiKey(), !key.isEmpty else {
            log.warning("[MiniMaxVision] failed status=token_missing")
            return await earlyFallback(image: image, mode: mode, reason: "MiniMax token is missing.")
        }
        let model = configuredModel
        guard !model.isEmpty else {
            log.warning("[MiniMaxVision] failed status=model_empty")
            return await earlyFallback(image: image, mode: mode, reason: "MiniMax vision model is not configured.")
        }
        guard let endpointURL = buildEndpoint() else {
            log.error("[MiniMaxVision] failed status=invalid_base_url")
            return await earlyFallback(image: image, mode: mode, reason: "Invalid MiniMax base URL")
        }

        // ── Encode primary frame ───────────────────────────────────────────
        let encodeStart = Date()
        guard let jpeg = encodeJPEG(image, maxWidth: maxWidth()) else {
            log.error("MiniMax vision: JPEG encode failed")
            return await earlyFallback(image: image, mode: mode, reason: "JPEG encode failed")
        }
        let encodeMs = Int(-encodeStart.timeIntervalSinceNow * 1000)
        let sizeKB   = jpeg.count / 1024
        let scaledW  = scaledWidth(original: image.width, original: image.height, maxSide: maxWidth())

        // Encode ROI crop (smaller, 512px max for bandwidth efficiency)
        let roiJpeg: Data? = roi.flatMap { encodeJPEG($0, maxWidth: 512) }

        log.debug("Vision encode: full=\(scaledW)px \(sizeKB)KB roi=\(roiJpeg != nil ? "yes" : "no") \(encodeMs)ms mode=\(String(describing: mode))")

        // ── Build prompts ──────────────────────────────────────────────────
        let (systemPrompt, userPrompt) = buildPrompts(mode: mode, hasROI: roiJpeg != nil)

        // ── Call MiniMax ───────────────────────────────────────────────────
        log.info("[MiniMaxVision] resolvedModel=\(model) endpoint=\(endpointURL.absoluteString)")
        let client = OpenAIChatClient(
            endpoint:            endpointURL,
            authorizationHeader: "Bearer \(key)",
            model:               model
        )

        log.info("[MiniMaxVision] requestStarted")
        let requestStart = Date()
        do {
            let (rawText, _) = try await client.completeWithVisionImages(
                systemPrompt:   systemPrompt,
                userPrompt:     userPrompt,
                contextSummary: nil,
                temperature:    0.25,
                maxTokens:      420,
                timeoutSeconds: 30,
                primaryImage:   jpeg,
                roiImage:       roiJpeg
            )
            let requestMs = Int(-requestStart.timeIntervalSinceNow * 1000)
            let totalMs   = Int(-totalStart.timeIntervalSinceNow * 1000)

            // ── Parse structured JSON (or fall back to plain text) ─────────
            let structured = VisionStructuredResponse.parse(from: rawText)
            let summary: String
            let entities: [String]
            let confidence: Float?

            if let s = structured {
                summary    = s.qualifiedSummary()
                entities   = s.detectedEntities
                confidence = s.confidenceScore
                log.info("[MiniMaxVision] success")
                log.info("""
                    MiniMax vision OK (JSON): model=\(model, privacy: .public) \
                    encode=\(encodeMs)ms request=\(requestMs)ms total=\(totalMs)ms \
                    sizeKB=\(sizeKB) entities=\(entities.count) conf=\(Int(s.confidenceScore * 100))%
                    """)
            } else {
                // Plain-text fallback — model didn't return valid JSON
                summary    = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                entities   = []
                confidence = nil
                log.info("""
                    MiniMax vision OK (plain): model=\(model, privacy: .public) \
                    encode=\(encodeMs)ms request=\(requestMs)ms total=\(totalMs)ms sizeKB=\(sizeKB)
                    """)
            }

            let result = VisionProviderResult(
                description:      summary,
                providerUsed:     providerName,
                modelUsed:        model,
                latencyMs:        totalMs,
                imageWidthPx:     scaledW,
                imageSizeKB:      sizeKB,
                error:            nil,
                timestamp:        Date(),
                detectedEntities: entities,
                confidenceScore:  confidence
            )
            await updateDiagnostics(result, encodeMs: encodeMs, requestMs: requestMs)
            return result

        } catch {
            let requestMs = Int(-requestStart.timeIntervalSinceNow * 1000)
            let totalMs   = Int(-totalStart.timeIntervalSinceNow * 1000)
            let reason = (error as? LLMError)?.errorDescription ?? error.localizedDescription
            log.warning("[MiniMaxVision] failed status=\(reason, privacy: .public) model=\(model) \(requestMs)ms")

            // HTTP 400 typically means an invalid/unknown model name. Return the exact
            // error rather than the Apple Vision fallback text (which says "Enable MiniMax
            // in Settings → AI" — misleading when MiniMax IS enabled but misconfigured).
            let isModelError = reason.contains("400")
                            || reason.localizedCaseInsensitiveContains("invalid")
                            || reason.localizedCaseInsensitiveContains("unknown model")

            if isModelError {
                log.info("[MiniMaxVision] success=false model_invalid=true returning error description")
                let diagResult = VisionProviderResult(
                    description:      "MiniMax vision model is invalid: \"\(model)\". Check Settings → AI → MiniMax model.",
                    providerUsed:     providerName,
                    modelUsed:        model,
                    latencyMs:        totalMs,
                    imageWidthPx:     scaledW,
                    imageSizeKB:      sizeKB,
                    error:            reason,
                    timestamp:        Date(),
                    detectedEntities: [],
                    confidenceScore:  nil
                )
                await updateDiagnostics(diagResult, encodeMs: encodeMs, requestMs: requestMs)
                return diagResult
            }

            // Other errors (network, timeout, etc.) — fall back to Apple Vision.
            let appleResult = await fallback.analyze(image: image, mode: mode)
            let diagResult = VisionProviderResult(
                description:      "MiniMax vision request failed: \(reason)",
                providerUsed:     "Apple Vision (fallback)",
                modelUsed:        nil,
                latencyMs:        totalMs,
                imageWidthPx:     scaledW,
                imageSizeKB:      sizeKB,
                error:            reason,
                timestamp:        Date(),
                detectedEntities: appleResult.detectedEntities,
                confidenceScore:  nil
            )
            await updateDiagnostics(diagResult, encodeMs: encodeMs, requestMs: requestMs)
            return diagResult
        }
    }

    // MARK: - Prompt construction

    /// Returns (systemPrompt, userPrompt) tailored to the analysis mode.
    ///
    /// All modes request a structured JSON response so entities and confidence
    /// can be extracted without fragile regex parsing.  The JSON schema is
    /// explicitly defined in the system prompt.
    private func buildPrompts(mode: VisionMode, hasROI: Bool) -> (system: String, user: String) {
        // Common JSON schema instruction appended to every system prompt.
        let jsonSchema = """

        IMPORTANT: Respond ONLY with a valid JSON object using this exact schema:
        {
          "summary": "<concise natural-language answer, 1-3 sentences>",
          "confidence_score": <float 0.0-1.0 representing your certainty>,
          "detected_entities": [<list of all notable visual elements as strings>],
          "visual_context": {
            "clothing": [<list of clothing items with exact colours and garment type>],
            "accessories": [<list of accessories: glasses, hat, jewellery, watch, etc.>],
            "held_objects": [<list of objects held in hands>],
            "ocr_text": [<list of visible text strings>]
          }
        }
        Do not include any text outside this JSON object.
        """

        switch mode {

        case .describe:
            let system = """
            You are Jarvis, a precision camera vision assistant.
            Describe what you see in the camera frame with high specificity.

            Cover all visible elements:
            - People: exact clothing colours and type, facial accessories (glasses frame style and colour, \
            hat, beard, jewellery), what they hold in each hand.
            - Objects, devices, and items.
            - Environment and background.

            Rules:
            - Be specific: "thick black rectangular glasses" not "glasses".
            - "dark grey zip-up hoodie" not "a shirt".
            - Mention ALL held objects — never omit items in hands.
            - NEVER identify or name any real person.
            - If uncertain about something, say so explicitly in your summary.
            \(jsonSchema)
            """
            let user = hasROI
                ? "Describe what you can see in these camera frames. The second image is a zoomed crop."
                : "What can you see in this camera frame?"
            return (system, user)

        case .describePerson:
            let system = """
            You are Jarvis, a precision camera vision assistant focused on person description.
            Describe the person visible in the camera frame in precise, specific detail.

            You MUST cover ALL of the following in order:
            1. FACE & ACCESSORIES: Glasses — describe the EXACT frame style (thick/thin, round/rectangular/\
            oval) and colour (black, tortoiseshell, silver, etc.). Hat style and colour. Beard or facial hair \
            (stubble, full beard, moustache). Visible jewellery (earrings, rings, necklace). Piercings.
               — If glasses are present, they MUST appear in your accessories list.
            2. CLOTHING: Each garment with EXACT colour and type — "dark charcoal zip-up hoodie", \
            "white crew-neck t-shirt", "blue denim jacket". Never say "a shirt" or "casual clothes".
            3. POSTURE & POSITION: Sitting or standing, facing direction, approximate distance.
            4. HANDS & HELD ITEMS: Describe anything visible in EITHER hand — phone (model if visible), \
            mug, remote, book, controller, pen, etc. If hands are empty, say so explicitly.
            5. ACTIVITY: What the person appears to be doing.

            \(hasROI ? "The second image is a zoomed crop of the face — use it to identify accessories more accurately." : "")

            Rules:
            - Be precise throughout. Low confidence = say so in summary.
            - NEVER identify, name, or infer the identity of any person.
            - NEVER infer sensitive attributes (age, health, ethnicity).
            \(jsonSchema)
            """
            let user = hasROI
                ? "Describe the person in detail. The second image shows a closer view of their face."
                : "Describe the person visible in this camera frame in detail."
            return (system, user)

        case .describeDesk:
            let system = """
            You are Jarvis, a precision camera vision assistant focused on desk and workspace analysis.
            Describe all visible objects on the desk or workspace.

            Be specific:
            - Name every device (laptop brand/colour, monitor count and size, keyboard type, mouse, \
            phone model, tablet, headphones, speakers).
            - Mention papers, notebooks, books, sticky notes.
            - Note food, drinks, and containers.
            - Describe spatial layout ("two monitors side by side", "keyboard centred in front").
            - Focus on what is physically present — not inferences about the owner.
            \(jsonSchema)
            """
            let user = "What objects and items can you see in this camera frame, particularly on the desk or workspace?"
            return (system, user)

        case .readText:
            let system = """
            You are Jarvis, a precise OCR camera vision assistant.
            Extract ALL readable text from the image exactly as it appears.

            Rules:
            - Preserve exact wording, capitalisation, and punctuation.
            - Organise by visual position (top, middle, bottom) if multiple blocks.
            - Include text on screens, labels, books, whiteboards, packaging — everything.
            - If no text is visible, say so in the summary.
            - Put ALL extracted text strings in the "ocr_text" array.
            \(jsonSchema)
            """
            let user = "Extract and list all readable text visible in this image."
            return (system, user)

        case .detectPeople:
            let system = """
            You are Jarvis, a precision camera vision assistant.
            Identify and count all people visible in the frame.
            Note notable objects, devices, and accessories for each person.
            Use 1–2 concise sentences.
            \(jsonSchema)
            """
            let user = "Who and what can you see in this camera frame?"
            return (system, user)

        case .detectHeldObject:
            let system = """
            You are Jarvis, a precision camera vision assistant specialising in handheld object detection.
            Your ONLY job is to identify what the person is holding in their hands.

            Instructions:
            1. IDENTIFY the primary held object precisely — use exact product names where visible:
               "iPhone 15 Pro", "Android smartphone", "TV remote", "coffee mug", "book", \
               "gaming controller", "pen", "AirPods case", "water bottle", "tablet".
            2. SPECIFY which hand(s) and orientation if visible (left hand, both hands, held to ear, etc.).
            3. LIST any secondary held items.

            \(hasROI ? "The second image is a zoomed crop of the person's hand region — use it to identify the object more accurately." : "")

            Response rules:
            - If the person is holding NOTHING: summary = "I don't see anything in their hands."
            - If no person is visible: summary = "No person is visible in the frame."
            - If uncertain: reduce confidence_score and say "I think" or "possibly" in summary.
            - Do NOT describe background or clothing unless it helps identify the object.
            - Be concise — summary must be 1–2 sentences maximum.
            - NEVER identify or name any real person.
            \(jsonSchema)
            """
            let user = hasROI
                ? "What is the person holding in their hands? The second image is a zoomed crop of the hand area."
                : "What is the person holding in their hands right now?"
            return (system, user)
        }
    }

    // MARK: - Early fallback helper

    private func earlyFallback(image: CGImage,
                               mode: VisionMode,
                               reason: String) async -> VisionProviderResult {
        let appleResult = await fallback.analyze(image: image, mode: mode)
        let result = VisionProviderResult(
            description:      appleResult.description,
            providerUsed:     "Apple Vision (fallback)",
            modelUsed:        nil,
            latencyMs:        appleResult.latencyMs,
            imageWidthPx:     appleResult.imageWidthPx,
            imageSizeKB:      appleResult.imageSizeKB,
            error:            reason,
            timestamp:        Date(),
            detectedEntities: [],
            confidenceScore:  nil
        )
        await updateDiagnostics(result, encodeMs: 0, requestMs: 0)
        return result
    }

    // MARK: - Diagnostics

    @MainActor
    private func updateDiagnostics(_ result: VisionProviderResult,
                                   encodeMs: Int, requestMs: Int) {
        guard let state = appState else { return }
        state.lastVisionProvider    = result.providerUsed
        state.lastVisionImageSizeKB = result.imageSizeKB
        state.lastVisionEncodeMs    = encodeMs
        state.lastVisionRequestMs   = requestMs
        state.lastVisionTotalMs     = result.latencyMs
        state.lastVisionError       = result.error
        state.visionIsLoading       = false
    }

    // MARK: - URL builder

    private func buildEndpoint() -> URL? {
        var base = baseURL().trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { return nil }
        let full = base.hasSuffix("/chat/completions") ? base : base + "/chat/completions"
        return URL(string: full)
    }

    // MARK: - Image encoding

    private func encodeJPEG(_ image: CGImage, maxWidth: Int) -> Data? {
        let (w, h) = scaledDimensions(width: image.width, height: image.height, maxSide: maxWidth)
        let target: CGImage
        if w < image.width || h < image.height {
            let space = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(data: nil, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let scaled = ctx.makeImage() else { return nil }
            target = scaled
        } else {
            target = image
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, target,
            [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    private func scaledDimensions(width: Int, height: Int, maxSide: Int) -> (Int, Int) {
        guard maxSide > 0, width > 0, height > 0 else { return (width, height) }
        let longest = max(width, height)
        guard longest > maxSide else { return (width, height) }
        let scale = Double(maxSide) / Double(longest)
        return (max(1, Int(Double(width) * scale)), max(1, Int(Double(height) * scale)))
    }

    private func scaledWidth(original w: Int, original h: Int, maxSide: Int) -> Int {
        scaledDimensions(width: w, height: h, maxSide: maxSide).0
    }
}
