import Foundation
import Observation

/// Observable store for response templates.
/// Persists user overrides and style preference to
/// `Application Support/JarvisMac/response_playbook.json`.
/// Built-in defaults always live in `ResponsePlaybook.defaults`.
@Observable
@MainActor
final class ResponseTemplateStore {

    var style: ResponseStyle = .consistent
    private(set) var overrides: [String: [String]] = [:]

    private let fileURL: URL

    init() {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true))
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("JarvisMac", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("response_playbook.json")
        load()
    }

    // MARK: - Query

    func phrases(for key: String) -> [String] {
        if let custom = overrides[key], !custom.isEmpty { return custom }
        return ResponsePlaybook.defaults[key] ?? []
    }

    func isCustomised(_ key: String) -> Bool {
        overrides[key] != nil
    }

    var allKeys: [String] {
        ResponsePlaybook.defaults.keys.sorted()
    }

    // MARK: - Mutations

    func setStyle(_ newStyle: ResponseStyle) {
        style = newStyle
        save()
    }

    func update(key: String, phrases: [String]) {
        let cleaned = phrases.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if cleaned.isEmpty || cleaned == ResponsePlaybook.defaults[key] {
            overrides[key] = nil
        } else {
            overrides[key] = cleaned
        }
        save()
    }

    func reset(key: String) {
        overrides[key] = nil
        save()
    }

    func resetAll() {
        overrides = [:]
        save()
    }

    // MARK: - Import / Export

    func exportData() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(PlaybookFile(style: style, overrides: overrides))
    }

    func importData(_ data: Data) throws {
        let payload = try JSONDecoder().decode(PlaybookFile.self, from: data)
        style = payload.style
        overrides = payload.overrides
        save()
    }

    // MARK: - Persistence

    func save() {
        let payload = PlaybookFile(style: style, overrides: overrides)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: fileURL, options: [.atomic])
        Log.app.debug("response playbook saved")
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(PlaybookFile.self, from: data) else { return }
        style = payload.style
        overrides = payload.overrides
        Log.app.debug("response playbook loaded (\(payload.overrides.count) overrides)")
    }
}

// MARK: - Wire format

private struct PlaybookFile: Codable {
    var style: ResponseStyle
    var overrides: [String: [String]]
}
