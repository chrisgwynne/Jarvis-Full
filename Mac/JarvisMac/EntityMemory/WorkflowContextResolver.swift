import Foundation

// MARK: - WorkflowContextResolver

@MainActor
enum WorkflowContextResolver {

    // MARK: - Active context accessors

    static func activeRepository()  -> EntityMemNode? { graph.byKind(.repository, limit: 1).first }
    static func activeBranch()      -> EntityMemNode? { graph.byKind(.branch, limit: 1).first }
    static func activePullRequest() -> EntityMemNode? { graph.byKind(.pullRequest, limit: 1).first }
    static func activeIssue()       -> EntityMemNode? { graph.byKind(.githubIssue, limit: 1).first }
    static func activeCodingFile()  -> EntityMemNode? { graph.byKind(.file, limit: 1).first }

    // MARK: - "Continue where we left off"

    static func resolveWorkflowContinuation() -> EntityMemNode? {
        if let pr    = activePullRequest()                    { return pr }
        if let issue = activeIssue()                          { return issue }
        if let task  = graph.byKind(.task, limit: 1).first   { return task }
        if let file  = activeCodingFile()                     { return file }
        return graph.byKind(.conversationTopic, limit: 1).first
    }

    // MARK: - "The other X"

    static func resolveOther(kind: EntityMemKind, currentId: String?) -> EntityMemNode? {
        let candidates = graph.byKind(kind, limit: 5)
        guard candidates.count >= 2 else { return nil }
        return candidates.first(where: { $0.id != currentId })
    }

    // MARK: - LLM context block

    static func workflowContextBlock() -> String? {
        var lines: [String] = []
        if let repo   = activeRepository()  { lines.append("active_repo: \(repo.canonicalName)") }
        if let branch = activeBranch()      { lines.append("active_branch: \(branch.canonicalName)") }
        if let pr     = activePullRequest() { lines.append("active_pr: \(pr.canonicalName)") }
        if let issue  = activeIssue()       { lines.append("active_issue: \(issue.canonicalName)") }
        if let file   = activeCodingFile()  { lines.append("active_file: \(file.canonicalName)") }
        guard !lines.isEmpty else { return nil }
        return (["{WORKFLOW CONTEXT}"] + lines).joined(separator: "\n")
    }

    // MARK: - Private

    private static var graph: EntityMemoryGraph { .shared }
}
