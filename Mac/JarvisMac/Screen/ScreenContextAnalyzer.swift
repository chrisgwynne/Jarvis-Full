import Foundation

/// Heuristic app + OCR text → richer natural-language summary.
/// No network calls — pure string logic.
struct ScreenContextAnalyzer {

    func analyze(app: String, windowTitle: String, textLines: [String]) -> String {
        var parts: [String] = []
        let low = app.lowercased()

        if !app.isEmpty {
            let titlePart = windowTitle.isEmpty ? "" : " — \"\(windowTitle)\""
            parts.append("You're using \(app)\(titlePart).")
        }

        // App-specific hints
        if low.contains("xcode") {
            if let file = textLines.first(where: { $0.contains(".swift") || $0.contains(".m") || $0.contains(".h") }) {
                parts.append("Editing \(file.trimmingCharacters(in: .whitespaces)).")
            }
        } else if low.contains("terminal") || low.contains("iterm") || low.contains("warp") {
            if let cmd = textLines.first(where: { $0.hasPrefix("$") || $0.hasPrefix("%") || $0.hasPrefix(">") }) {
                parts.append("Terminal: \(cmd.trimmingCharacters(in: .whitespaces).prefix(80)).")
            }
        } else if low.contains("safari") || low.contains("chrome") || low.contains("firefox") || low.contains("arc") {
            if !windowTitle.isEmpty { parts.append("Browsing: \(windowTitle).") }
        } else if low.contains("slack") || low.contains("messages") || low.contains("teams") {
            parts.append("Looks like a messaging context.")
        } else if low.contains("mail") || low.contains("outlook") {
            parts.append("Looks like an email context.")
        } else if low.contains("notes") || low.contains("notion") || low.contains("obsidian") || low.contains("bear") {
            parts.append("Looks like a notes or writing context.")
        } else if low.contains("figma") || low.contains("sketch") || low.contains("canva") {
            parts.append("Looks like a design tool.")
        }

        // Text summary
        if textLines.isEmpty {
            parts.append("No readable text on screen.")
        } else if textLines.count <= 3 {
            parts.append("Text visible: \(textLines.joined(separator: " · ")).")
        } else {
            let preview = textLines.prefix(3).joined(separator: ", ")
            parts.append("I can see \(textLines.count) lines of text. First few: \(preview).")
        }

        return parts.joined(separator: " ")
    }

    func ocrSummary(from lines: [String]) -> String {
        if lines.isEmpty { return "No text detected." }
        if lines.count <= 3 { return lines.joined(separator: " · ") }
        return lines.prefix(5).joined(separator: " · ") + " …(\(lines.count) lines)"
    }
}
