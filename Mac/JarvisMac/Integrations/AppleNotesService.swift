import Foundation

// MARK: - AppleNote model

struct AppleNote: Identifiable {
    let id: String       // note name / title used as stable ID
    let title: String
    let body: String
    let modifiedAt: Date?
}

// MARK: - AppleNotesService

/// AppleScript-backed interface for Apple Notes.
///
/// All methods throw `AppleNotesService.NotesError` when scripting is
/// unavailable or returns an error. Callers should catch and speak a
/// setup guidance response in that case.
enum AppleNotesService {

    enum NotesError: Error, LocalizedError {
        case scriptingUnavailable(String)
        case notFound(String)

        var errorDescription: String? {
            switch self {
            case .scriptingUnavailable(let msg): return msg
            case .notFound(let msg):             return msg
            }
        }
    }

    // MARK: - Create

    /// Creates a new note in the default account/folder.
    /// Returns the title as confirmed by Notes.
    static func createNote(title: String, body: String) async throws -> String {
        let safeTitle = escaped(title)
        let safeBody  = escaped(body)
        let script = """
        tell application "Notes"
            set n to make new note at folder "Notes" with properties ¬
                {name: "\(safeTitle)", body: "\(safeTitle)\\n\(safeBody)"}
            return name of n
        end tell
        """
        do {
            let result = try await AppleScriptRunner.run(script)
            return result.isEmpty ? title : result
        } catch let e as AppleScriptRunner.ScriptError {
            throw NotesError.scriptingUnavailable(e.message)
        }
    }

    // MARK: - Append

    /// Appends a timestamped block to an existing note whose name contains
    /// `title`. Throws `notFound` if no matching note exists.
    static func appendToNote(title: String, body: String) async throws {
        let safeTitle = escaped(title)
        let safeBody  = escaped(body)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let script = """
        tell application "Notes"
            set matchNote to missing value
            repeat with n in every note
                if name of n contains "\(safeTitle)" then
                    set matchNote to n
                    exit repeat
                end if
            end repeat
            if matchNote is missing value then
                return "NOT_FOUND"
            end if
            set body of matchNote to (body of matchNote) & "\\n\\n[\(timestamp)]\\n\(safeBody)"
        end tell
        """
        do {
            let result = try await AppleScriptRunner.run(script)
            if result.trimmingCharacters(in: .whitespaces) == "NOT_FOUND" {
                throw NotesError.notFound("No note found matching \"\(title)\"")
            }
        } catch let e as AppleScriptRunner.ScriptError {
            throw NotesError.scriptingUnavailable(e.message)
        }
    }

    // MARK: - Search

    /// Returns up to `limit` notes whose name or body contains `query`.
    static func searchNotes(query: String, limit: Int = 5) async throws -> [AppleNote] {
        let safeQuery = escaped(query)
        let script = """
        tell application "Notes"
            set results to {}
            set n to 0
            repeat with aNote in every note
                if name of aNote contains "\(safeQuery)" or body of aNote contains "\(safeQuery)" then
                    set end of results to (name of aNote) & "|||" & (body of aNote)
                    set n to n + 1
                    if n >= \(limit) then exit repeat
                end if
            end repeat
            return results as string
        end tell
        """
        do {
            let raw = try await AppleScriptRunner.run(script)
            return parse(raw: raw)
        } catch let e as AppleScriptRunner.ScriptError {
            throw NotesError.scriptingUnavailable(e.message)
        }
    }

    // MARK: - Open

    /// Brings Apple Notes to the foreground.
    static func openNotes() async throws {
        let script = """
        tell application "Notes"
            activate
        end tell
        """
        do {
            _ = try await AppleScriptRunner.run(script)
        } catch let e as AppleScriptRunner.ScriptError {
            throw NotesError.scriptingUnavailable(e.message)
        }
    }

    // MARK: - Helpers

    /// Escapes characters that would break an AppleScript double-quoted string.
    static func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Parses the "name|||body, name|||body, …" result from the search script.
    private static func parse(raw: String) -> [AppleNote] {
        guard !raw.isEmpty else { return [] }
        return raw.components(separatedBy: ", ")
            .compactMap { chunk -> AppleNote? in
                let parts = chunk.components(separatedBy: "|||")
                guard parts.count >= 2 else { return nil }
                let title = parts[0].trimmingCharacters(in: .whitespaces)
                let body  = parts[1...].joined(separator: "|||")
                    .trimmingCharacters(in: .whitespaces)
                return AppleNote(id: title, title: title, body: body, modifiedAt: nil)
            }
    }
}
