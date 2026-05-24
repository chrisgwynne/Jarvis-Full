import Foundation

/// Identifies which external system produced a ContextNode or ContextEdge.
enum ContextSource: String, Codable, Hashable, CaseIterable {
    case taskThread         = "task_thread"
    case conversationMemory = "conversation_memory"
    case brainMemory        = "brain_memory"
    case obsidianVault      = "obsidian_vault"
    case githubRepo         = "github_repo"
    case githubIssue        = "github_issue"
    case githubPR           = "github_pr"
    case todoistTask        = "todoist_task"
    case calendarEvent      = "calendar_event"
    case executionTrace     = "execution_trace"
    case ambientContext     = "ambient_context"
    case appleNotes         = "apple_notes"
    case appleMail          = "apple_mail"
    case system             = "system"
    case manual             = "manual"

    var displayName: String {
        switch self {
        case .taskThread:         return "Task Thread"
        case .conversationMemory: return "Conversation Memory"
        case .brainMemory:        return "Brain Memory"
        case .obsidianVault:      return "Obsidian Vault"
        case .githubRepo:         return "GitHub Repo"
        case .githubIssue:        return "GitHub Issue"
        case .githubPR:           return "GitHub PR"
        case .todoistTask:        return "Todoist Task"
        case .calendarEvent:      return "Calendar Event"
        case .executionTrace:     return "Execution Trace"
        case .ambientContext:     return "Ambient Context"
        case .appleNotes:         return "Apple Notes"
        case .appleMail:          return "Apple Mail"
        case .system:             return "System"
        case .manual:             return "Manual"
        }
    }
}
