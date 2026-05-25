import Foundation
import Observation
import os

// MARK: - PronunciationEntry

struct PronunciationEntry: Codable, Identifiable, Equatable {
    var id: UUID
    /// The text to match in the response (exact string, case-controlled by `caseSensitive`).
    var input: String
    /// What Jarvis will say instead.
    var output: String
    /// Temporarily disable without deleting.
    var enabled: Bool
    /// If false, matches "ai", "Ai", "AI" equally.
    var caseSensitive: Bool
    /// Built-in entries shipped with the app — shown with a lock icon in Settings.
    var isBuiltIn: Bool

    init(id: UUID = UUID(), input: String, output: String,
         enabled: Bool = true, caseSensitive: Bool = true, isBuiltIn: Bool = false) {
        self.id            = id
        self.input         = input
        self.output        = output
        self.enabled       = enabled
        self.caseSensitive = caseSensitive
        self.isBuiltIn     = isBuiltIn
    }
}

// MARK: - PronunciationDictionary

/// Persistent, user-editable pronunciation override table.
///
/// Built-in defaults are seeded at first launch and after a reset.
/// User-added entries and toggles persist to
/// `~/Library/Application Support/JarvisMac/pronunciation-dictionary.json`.
///
/// Apply order: longest match first, so "GPT-4o" beats "GPT-4".
@Observable
@MainActor
final class PronunciationDictionary {

    private(set) var entries: [PronunciationEntry] = []
    private let fileURL: URL
    private let log = Logger(subsystem: "com.jarvis", category: "pronunciation")

    // MARK: - Built-in defaults

    static let builtInDefaults: [(input: String, output: String, caseSensitive: Bool)] = [
        // ── Acronyms ──────────────────────────────────────────────────────────────
        ("AI",        "A.I.",            true),
        ("LLM",       "L.L.M.",          true),
        ("API",       "A.P.I.",          true),
        ("GPU",       "G.P.U.",          true),
        ("CPU",       "C.P.U.",          true),
        ("TTS",       "T.T.S.",          true),
        ("STT",       "S.T.T.",          true),
        ("SSH",       "S.S.H.",          true),
        ("OBS",       "O.B.S.",          true),
        ("URL",       "U.R.L.",          true),
        ("UI",        "U.I.",            true),
        ("UX",        "U.X.",            true),
        ("SDK",       "S.D.K.",          true),
        ("IDE",       "I.D.E.",          true),
        ("CI",        "C.I.",            true),
        ("PR",        "P.R.",            true),
        ("UUID",      "U.U.I.D.",        true),
        ("JSON",      "jason",           true),
        ("YAML",      "yam-el",          true),
        ("SQL",       "sequel",          true),
        ("HTML",      "H.T.M.L.",        true),
        ("CSS",       "C.S.S.",          true),
        ("CLI",       "C.L.I.",          true),
        ("DNS",       "D.N.S.",          true),
        ("VPN",       "V.P.N.",          true),
        ("RAM",       "ram",             true),
        ("SSD",       "S.S.D.",          true),
        ("ONNX",      "O.N.N.X.",        true),
        ("GGUF",      "G.G.U.F.",        true),
        ("LLMs",      "L.L.M.s",        true),
        ("APIs",      "A.P.I.s",        true),
        // ── Brands / Products ────────────────────────────────────────────────────
        ("MiniMax",   "Mini Max",        true),
        ("llama.cpp", "llama dot C P P", true),
        ("ChatGPT",   "Chat G.P.T.",     true),
        ("GPT-4o",    "G.P.T. Four Oh",  true),
        ("GPT-4",     "G.P.T. Four",     true),
        ("GPT-3",     "G.P.T. Three",    true),
        ("iOS",       "i O S",           true),
        ("macOS",     "mac O S",         true),
        ("SwiftUI",   "Swift U.I.",      true),
        ("GitHub",    "Git Hub",         true),
        ("GitLab",    "Git Lab",         true),
        ("Tailscale", "Tail Scale",      true),
        ("HomeKit",   "Home Kit",        true),
        ("Obsidian",  "Obsidian",        true),
        ("Ollama",    "Oh-lama",          true),
        ("Whisper",   "Whisper",         true),   // prevent W.H.I.S.P.E.R. from auto-expander
        ("Piper",     "Piper",           true),
    ]

    // MARK: - Init

    init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("JarvisMac", isDirectory: true)
        fileURL = dir.appendingPathComponent("pronunciation-dictionary.json")
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        load()
    }

    // MARK: - Apply

    /// Replace all matching input phrases in `text` with their outputs.
    /// Processes longest entries first to prevent shorter matches from
    /// preempting longer ones (e.g. "GPT-4" before "GPT-4o").
    func apply(to text: String, replacements: inout [(String, String)]) -> String {
        var t = text
        let active = entries
            .filter { $0.enabled }
            .sorted { $0.input.count > $1.input.count }

        for entry in active {
            let opts: String.CompareOptions = entry.caseSensitive ? [] : .caseInsensitive
            guard t.range(of: entry.input, options: opts) != nil else { continue }
            t = t.replacingOccurrences(of: entry.input, with: entry.output, options: opts)
            replacements.append((entry.input, entry.output))
        }
        return t
    }

    // MARK: - CRUD

    func add(input: String, output: String, caseSensitive: Bool = true) {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        entries.append(PronunciationEntry(
            input: trimmed, output: output.trimmingCharacters(in: .whitespaces),
            caseSensitive: caseSensitive))
        save()
    }

    func update(_ entry: PronunciationEntry) {
        guard let idx = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[idx] = entry
        save()
    }

    func delete(_ entry: PronunciationEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func resetToDefaults() {
        entries.removeAll { $0.isBuiltIn }
        seedDefaults()
        save()
        log.info("Pronunciation dictionary reset to defaults")
    }

    // MARK: - Persistence

    private func load() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([PronunciationEntry].self, from: data) {
            entries = decoded
            log.debug("Loaded \(decoded.count) pronunciation entries from disk")
        }
        seedDefaults()
    }

    /// Adds any built-in entries that are not yet present, preserving user entries
    /// at the end of the list and built-ins at the front.
    private func seedDefaults() {
        for def in Self.builtInDefaults.reversed() {
            guard !entries.contains(where: { $0.input == def.input && $0.isBuiltIn }) else {
                continue
            }
            entries.insert(
                PronunciationEntry(input: def.input, output: def.output,
                                   enabled: true, caseSensitive: def.caseSensitive,
                                   isBuiltIn: true),
                at: 0)
        }
    }

    func save() {
        let snapshot = entries
        let dest = fileURL
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: dest, options: .atomic)
        }
    }
}
