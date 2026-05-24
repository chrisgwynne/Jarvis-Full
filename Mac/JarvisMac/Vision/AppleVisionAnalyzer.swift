import Foundation
import CoreGraphics
import Vision

/// Real Phase-2 vision analyzer driven by Apple's Vision framework.
/// Everything runs on-device, off the main thread.
///
/// - `describe`     → recognized text + person/face count summary
/// - `readText`     → OCR-only, returns all recognized strings
/// - `detectPeople` → face + body detection
///
/// We deliberately keep this lean — object classification via `VNClassifyImage`
/// adds licensing/footprint cost. Once the user wants richer scene
/// understanding we'll add a CoreML model behind the same interface.
final class AppleVisionAnalyzer: VisionAnalyzing {

    func analyze(_ frame: CGImage, mode: VisionMode) async throws -> VisionResult {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<VisionResult, Error>) in
            let queue = DispatchQueue.global(qos: .userInitiated)
            queue.async {
                do {
                    let result = try Self.runRequests(frame: frame, mode: mode)
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private static func runRequests(frame: CGImage, mode: VisionMode) throws -> VisionResult {
        let handler = VNImageRequestHandler(cgImage: frame, options: [:])
        var requests: [VNRequest] = []

        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true

        let faceRequest = VNDetectFaceRectanglesRequest()
        let bodyRequest = VNDetectHumanRectanglesRequest()

        switch mode {
        case .describe, .describePerson, .describeDesk:
            requests = [textRequest, faceRequest, bodyRequest]
        case .readText:
            requests = [textRequest]
        case .detectPeople, .detectHeldObject:
            requests = [faceRequest, bodyRequest]
        }

        try handler.perform(requests)

        let recognized: [String] = (textRequest.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let faces = faceRequest.results?.count ?? 0
        let bodies = bodyRequest.results?.count ?? 0
        let peopleCount = max(faces, bodies)

        let summary: String
        switch mode {
        case .describe:
            summary = describeSentence(text: recognized, peopleCount: peopleCount)
        case .describePerson:
            switch peopleCount {
            case 0: summary = "I can't see anyone in frame."
            case 1: summary = "There's one person visible, but I can't make out the details without a vision model."
            default: summary = "I can see \(peopleCount) people, but I can't describe them in detail without a vision model."
            }
        case .describeDesk:
            if !recognized.isEmpty {
                let snippet = recognized.prefix(5).joined(separator: ", ")
                summary = "I can see some text: \(snippet). For a full description of objects, enable the vision model in Settings."
            } else if peopleCount > 0 {
                summary = "I can see \(peopleCount == 1 ? "a person" : "\(peopleCount) people") and possibly a desk, but I can't describe objects in detail without a vision model."
            } else {
                summary = "I can see the area, but I need the vision model enabled to describe what's on your desk."
            }
        case .readText:
            if recognized.isEmpty {
                summary = "I don't see any text."
            } else {
                summary = "I see: " + recognized.prefix(8).joined(separator: " · ")
            }
        case .detectPeople:
            switch peopleCount {
            case 0: summary = "No one's in frame."
            case 1: summary = "I can see one person."
            default: summary = "I can see \(peopleCount) people."
            }
        case .detectHeldObject:
            if peopleCount == 0 {
                summary = "No person is visible in the frame."
            } else {
                summary = "I can see a person, but on-device analysis can't identify held objects. Enable cloud vision in Settings for accurate hand detection."
            }
        }

        return VisionResult(summary: summary,
                            recognizedText: recognized,
                            labels: [],
                            faceCount: peopleCount,
                            timestamp: Date())
    }

    /// Produces an honest summary of what on-device Vision detected.
    ///
    /// Deliberately mentions the AI vision model so the user knows this is
    /// basic structural detection rather than rich LLM understanding — and
    /// understands what to enable to get the full description.
    private static func describeSentence(text: [String], peopleCount: Int) -> String {
        var parts: [String] = []
        switch peopleCount {
        case 0:   break
        case 1:   parts.append("one person in frame")
        default:  parts.append("\(peopleCount) people in frame")
        }
        if !text.isEmpty {
            let snippet = text.prefix(3).joined(separator: ", ")
            parts.append("some text visible: \(snippet)")
        }

        if parts.isEmpty {
            return "I can see the camera view, but the AI vision model isn't enabled — enable MiniMax in Settings → AI for a full description."
        }
        let detected = parts.joined(separator: " and ")
        return "On-device detection shows \(detected). Enable MiniMax in Settings → AI for a full AI description."
    }
}
