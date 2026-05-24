import Foundation
import AppKit
import Observation

/// Loads, saves, and watches the local personality markdown files.
/// Each file lives at `Application Support/JarvisMac/Personality/<filename>`.
/// Missing or corrupted files fall back to built-in defaults.
@Observable
@MainActor
final class PersonalityFileStore {

    private(set) var contents: [String: String] = [:]   // file.id → markdown text
    private(set) var loadErrors: [String: String] = [:] // file.id → error message

    let folderURL: URL

    private var directoryWatchSource: DispatchSourceFileSystemObject?
    private var reloadDebounceTask: Task<Void, Never>?

    init() {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true))
            ?? fm.temporaryDirectory
        folderURL = base
            .appendingPathComponent("JarvisMac", isDirectory: true)
            .appendingPathComponent("Personality", isDirectory: true)

        try? fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
        createDefaultFilesIfNeeded()
        loadAll()
        startDirectoryWatch()
    }

    nonisolated func cancelWatch() {
        Task { @MainActor in directoryWatchSource?.cancel() }
    }

    deinit {
        cancelWatch()
    }

    // MARK: - Access

    func content(for file: PersonalityFile) -> String {
        contents[file.id] ?? file.defaultContent
    }

    // MARK: - Parsed user preferences

    var preferredName: String { parseValue("Name") ?? "" }
    var addressStyle: String  { parseValue("Address style") ?? "none" }

    var verbosity: String { parseValue("Verbosity") ?? "normal" }

    var responseStyle: ResponseStyle {
        switch verbosity.lowercased() {
        case "concise":  return .minimal
        case "detailed": return .varied
        default:         return .consistent
        }
    }

    // MARK: - Mutations

    func save(file: PersonalityFile, content: String) {
        let url = fileURL(for: file)
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            contents[file.id] = content
            loadErrors[file.id] = nil
        } catch {
            loadErrors[file.id] = error.localizedDescription
        }
    }

    func reset(file: PersonalityFile) {
        save(file: file, content: file.defaultContent)
    }

    func resetAll() {
        for file in PersonalityPack.files {
            reset(file: file)
        }
    }

    func reload() {
        loadAll()
    }

    func openFolder() {
        NSWorkspace.shared.open(folderURL)
    }

    // MARK: - File path

    func fileURL(for file: PersonalityFile) -> URL {
        folderURL.appendingPathComponent(file.filename)
    }

    // MARK: - Private helpers

    private func createDefaultFilesIfNeeded() {
        let fm = FileManager.default
        for file in PersonalityPack.files {
            let url = fileURL(for: file)
            guard !fm.fileExists(atPath: url.path) else { continue }
            try? file.defaultContent.write(to: url, atomically: true, encoding: .utf8)
        }
        migrateAddressStyle()
    }

    /// One-time migration: removes the old forced "sir" default from user_preferences.md.
    /// Only touches the file if the address style line is exactly `**Address style:** sir`
    /// AND the user has not otherwise customised that line (still matches factory wording).
    private func migrateAddressStyle() {
        guard let file = PersonalityPack.files.first(where: { $0.id == "user_preferences" }) else { return }
        let url = fileURL(for: file)
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              text.contains("**Address style:** sir") else { return }
        let migrated = text.replacingOccurrences(of: "**Address style:** sir",
                                                  with: "**Address style:** none")
        try? migrated.write(to: url, atomically: true, encoding: .utf8)
    }

    private func loadAll() {
        for file in PersonalityPack.files {
            loadFile(file)
        }
    }

    private func loadFile(_ file: PersonalityFile) {
        let url = fileURL(for: file)
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            contents[file.id] = text
            loadErrors[file.id] = nil
        } catch {
            // File missing or unreadable — use default and recreate
            contents[file.id] = file.defaultContent
            loadErrors[file.id] = error.localizedDescription
            try? file.defaultContent.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Directory watching

    private func startDirectoryWatch() {
        let fd = Darwin.open(folderURL.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleReload()
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        directoryWatchSource = source
    }

    private func scheduleReload() {
        reloadDebounceTask?.cancel()
        reloadDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.loadAll()
        }
    }

    // MARK: - user_preferences.md parser

    /// Extracts `**Key:** value` entries from user_preferences.md.
    /// Public so `PersonalityContextBuilder` can read arbitrary keys.
    func parsePublicValue(_ key: String) -> String? { parseValue(key) }

    private func parseValue(_ key: String) -> String? {
        guard let text = contents["user_preferences"] else { return nil }
        for line in text.components(separatedBy: .newlines) {
            let prefix = "**\(key):**"
            if line.contains(prefix) {
                let rest = line.components(separatedBy: prefix).last ?? ""
                let value = rest.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty && value != "(not set)" {
                    return value
                }
            }
        }
        return nil
    }
}
