import Foundation
import OSLog

// MARK: - Issue metadata enums

enum GitHubIssueType: String, CaseIterable, Codable {
    case bug        = "bug"
    case regression = "regression"
    case feature    = "feature"
    case task       = "task"
    case question   = "question"

    var label: String { rawValue }
    var emoji: String {
        switch self {
        case .bug:        return "🐛"
        case .regression: return "↩️"
        case .feature:    return "✨"
        case .task:       return "📋"
        case .question:   return "❓"
        }
    }
}

enum GitHubIssueSeverity: String, CaseIterable, Codable {
    case low      = "low"
    case medium   = "medium"
    case high     = "high"
    case critical = "critical"

    var label: String { rawValue }
    var color: String {
        switch self {
        case .low:      return "gray"
        case .medium:   return "yellow"
        case .high:     return "orange"
        case .critical: return "red"
        }
    }
}

enum GitHubIssueArea: String, CaseIterable, Codable {
    case brain         = "brain"
    case macApp        = "Mac app"
    case android       = "Android app"
    case stt           = "STT"
    case tts           = "TTS"
    case vision        = "vision"
    case ui            = "UI"
    case daemon        = "daemon"
    case keychain      = "keychain"
    case github        = "GitHub"
    case homeAssistant = "Home Assistant"
    case other         = "other"

    var label: String { rawValue }
}

// MARK: - GitHubIssueDraft

/// Mutable draft for the GitHub Issue Overlay.  Persisted in-memory
/// until app restart or user discards — so a failed submission never loses content.
@Observable
final class GitHubIssueDraft {

    // MARK: Fields (all editable in the overlay)
    var repo: String           = ""
    var title: String          = ""
    var issueType: GitHubIssueType      = .bug
    var severity: GitHubIssueSeverity   = .medium
    var area: GitHubIssueArea           = .macApp
    var description: String    = ""
    var stepsToReproduce: String = ""
    var expectedBehaviour: String = ""
    var actualBehaviour: String   = ""
    var logsTrace: String         = ""
    var labelsCSV: String         = ""
    var assignees: String         = ""

    // MARK: Deduplication
    /// Error signature — used to detect repeated identical errors.
    var errorSignature: String?
    /// How many times the same error was seen before this draft was opened.
    var duplicateCount: Int = 1

    // MARK: Source tracking
    enum Source: Equatable {
        case automaticError   // opened by the runtime error handler
        case manualVoice      // user said "open a GitHub issue"
        case manualWithContext // user said "log this as an issue" (recent context attached)
    }
    var source: Source = .manualVoice

    // MARK: Submission state
    enum SubmitState: Equatable {
        case idle
        case submitting
        case success(url: String, number: Int)
        case failed(message: String)
    }
    var submitState: SubmitState = .idle

    // MARK: - Rendered body

    /// Full Markdown body built from the form fields.
    var renderedBody: String {
        var lines: [String] = []

        lines.append("## Summary")
        lines.append(description.isEmpty ? "_No description provided._" : description)
        lines.append("")

        if !expectedBehaviour.isEmpty {
            lines.append("## Expected Behaviour")
            lines.append(expectedBehaviour)
            lines.append("")
        }

        if !actualBehaviour.isEmpty {
            lines.append("## Actual Behaviour")
            lines.append(actualBehaviour)
            lines.append("")
        }

        if !stepsToReproduce.isEmpty {
            lines.append("## Steps to Reproduce")
            lines.append(stepsToReproduce)
            lines.append("")
        }

        if !logsTrace.isEmpty {
            lines.append("## Logs / Trace")
            lines.append("```text")
            lines.append(logsTrace)
            lines.append("```")
            lines.append("")
        }

        // Environment block
        lines.append("## Environment")
        lines.append("- **App:** Jarvis macOS")
        lines.append("- **Area:** \(area.label)")
        lines.append("- **Severity:** \(severity.label)")
        lines.append("- **Type:** \(issueType.label)")
        lines.append("- **macOS:** \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("- **Timestamp:** \(ISO8601DateFormatter().string(from: Date()))")
        if duplicateCount > 1 {
            lines.append("- **Duplicate occurrences:** \(duplicateCount)")
        }

        lines.append("")
        lines.append("---")
        lines.append("*Filed via Jarvis GitHub Issue Overlay.*")

        return lines.joined(separator: "\n")
    }

    /// Labels array derived from `issueType`, `severity`, and `labelsCSV`.
    var resolvedLabels: [String] {
        var labels: [String] = [issueType.rawValue, severity.rawValue]
        let extra = labelsCSV
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        labels.append(contentsOf: extra)
        return labels
    }

    // MARK: - Blank / pre-filled constructors

    static func blank(defaultRepo: String = "") -> GitHubIssueDraft {
        let d = GitHubIssueDraft()
        d.repo = defaultRepo
        d.source = .manualVoice
        return d
    }

    /// Pre-fill from a runtime error.
    static func fromError(
        title: String,
        description: String,
        area: GitHubIssueArea,
        severity: GitHubIssueSeverity,
        logs: String,
        signature: String?,
        duplicateCount: Int,
        defaultRepo: String
    ) -> GitHubIssueDraft {
        let d = GitHubIssueDraft()
        d.repo = defaultRepo
        d.title = title
        d.issueType = .bug
        d.severity = severity
        d.area = area
        d.description = description
        d.logsTrace = String(logs.prefix(2000))
        d.errorSignature = signature
        d.duplicateCount = duplicateCount
        d.source = .automaticError
        return d
    }

    /// Pre-fill from recent unmatched command context.
    static func fromContext(
        rawTranscript: String,
        context: String?,
        defaultRepo: String
    ) -> GitHubIssueDraft {
        let d = GitHubIssueDraft()
        d.repo = defaultRepo
        d.title = "[Unknown command] \"\(rawTranscript.prefix(80))\""
        d.issueType = .task
        d.severity = .low
        d.area = .macApp
        d.description = "Jarvis did not understand: \"\(rawTranscript)\""
        d.stepsToReproduce = "1. Say: \"\(rawTranscript)\"\n2. Jarvis responds with an unmatched command message."
        d.expectedBehaviour = "Jarvis handles the command correctly."
        d.actualBehaviour = "Jarvis does not recognise the command."
        if let ctx = context { d.logsTrace = String(ctx.prefix(1500)) }
        d.source = .manualWithContext
        return d
    }
}

// MARK: - GitHubIssueDraftStore

/// Holds the current unsent draft across sessions (in-memory only — discarded on restart).
/// Deduplicates repeated identical errors so the overlay isn't spammed.
@MainActor
final class GitHubIssueDraftStore {

    static let shared = GitHubIssueDraftStore()

    // MARK: - Active draft

    /// The single draft the overlay shows. Nil when overlay has not been opened yet.
    private(set) var currentDraft: GitHubIssueDraft? = nil

    /// Discard the current draft (Cancel button, successful submit).
    func clearDraft() {
        currentDraft = nil
    }

    // MARK: - Deduplication

    /// Signatures of errors that have already been surfaced (key = signature, value = count).
    private var seenSignatures: [String: Int] = [:]
    /// Timestamp of the last overlay open — prevents re-opening within 30 s.
    private var lastOpenedAt: Date = .distantPast

    /// Minimum gap between automatic overlay opens for DIFFERENT errors.
    private let minIntervalSeconds: TimeInterval = 30

    // MARK: - Open logic

    /// Open the overlay with a new pre-filled draft for a runtime error.
    /// Returns `false` and bumps the duplicate count if the same error fires again
    /// within the dedup window — the overlay already shows that error.
    @discardableResult
    func openForError(
        title: String,
        description: String,
        area: GitHubIssueArea,
        severity: GitHubIssueSeverity,
        logs: String,
        signature: String?,
        defaultRepo: String
    ) -> Bool {
        let sig = signature ?? "\(title.prefix(60))"

        // Already open with THIS error → just increment the duplicate count.
        if let existing = currentDraft,
           existing.errorSignature == sig,
           existing.submitState == .idle {
            existing.duplicateCount += 1
            seenSignatures[sig, default: 0] += 1
            let count = seenSignatures[sig, default: 1]
            Log.github.info("[GitHubIssueOverlay] duplicateDetected count=\(count) sig=\(sig.prefix(60))")
            return false
        }

        // Too soon after the last open → skip.
        let elapsed = Date().timeIntervalSince(lastOpenedAt)
        if elapsed < minIntervalSeconds, currentDraft != nil {
            let count = seenSignatures[sig, default: 0] + 1
            seenSignatures[sig] = count
            Log.github.info("[GitHubIssueOverlay] suppressedTooSoon sig=\(sig.prefix(60)) count=\(count)")
            return false
        }

        let count = (seenSignatures[sig] ?? 0) + 1
        seenSignatures[sig] = count
        lastOpenedAt = Date()

        let draft = GitHubIssueDraft.fromError(
            title: title,
            description: description,
            area: area,
            severity: severity,
            logs: logs,
            signature: sig,
            duplicateCount: count,
            defaultRepo: defaultRepo
        )
        currentDraft = draft

        Log.github.info("[GitHubIssueOverlay] opened source=automatic_error")
        Log.github.info("[GitHubIssueOverlay] prefilled title=\(title.prefix(80))")
        return true
    }

    /// Open the overlay for a manual voice request. If `context` is provided,
    /// pre-fills from recent error/command context; otherwise opens blank.
    func openManual(rawTranscript: String? = nil, context: String? = nil, defaultRepo: String) {
        if let transcript = rawTranscript {
            currentDraft = GitHubIssueDraft.fromContext(
                rawTranscript: transcript,
                context: context,
                defaultRepo: defaultRepo
            )
            Log.github.info("[GitHubIssueOverlay] opened source=manual")
            let prefilled = currentDraft?.title ?? ""
            Log.github.info("[GitHubIssueOverlay] prefilled title=\(prefilled)")
        } else {
            currentDraft = GitHubIssueDraft.blank(defaultRepo: defaultRepo)
            Log.github.info("[GitHubIssueOverlay] opened source=manual")
        }
        lastOpenedAt = Date()
    }
}
