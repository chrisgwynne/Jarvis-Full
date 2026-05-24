import Foundation

// MARK: - NotesIntentHandler

/// Handles Apple Notes domain intents. Follows the per-domain handler
/// pattern introduced in Sprint P (Shopify / Todoist style).
@MainActor final class NotesIntentHandler {

    private let renderer: ResponseRenderer

    var speak: (String) -> Void = { _ in }
    var setPendingContext: (PendingConversationContext) -> Void = { _ in }
    var currentTranscript: () -> String = { "" }
    var ingestNode: ((ContextNode) -> Void)?   // optional graph ingestion hook

    init(renderer: ResponseRenderer) {
        self.renderer = renderer
    }

    /// Returns true if the intent was handled, false if not a Notes intent.
    func handle(_ intent: Intent) async -> Bool {
        switch intent {

        // MARK: - Open / Show

        case .openNotes, .showNotes:
            do {
                try await AppleNotesService.openNotes()
                speak(renderer.render(ResponseKey.notesOpened))
            } catch {
                speak(renderer.render(ResponseKey.notesPermissionError))
            }
            return true

        // MARK: - Create

        case .createNote(let title, let body):
            if title.isEmpty && body.isEmpty {
                speak(renderer.render(ResponseKey.notesNeedTitle))
                setPendingContext(.make(
                    originalTranscript: currentTranscript(),
                    originalIntent: intent,
                    assistantQuestion: renderer.render(ResponseKey.notesNeedTitle),
                    responseType: .freeform,
                    onFreeform: .callLLMWithHistory
                ))
                return true
            }
            let resolvedTitle = title.isEmpty ? body.truncated(to: 40) : title
            let resolvedBody  = body.isEmpty  ? title : body
            do {
                let confirmed = try await AppleNotesService.createNote(title: resolvedTitle,
                                                                        body: resolvedBody)
                speak(renderer.render(ResponseKey.notesCreated, ["title": confirmed]))
                ingestNoteNode(title: confirmed, body: resolvedBody)
            } catch let e as AppleNotesService.NotesError {
                handleNotesError(e, context: resolvedTitle)
            } catch {
                speak(renderer.render(ResponseKey.notesPermissionError))
            }
            return true

        // MARK: - Append

        case .appendNote(let title, let body):
            if title.isEmpty {
                speak(renderer.render(ResponseKey.notesNeedTitle))
                setPendingContext(.make(
                    originalTranscript: currentTranscript(),
                    originalIntent: intent,
                    assistantQuestion: renderer.render(ResponseKey.notesNeedTitle),
                    responseType: .freeform,
                    onFreeform: .callLLMWithHistory
                ))
                return true
            }
            if body.isEmpty {
                speak(renderer.render(ResponseKey.notesNeedBody))
                setPendingContext(.make(
                    originalTranscript: currentTranscript(),
                    originalIntent: intent,
                    assistantQuestion: renderer.render(ResponseKey.notesNeedBody),
                    responseType: .freeform,
                    onFreeform: .callLLMWithHistory
                ))
                return true
            }
            do {
                try await AppleNotesService.appendToNote(title: title, body: body)
                speak(renderer.render(ResponseKey.notesAppended, ["title": title]))
                ingestNoteNode(title: title, body: body)
            } catch let e as AppleNotesService.NotesError {
                handleNotesError(e, context: title)
            } catch {
                speak(renderer.render(ResponseKey.notesPermissionError))
            }
            return true

        // MARK: - Search

        case .searchNotes(let query):
            if query.isEmpty {
                speak(renderer.render(ResponseKey.notesNeedQuery))
                setPendingContext(.make(
                    originalTranscript: currentTranscript(),
                    originalIntent: intent,
                    assistantQuestion: renderer.render(ResponseKey.notesNeedQuery),
                    responseType: .freeform,
                    onFreeform: .callLLMWithHistory
                ))
                return true
            }
            do {
                let notes = try await AppleNotesService.searchNotes(query: query)
                if notes.isEmpty {
                    speak(renderer.render(ResponseKey.notesNoResults, ["query": query]))
                } else {
                    let titles = notes.prefix(3).map(\.title).joined(separator: ", ")
                    speak(renderer.render(ResponseKey.notesSearchResult, [
                        "count":       "\(notes.count)",
                        "count_label": notes.count == 1 ? "note" : "notes",
                        "titles":      titles,
                    ]))
                    for note in notes.prefix(3) {
                        ingestNoteNode(title: note.title, body: note.body)
                    }
                }
            } catch let e as AppleNotesService.NotesError {
                handleNotesError(e, context: query)
            } catch {
                speak(renderer.render(ResponseKey.notesPermissionError))
            }
            return true

        default:
            return false
        }
    }

    // MARK: - Helpers

    private func handleNotesError(_ error: AppleNotesService.NotesError, context: String) {
        switch error {
        case .notFound:
            speak(renderer.render(ResponseKey.notesNotFound, ["title": context]))
        case .scriptingUnavailable:
            speak(renderer.render(ResponseKey.notesPermissionError))
        }
    }

    func ingestNoteNode(title: String, body: String) {
        let node = ContextNode(
            type:       .appleNote,
            title:      title,
            summary:    String(body.prefix(120)),
            source:     .appleNotes,
            confidence: 0.90,
            trustTier:  .synced,
            externalID: "applenote:\(title.lowercased().replacingOccurrences(of: " ", with: "-"))"
        )
        ingestNode?(node)
    }
}

// MARK: - String helper

private extension String {
    func truncated(to maxLength: Int) -> String {
        count > maxLength ? String(prefix(maxLength)) + "…" : self
    }
}
