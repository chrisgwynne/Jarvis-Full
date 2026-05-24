import Foundation

/// Loads optional soul / persona / identity files from the user's Application
/// Support directory and exposes a live `Identity` value used by
/// `FastResponseRouter`, `PersonalFactsResolver`, and the LLM context builder.
///
/// Supported files (checked in priority order):
///   ~/Library/Application Support/JarvisMac/soul/identity.json
///   ~/Library/Application Support/JarvisMac/soul/persona.md
///   ~/Library/Application Support/JarvisMac/soul/soul.txt
///
/// All files are optional — sensible defaults are used when absent.
/// Files can be edited at any time; call `reload()` (or say "reload personality")
/// to pick up changes without restarting Jarvis.
final class AssistantIdentityService {

    // MARK: - Public identity snapshot

    struct Identity {
        var name: String = "Jarvis"
        var descriptionText: String = "a local-first Mac voice assistant"
        var personalitySummary: String = ""
        var creatorName: String = ""
        var values: [String] = []
        var limitations: [String] = []
        var version: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"

        /// Spoken answer for "who are you" with optional user name greeting.
        func spokenIntroduction(userName: String) -> String {
            var parts: [String] = []
            parts.append("I'm \(name), \(descriptionText).")
            if !personalitySummary.isEmpty {
                parts.append(personalitySummary)
            }
            if !creatorName.isEmpty {
                parts.append("I was created by \(creatorName).")
            }
            if !userName.isEmpty {
                parts.append("Good to talk to you, \(userName).")
            }
            return parts.joined(separator: " ")
        }

        /// Compact one-liner for LLM context.
        func contextLine() -> String {
            var line = "Assistant: \(name) — \(descriptionText)"
            if !creatorName.isEmpty { line += ", created by \(creatorName)" }
            if !personalitySummary.isEmpty { line += ". \(personalitySummary)" }
            return line
        }
    }

    // MARK: - State

    private let soulDirectory: URL
    private(set) var identity = Identity()
    private(set) var loadedFrom: String = "defaults"
    private(set) var lastLoadedAt: Date?

    // MARK: - Init

    init() {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false)
        ) ?? FileManager.default.temporaryDirectory
        soulDirectory = base.appendingPathComponent("JarvisMac/soul", isDirectory: true)
        load()
    }

    // MARK: - Public API

    func reload() {
        identity = Identity()
        loadedFrom = "defaults"
        load()
        Log.app.info("identity reloaded source=\(self.loadedFrom)")
    }

    /// Creates the soul directory with an example `identity.json` so users
    /// know the format without reading documentation.
    func ensureDirectoryExists() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: soulDirectory.path) else { return }
        try? fm.createDirectory(at: soulDirectory, withIntermediateDirectories: true)

        let exampleJSON = """
        {
          "name": "Jarvis",
          "description": "a local-first Mac voice assistant",
          "personality": "Professional and efficient, with a touch of wit.",
          "creator": "Chris",
          "values": ["local-first", "privacy", "speed"],
          "limitations": ["Mac only", "No email or calendar write access"]
        }
        """
        let exampleURL = soulDirectory.appendingPathComponent("identity.json.example")
        try? exampleJSON.write(to: exampleURL, atomically: true, encoding: .utf8)

        let personaTemplate = """
        # Jarvis

        A local-first Mac assistant built by Chris.

        ## Personality
        Professional and efficient, with a touch of wit.

        ## Values
        - Local-first
        - Privacy
        - Speed over polish

        ## Limitations
        - Mac only
        - No email or calendar write access
        """
        let personaURL = soulDirectory.appendingPathComponent("persona.md.example")
        try? personaTemplate.write(to: personaURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Private loaders

    private func load() {
        // Priority 1: identity.json
        let jsonURL = soulDirectory.appendingPathComponent("identity.json")
        if let data = try? Data(contentsOf: jsonURL),
           let decoded = try? JSONDecoder().decode(IdentityJSON.self, from: data) {
            applyJSON(decoded)
            loadedFrom = "identity.json"
            lastLoadedAt = Date()
            return
        }

        // Priority 2: persona.md
        let mdURL = soulDirectory.appendingPathComponent("persona.md")
        if let text = try? String(contentsOf: mdURL, encoding: .utf8), !text.isEmpty {
            parseMarkdown(text)
            loadedFrom = "persona.md"
            lastLoadedAt = Date()
            return
        }

        // Priority 3: soul.txt (free-form, stuffed into personalitySummary)
        let txtURL = soulDirectory.appendingPathComponent("soul.txt")
        if let text = try? String(contentsOf: txtURL, encoding: .utf8), !text.isEmpty {
            identity.personalitySummary = String(text.prefix(500))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            loadedFrom = "soul.txt"
            lastLoadedAt = Date()
            return
        }
        // No file found — defaults remain.
    }

    private func applyJSON(_ j: IdentityJSON) {
        if let v = j.name        { identity.name = v }
        if let v = j.description { identity.descriptionText = v }
        if let v = j.personality { identity.personalitySummary = v }
        if let v = j.creator     { identity.creatorName = v }
        if let v = j.values      { identity.values = v }
        if let v = j.limitations { identity.limitations = v }
    }

    private func parseMarkdown(_ text: String) {
        var currentSection: String? = nil
        var sections: [String: [String]] = [:]

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("# ") {
                // Top-level heading → assistant name
                identity.name = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("## ") {
                currentSection = String(line.dropFirst(3))
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
            } else if let key = currentSection, !line.isEmpty {
                let content = line.hasPrefix("- ") ? String(line.dropFirst(2)) : line
                sections[key, default: []].append(content)
            }
        }

        if let v = sections["description"]?.first { identity.descriptionText = v }
        if let v = sections["personality"]?.first  { identity.personalitySummary = v }
        if let v = sections["creator"]?.first      { identity.creatorName = v }
        if let v = sections["values"]              { identity.values = v }
        if let v = sections["limitations"]         { identity.limitations = v }
    }

    // MARK: - Codable

    private struct IdentityJSON: Codable {
        var name: String?
        var description: String?
        var personality: String?
        var creator: String?
        var values: [String]?
        var limitations: [String]?
    }
}
