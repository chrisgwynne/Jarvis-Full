import Foundation

/// Heuristic camera scene → natural-language description.
/// Uses Vision results (OCR text, people count) — no network calls.
struct CameraSceneAnalyzer {

    func analyze(visionSummary: String, ocrLines: [String], peopleCount: Int, motionDelta: Double) -> String {
        var parts: [String] = []

        // Presence
        switch peopleCount {
        case 0:  break
        case 1:  parts.append("One person is in frame.")
        default: parts.append("\(peopleCount) people are in frame.")
        }

        // Motion hint
        if motionDelta > 0.08 {
            parts.append("Movement detected.")
        }

        // OCR content hints
        if !ocrLines.isEmpty {
            let snippet = ocrLines.prefix(3).joined(separator: ", ")
            if ocrLines.count == 1 {
                parts.append("Text visible: \(snippet).")
            } else {
                parts.append("Text visible including: \(snippet)\(ocrLines.count > 3 ? ", and more" : "").")
            }
        }

        // Workspace clues from OCR
        let allText = ocrLines.joined(separator: " ").lowercased()
        if allText.contains("keyboard") || allText.contains("monitor") || allText.contains("mouse") {
            parts.append("Workspace with computer equipment visible.")
        } else if allText.contains("label") || allText.contains("package") || allText.contains("box") {
            parts.append("Package or label visible.")
        } else if allText.contains("book") || allText.contains("page") || allText.contains("chapter") {
            parts.append("Reading material in view.")
        }

        // Fallback from the vision model summary
        if parts.isEmpty {
            return visionSummary.isEmpty
                ? "Camera sees the room. No notable features detected."
                : visionSummary
        }

        return parts.joined(separator: " ")
    }

    func ocrSummary(from lines: [String]) -> String {
        if lines.isEmpty { return "No text detected." }
        if lines.count <= 3 { return lines.joined(separator: " · ") }
        return lines.prefix(5).joined(separator: " · ") + " …(\(lines.count) lines)"
    }
}
