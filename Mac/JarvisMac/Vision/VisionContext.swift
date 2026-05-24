import Foundation

// MARK: - VisionContext

/// Short-lived structured record of what the vision pipeline observed.
///
/// Survives for `ttlSeconds` (default 60) after analysis. Injected into
/// `tryLLMFallback` context so conversational follow-ups ("what colour is it?",
/// "what does the label say?", "is it an Android or iPhone?") can refer to the
/// last visual observation without triggering another camera capture.
///
/// Not persisted — it is an in-memory working context only.
struct VisionContext {

    // MARK: Content

    let summary:         String        // human-readable description for TTS
    let mode:            VisionMode    // which analysis mode produced this
    let frameID:         UUID          // unique ID per captured frame
    let frameTimestamp:  Date          // when the physical frame was captured
    let analysisTimestamp: Date        // when analysis completed

    // Structured entity lists (empty if provider couldn't extract them)
    let detectedEntities: [String]     // all notable visual observations
    let clothingItems:    [String]     // ["dark grey zip-up hoodie", "white t-shirt"]
    let accessories:      [String]     // ["black thick-framed glasses", "baseball cap"]
    let heldObjects:      [String]     // ["iPhone", "coffee mug"]
    let ocrText:          [String]     // raw OCR lines

    // Confidence (nil = not available from this provider)
    let confidenceScore: Float?

    // Which provider answered
    let providerUsed: String

    // MARK: TTL

    static let ttlSeconds: TimeInterval = 60

    var isFresh: Bool {
        analysisTimestamp.timeIntervalSinceNow > -Self.ttlSeconds
    }

    var ageSeconds: Int {
        Int(-analysisTimestamp.timeIntervalSinceNow)
    }

    // MARK: LLM injection

    /// Returns a compact block for injection into the LLM context window.
    /// Only called when `isFresh` is true.
    func toLLMContextString() -> String {
        var lines: [String] = []
        lines.append("[VISION CONTEXT — \(Int(-analysisTimestamp.timeIntervalSinceNow))s ago]")
        lines.append("Description: \(summary)")

        if !accessories.isEmpty {
            lines.append("Accessories: \(accessories.joined(separator: ", "))")
        }
        if !clothingItems.isEmpty {
            lines.append("Clothing: \(clothingItems.joined(separator: ", "))")
        }
        if !heldObjects.isEmpty {
            lines.append("Held objects: \(heldObjects.joined(separator: ", "))")
        }
        if !ocrText.isEmpty {
            lines.append("Visible text: \(ocrText.prefix(5).joined(separator: " / "))")
        }
        if let c = confidenceScore {
            lines.append("Confidence: \(Int(c * 100))%")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Empty sentinel

    static let empty = VisionContext(
        summary: "",
        mode: .describe,
        frameID: UUID(),
        frameTimestamp: .distantPast,
        analysisTimestamp: .distantPast,
        detectedEntities: [],
        clothingItems: [],
        accessories: [],
        heldObjects: [],
        ocrText: [],
        confidenceScore: nil,
        providerUsed: ""
    )
}

// MARK: - VisionStructuredResponse

/// Internal model for parsing the structured JSON the vision provider returns.
/// Not exposed to callers — converted to `VisionContext` by the analysis pipeline.
struct VisionStructuredResponse {
    let summary:         String
    let confidenceScore: Float         // 0.0–1.0
    let detectedEntities: [String]
    let clothing:        [String]
    let accessories:     [String]
    let heldObjects:     [String]
    let rawText:         [String]      // OCR

    // MARK: JSON parsing

    /// Attempt to parse a JSON blob returned by the LLM.
    /// Returns nil on parse failure — caller falls back to treating the response as plain text.
    static func parse(from jsonString: String) -> VisionStructuredResponse? {
        guard let data = jsonString.data(using: .utf8),
              let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let summary    = obj["summary"] as? String ?? ""
        let confidence = (obj["confidence_score"] as? Double).map(Float.init) ?? 0.5
        let entities   = obj["detected_entities"] as? [String] ?? []

        let visual     = obj["visual_context"] as? [String: Any] ?? [:]
        let clothing   = visual["clothing"]     as? [String] ?? []
        let access     = visual["accessories"]  as? [String] ?? []
        let held       = visual["held_objects"] as? [String] ?? []
        let ocr        = visual["ocr_text"]     as? [String] ?? []

        guard !summary.isEmpty else { return nil }

        return VisionStructuredResponse(
            summary:          summary,
            confidenceScore:  max(0, min(1, confidence)),
            detectedEntities: entities,
            clothing:         clothing,
            accessories:      access,
            heldObjects:      held,
            rawText:          ocr
        )
    }

    // MARK: Uncertainty qualifier

    /// Prepends a hedge if confidence is low enough that we shouldn't assert.
    func qualifiedSummary(uncertaintyThreshold: Float = 0.40) -> String {
        if confidenceScore < uncertaintyThreshold && !summary.isEmpty {
            return "I'm not entirely sure, but — \(summary)"
        }
        return summary
    }
}
