import Foundation

/// Assembles all personality files into a single context string
/// suitable for injection into an LLM system prompt.
///
/// Output format:
/// ```
/// [identity]
/// ...
///
/// [soul]
/// ...
/// ```
@MainActor
struct PersonalityContextBuilder {
    let store: PersonalityFileStore

    func buildContext() -> String {
        PersonalityPack.files
            .map { file in
                let content = store.content(for: file)
                return "[\(file.id.replacingOccurrences(of: "_", with: " "))]\n\(content)"
            }
            .joined(separator: "\n\n---\n\n")
    }

    /// Returns the full system-prompt block:
    /// a structured preamble (name, address style, communication style) followed
    /// by the core personality files (identity, soul, behaviour, examples).
    func buildSystemPrompt() -> String {
        buildSystemPrompt(userName: nil, assistantName: nil)
    }

    /// Overload that accepts identity strings from the controller so the
    /// prompt is never stale when PreferencesStore has been updated.
    func buildSystemPrompt(userName: String?, assistantName: String?) -> String {
        // ── Structured preamble ──────────────────────────────────────────────
        var preambleLines: [String] = []

        let resolvedAssistantName = assistantName?.nilIfEmpty ?? "Jarvis"
        preambleLines.append("You are \(resolvedAssistantName), a voice assistant running on macOS.")
        preambleLines.append("Your name is \(resolvedAssistantName).")

        // Address style
        let addressStyle = store.addressStyle.lowercased()
        let resolvedName = userName?.nilIfEmpty ?? store.preferredName.nilIfEmpty
        switch addressStyle {
        case "sir":
            preambleLines.append("Address the user as \"sir\" when greeting them.")
        case "name":
            if let name = resolvedName {
                preambleLines.append("Address the user as \"\(name)\" when greeting them.")
            }
        case "ma'am", "madam":
            preambleLines.append("Address the user as \"\(addressStyle)\" when greeting them.")
        default:
            break  // "none" — no honorific
        }

        // Communication style from user_preferences.md
        let tone = store.parsePublicValue("Tone") ?? "calm"
        let humourLevel = store.parsePublicValue("Humour level") ?? "low"
        let verbosity = store.verbosity

        let formalityDesc: String
        switch tone.lowercased() {
        case "formal":  formalityDesc = "formal"
        case "casual":  formalityDesc = "casual"
        default:        formalityDesc = "calm and direct"
        }
        preambleLines.append("Communication style: \(formalityDesc), humour level: \(humourLevel), verbosity: \(verbosity).")
        preambleLines.append("Always be concise — responses should be speakable in under 20 seconds.")

        let preamble = preambleLines.joined(separator: "\n")

        // ── Core personality files ───────────────────────────────────────────
        let coreIDs: Set<String> = ["identity", "soul", "behaviour", "examples"]
        let fileSections = PersonalityPack.files
            .filter { coreIDs.contains($0.id) }
            .map { file in
                let content = store.content(for: file)
                return "[\(file.id)]\n\(content)"
            }
            .joined(separator: "\n\n---\n\n")

        return [preamble, fileSections]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
