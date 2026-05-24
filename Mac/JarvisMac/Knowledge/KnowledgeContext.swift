import Foundation

/// The result of querying all knowledge sources for a given transcript.
struct KnowledgeContext {
    var projectFacts: [String]        // key project facts from memory + docs
    var roadmapItems: [String]        // current roadmap/todo items
    var recentDecisions: [String]     // recently made decisions
    var memoryHits: [String]          // matched entries from MemoryStore
    var obsidianExcerpts: [String]    // matched excerpts from Obsidian vault
    var sources: [String]             // which sources were queried (for diagnostics)
    var retrievalLatencyMs: Double

    static var empty: KnowledgeContext {
        KnowledgeContext(
            projectFacts: [],
            roadmapItems: [],
            recentDecisions: [],
            memoryHits: [],
            obsidianExcerpts: [],
            sources: [],
            retrievalLatencyMs: 0
        )
    }

    var isEmpty: Bool {
        projectFacts.isEmpty &&
        roadmapItems.isEmpty &&
        recentDecisions.isEmpty &&
        memoryHits.isEmpty &&
        obsidianExcerpts.isEmpty
    }

    var summary: String {
        var parts: [String] = []
        if !projectFacts.isEmpty     { parts.append("\(projectFacts.count) facts") }
        if !roadmapItems.isEmpty     { parts.append("\(roadmapItems.count) roadmap items") }
        if !memoryHits.isEmpty       { parts.append("\(memoryHits.count) memories") }
        if !obsidianExcerpts.isEmpty { parts.append("\(obsidianExcerpts.count) vault excerpts") }
        return parts.isEmpty ? "no context" : parts.joined(separator: ", ")
    }
}

/// A knowledge source identifier for diagnostics.
enum KnowledgeSource: String {
    case memory       = "memory_store"
    case obsidian     = "obsidian_vault"
    case projectDocs  = "project_docs"
    case conversation = "conversation_log"
    case localIndex   = "local_index"
}
