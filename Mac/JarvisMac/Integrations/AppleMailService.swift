import Foundation

// MARK: - EmailMessage model

struct EmailMessage: Identifiable {
    let id: String          // stable ID — message ID or subject+sender slug
    let messageID: String   // RFC 2822 Message-ID
    let subject: String
    let sender: String      // full "Name <email>" string as Mail returns it
    let senderName: String  // display name extracted from sender
    let preview: String     // first ~100 chars of body
    let dateString: String  // human-readable date as returned by AppleScript
    let isRead: Bool
}

// MARK: - AppleMailService

/// AppleScript-backed interface for Apple Mail.
///
/// IMPORTANT: Never sends email automatically. All write operations create
/// visible drafts only — the user must manually confirm and send.
/// All methods throw `AppleMailService.MailError` when Mail scripting is
/// unavailable; callers should catch and speak a setup guidance response.
enum AppleMailService {

    enum MailError: Error, LocalizedError {
        case scriptingUnavailable(String)
        case notFound(String)

        var errorDescription: String? {
            switch self {
            case .scriptingUnavailable(let msg): return msg
            case .notFound(let msg):             return msg
            }
        }
    }

    // MARK: - Read

    /// Returns up to `limit` recent messages from all INBOX folders.
    static func recentEmails(limit: Int = 5) async throws -> [EmailMessage] {
        let script = """
        set NL to (ASCII character 10)
        set result to ""
        set counter to 0
        tell application "Mail"
            repeat with anAccount in every account
                try
                    set inboxBox to mailbox "INBOX" of anAccount
                    repeat with aMessage in (every message of inboxBox)
                        if counter < \(limit) then
                            set subj to subject of aMessage
                            if subj is missing value then set subj to "(no subject)"
                            set sndr to sender of aMessage
                            if sndr is missing value then set sndr to "(unknown)"
                            set msgID to message id of aMessage
                            if msgID is missing value then set msgID to ""
                            set isRead to (read status of aMessage) as string
                            set result to result & subj & "|||" & sndr & "|||" & msgID & "|||" & isRead & NL
                            set counter to counter + 1
                        end if
                    end repeat
                end try
            end repeat
        end tell
        return result
        """
        do {
            let raw = try await AppleScriptRunner.run(script)
            return parseMessages(raw)
        } catch let e as AppleScriptRunner.ScriptError {
            throw MailError.scriptingUnavailable(e.message)
        }
    }

    /// Returns up to `limit` unread messages from all INBOX folders.
    static func unreadEmails(limit: Int = 5) async throws -> [EmailMessage] {
        let script = """
        set NL to (ASCII character 10)
        set result to ""
        set counter to 0
        tell application "Mail"
            repeat with anAccount in every account
                try
                    set inboxBox to mailbox "INBOX" of anAccount
                    repeat with aMessage in (every message of inboxBox)
                        if counter < \(limit) then
                            if not (read status of aMessage) then
                                set subj to subject of aMessage
                                if subj is missing value then set subj to "(no subject)"
                                set sndr to sender of aMessage
                                if sndr is missing value then set sndr to "(unknown)"
                                set msgID to message id of aMessage
                                if msgID is missing value then set msgID to ""
                                set result to result & subj & "|||" & sndr & "|||" & msgID & "|||" & "false" & NL
                                set counter to counter + 1
                            end if
                        end if
                    end repeat
                end try
            end repeat
        end tell
        return result
        """
        do {
            let raw = try await AppleScriptRunner.run(script)
            return parseMessages(raw)
        } catch let e as AppleScriptRunner.ScriptError {
            throw MailError.scriptingUnavailable(e.message)
        }
    }

    /// Returns up to `limit` messages whose subject or sender contains `query`.
    static func searchEmails(query: String, limit: Int = 5) async throws -> [EmailMessage] {
        let safeQuery = escaped(query)
        let script = """
        set NL to (ASCII character 10)
        set result to ""
        set counter to 0
        tell application "Mail"
            repeat with anAccount in every account
                try
                    set inboxBox to mailbox "INBOX" of anAccount
                    repeat with aMessage in (every message of inboxBox)
                        if counter < \(limit) then
                            set subj to subject of aMessage
                            if subj is missing value then set subj to ""
                            set sndr to sender of aMessage
                            if sndr is missing value then set sndr to ""
                            if (subj contains "\(safeQuery)") or (sndr contains "\(safeQuery)") then
                                set msgID to message id of aMessage
                                if msgID is missing value then set msgID to ""
                                set isRead to (read status of aMessage) as string
                                set result to result & subj & "|||" & sndr & "|||" & msgID & "|||" & isRead & NL
                                set counter to counter + 1
                            end if
                        end if
                    end repeat
                end try
            end repeat
        end tell
        return result
        """
        do {
            let raw = try await AppleScriptRunner.run(script)
            return parseMessages(raw)
        } catch let e as AppleScriptRunner.ScriptError {
            throw MailError.scriptingUnavailable(e.message)
        }
    }

    // MARK: - Write (drafts only — never sends automatically)

    /// Opens Mail with a new draft addressed to `to`.
    /// The user must manually review and send.
    static func createDraft(to recipient: String, subject: String, body: String) async throws {
        let safeTo      = escaped(recipient)
        let safeSubject = escaped(subject)
        let safeBody    = escaped(body)
        let script = """
        tell application "Mail"
            set newMessage to make new outgoing message with properties ¬
                {subject: "\(safeSubject)", content: "\(safeBody)", visible: true}
            tell newMessage
                make new to recipient at end of to recipients ¬
                    with properties {address: "\(safeTo)"}
            end tell
            activate
        end tell
        """
        do {
            _ = try await AppleScriptRunner.run(script)
        } catch let e as AppleScriptRunner.ScriptError {
            throw MailError.scriptingUnavailable(e.message)
        }
    }

    // MARK: - Open

    /// Brings Apple Mail to the foreground.
    static func openMail() async throws {
        let script = """
        tell application "Mail"
            activate
        end tell
        """
        do {
            _ = try await AppleScriptRunner.run(script)
        } catch let e as AppleScriptRunner.ScriptError {
            throw MailError.scriptingUnavailable(e.message)
        }
    }

    // MARK: - Helpers

    /// Escapes characters that would break an AppleScript double-quoted string.
    static func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Parses the newline-delimited "subject|||sender|||msgID|||readStatus" output.
    private static func parseMessages(_ raw: String) -> [EmailMessage] {
        guard !raw.isEmpty else { return [] }
        return raw.components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .compactMap { line -> EmailMessage? in
                let parts = line.components(separatedBy: "|||")
                guard parts.count >= 4 else { return nil }
                let subject  = parts[0].trimmingCharacters(in: .whitespaces)
                let sender   = parts[1].trimmingCharacters(in: .whitespaces)
                let messageID = parts[2].trimmingCharacters(in: .whitespaces)
                let isRead   = parts[3].trimmingCharacters(in: .whitespaces) == "true"
                let slug     = messageID.isEmpty ? "\(subject)-\(sender)" : messageID
                return EmailMessage(
                    id:          slug,
                    messageID:   messageID,
                    subject:     subject.isEmpty ? "(no subject)" : subject,
                    sender:      sender,
                    senderName:  extractName(from: sender),
                    preview:     "",
                    dateString:  "",
                    isRead:      isRead
                )
            }
    }

    /// Extracts a display name from "Name <email>" or returns the raw string.
    private static func extractName(from sender: String) -> String {
        if let angleBracket = sender.range(of: "<") {
            return sender[sender.startIndex..<angleBracket.lowerBound]
                .trimmingCharacters(in: .whitespaces.union(.init(charactersIn: "\"")))
        }
        return sender
    }
}
