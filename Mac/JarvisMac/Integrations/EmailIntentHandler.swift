import Foundation

// MARK: - EmailIntentHandler

/// Handles Apple Mail domain intents. Follows the per-domain handler
/// pattern (Shopify / Todoist / Notes style).
///
/// SECURITY: This handler NEVER sends email automatically.
/// All write operations create visible drafts that the user must
/// manually review and send in Mail.app.
@MainActor final class EmailIntentHandler {

    private let renderer: ResponseRenderer

    var speak: (String) -> Void = { _ in }
    var setPendingContext: (PendingConversationContext) -> Void = { _ in }
    var currentTranscript: () -> String = { "" }
    var ingestNode: ((ContextNode) -> Void)?

    init(renderer: ResponseRenderer) {
        self.renderer = renderer
    }

    /// Returns true if the intent was handled, false if not an email intent.
    func handle(_ intent: Intent) async -> Bool {
        switch intent {

        // MARK: - Open Mail

        case .showEmail, .checkEmail:
            do {
                try await AppleMailService.openMail()
                speak(renderer.render(ResponseKey.emailOpened))
                if case .checkEmail = intent {
                    // Fall through to unread summary after opening
                    do {
                        let msgs = try await AppleMailService.unreadEmails(limit: 5)
                        speak(unreadSummary(msgs))
                        for m in msgs.prefix(3) { ingestEmailNode(from: m) }
                    } catch {
                        // Non-fatal — we already spoke the "opened" line
                    }
                }
            } catch let e as AppleMailService.MailError {
                handleMailError(e)
            } catch {
                speak(renderer.render(ResponseKey.emailPermissionNeeded))
            }
            return true

        // MARK: - Unread

        case .unreadEmail:
            do {
                let msgs = try await AppleMailService.unreadEmails(limit: 5)
                if msgs.isEmpty {
                    speak(renderer.render(ResponseKey.emailNoneFound, ["query": "unread"]))
                } else {
                    speak(unreadSummary(msgs))
                    for m in msgs.prefix(3) { ingestEmailNode(from: m) }
                }
            } catch let e as AppleMailService.MailError {
                handleMailError(e)
            } catch {
                speak(renderer.render(ResponseKey.emailPermissionNeeded))
            }
            return true

        // MARK: - Latest

        case .readLatestEmail:
            do {
                let msgs = try await AppleMailService.recentEmails(limit: 1)
                if msgs.isEmpty {
                    speak(renderer.render(ResponseKey.emailNoneFound, ["query": "email"]))
                } else {
                    let m = msgs[0]
                    speak(renderer.render(ResponseKey.emailUnreadSummary, [
                        "count":   "1",
                        "sender":  m.senderName,
                        "subject": m.subject,
                    ]))
                    ingestEmailNode(from: m)
                }
            } catch let e as AppleMailService.MailError {
                handleMailError(e)
            } catch {
                speak(renderer.render(ResponseKey.emailPermissionNeeded))
            }
            return true

        // MARK: - Search

        case .searchEmail(let query):
            if query.isEmpty {
                speak(renderer.render(ResponseKey.emailNeedQuery))
                setPendingContext(.make(
                    originalTranscript: currentTranscript(),
                    originalIntent: intent,
                    assistantQuestion: renderer.render(ResponseKey.emailNeedQuery),
                    responseType: .freeform,
                    onFreeform: .callLLMWithHistory
                ))
                return true
            }
            do {
                let msgs = try await AppleMailService.searchEmails(query: query, limit: 5)
                if msgs.isEmpty {
                    speak(renderer.render(ResponseKey.emailNoneFound, ["query": query]))
                } else {
                    let top = msgs.first!
                    speak(renderer.render(ResponseKey.emailSearchSummary, [
                        "count":   "\(msgs.count)",
                        "query":   query,
                        "sender":  top.senderName,
                        "subject": top.subject,
                    ]))
                    for m in msgs.prefix(3) { ingestEmailNode(from: m) }
                }
            } catch let e as AppleMailService.MailError {
                handleMailError(e)
            } catch {
                speak(renderer.render(ResponseKey.emailPermissionNeeded))
            }
            return true

        // MARK: - Summarise (unread)

        case .summariseEmail:
            do {
                let msgs = try await AppleMailService.unreadEmails(limit: 5)
                if msgs.isEmpty {
                    speak(renderer.render(ResponseKey.emailNoneFound, ["query": "unread"]))
                } else {
                    speak(unreadSummary(msgs))
                    for m in msgs.prefix(3) { ingestEmailNode(from: m) }
                }
            } catch let e as AppleMailService.MailError {
                handleMailError(e)
            } catch {
                speak(renderer.render(ResponseKey.emailPermissionNeeded))
            }
            return true

        // MARK: - Important / VIP

        case .importantEmail:
            do {
                let keywords = ["urgent", "important", "action required", "asap", "follow up"]
                var important: [EmailMessage] = []
                for keyword in keywords {
                    let found = try await AppleMailService.searchEmails(query: keyword, limit: 3)
                    for m in found where !important.contains(where: { $0.messageID == m.messageID }) {
                        important.append(m)
                    }
                    if important.count >= 5 { break }
                }
                if important.isEmpty {
                    speak(renderer.render(ResponseKey.emailNoneFound, ["query": "important"]))
                } else {
                    let top = important[0]
                    speak(renderer.render(ResponseKey.emailImportantSummary, [
                        "count":   "\(important.count)",
                        "sender":  top.senderName,
                        "subject": top.subject,
                    ]))
                    for m in important.prefix(3) { ingestEmailNode(from: m) }
                }
            } catch let e as AppleMailService.MailError {
                handleMailError(e)
            } catch {
                speak(renderer.render(ResponseKey.emailPermissionNeeded))
            }
            return true

        // MARK: - Draft (never sends automatically)

        case .draftEmail(let to, let subject, let body):
            if to.isEmpty {
                speak(renderer.render(ResponseKey.emailNeedRecipient))
                setPendingContext(.make(
                    originalTranscript: currentTranscript(),
                    originalIntent: intent,
                    assistantQuestion: renderer.render(ResponseKey.emailNeedRecipient),
                    responseType: .freeform,
                    onFreeform: .callLLMWithHistory
                ))
                return true
            }
            if subject.isEmpty {
                speak(renderer.render(ResponseKey.emailNeedSubject))
                setPendingContext(.make(
                    originalTranscript: currentTranscript(),
                    originalIntent: intent,
                    assistantQuestion: renderer.render(ResponseKey.emailNeedSubject),
                    responseType: .freeform,
                    onFreeform: .callLLMWithHistory
                ))
                return true
            }
            do {
                let resolvedBody = body.isEmpty ? "" : body
                try await AppleMailService.createDraft(to: to, subject: subject, body: resolvedBody)
                speak(renderer.render(ResponseKey.emailDraftCreated, [
                    "to":      to,
                    "subject": subject,
                ]))
            } catch let e as AppleMailService.MailError {
                handleMailError(e)
            } catch {
                speak(renderer.render(ResponseKey.emailPermissionNeeded))
            }
            return true

        // MARK: - Reply draft

        case .replyEmail(let to, let body):
            if to.isEmpty {
                speak(renderer.render(ResponseKey.emailNeedRecipient))
                setPendingContext(.make(
                    originalTranscript: currentTranscript(),
                    originalIntent: intent,
                    assistantQuestion: renderer.render(ResponseKey.emailNeedRecipient),
                    responseType: .freeform,
                    onFreeform: .callLLMWithHistory
                ))
                return true
            }
            do {
                try await AppleMailService.createDraft(to: to, subject: "Re:", body: body)
                speak(renderer.render(ResponseKey.emailDraftCreated, [
                    "to":      to,
                    "subject": "Re:",
                ]))
            } catch let e as AppleMailService.MailError {
                handleMailError(e)
            } catch {
                speak(renderer.render(ResponseKey.emailPermissionNeeded))
            }
            return true

        default:
            return false
        }
    }

    // MARK: - Graph ingestion

    func ingestEmailNode(from message: EmailMessage) {
        let node = ContextNode(
            type:       .email,
            title:      message.subject,
            summary:    "From: \(message.senderName). \(message.preview.prefix(100))",
            source:     .appleMail,
            confidence: 0.90,
            trustTier:  .synced,
            externalID: message.messageID.isEmpty
                ? nil
                : "email:\(message.messageID)"
        )
        ingestNode?(node)
    }

    // MARK: - Helpers

    private func unreadSummary(_ msgs: [EmailMessage]) -> String {
        let count = msgs.count
        let top   = msgs[0]
        return renderer.render(ResponseKey.emailUnreadSummary, [
            "count":   "\(count)",
            "sender":  top.senderName,
            "subject": top.subject,
        ])
    }

    private func handleMailError(_ error: AppleMailService.MailError) {
        switch error {
        case .scriptingUnavailable:
            speak(renderer.render(ResponseKey.emailPermissionNeeded))
        case .notFound:
            speak(renderer.render(ResponseKey.emailNoneFound, ["query": "email"]))
        }
    }
}
