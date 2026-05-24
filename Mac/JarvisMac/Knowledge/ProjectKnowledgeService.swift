import Foundation

@MainActor
final class ProjectKnowledgeService {

    private let memories:   MemoryStore?
    private let search:     SearchService?
    private let obsidian:   ObsidianVaultService?
    private let convMemory: ConversationMemoryStore

    /// Optional path to project documentation (FEATURES.md, TODO.md, CLAUDE.md etc.)
    var projectDocsPath: String? = nil

    init(
        memories:   MemoryStore?,
        search:     SearchService?,
        obsidian:   ObsidianVaultService?,
        convMemory: ConversationMemoryStore
    ) {
        self.memories   = memories
        self.search     = search
        self.obsidian   = obsidian
        self.convMemory = convMemory
    }

    // MARK: - Main retrieval

    /// Build a `KnowledgeContext` relevant to `transcript` for the given route.
    ///
    /// - General chat routes return `.empty` immediately (no retrieval).
    /// - All other routes fan out in parallel across memory, vault, docs,
    ///   and conversation memory, then merge results.
    func retrieve(for transcript: String, route: ConversationRoute) async -> KnowledgeContext {
        let start = Date()

        // General chat doesn't need knowledge retrieval
        guard route == .projectReflection ||
              route == .knowledgeQuery    ||
              route == .memoryUpdate      else {
            return .empty
        }

        var ctx = KnowledgeContext.empty
        let query = extractKeyTerms(from: transcript)

        // Fan out in parallel
        async let memHits   = retrieveFromMemory(query: query)
        async let obsHits   = retrieveFromObsidian(query: query)
        async let docFacts  = retrieveFromProjectDocs(query: query)
        async let convFacts = retrieveFromConversationMemory(query: query)

        let (m, o, d, c) = await (memHits, obsHits, docFacts, convFacts)

        // Merge
        ctx.memoryHits         = Array(m.prefix(5))
        ctx.obsidianExcerpts   = Array(o.prefix(4))
        ctx.projectFacts       = Array((d + c).prefix(6))
        ctx.roadmapItems       = extractRoadmapItems(from: d)
        ctx.recentDecisions    = extractDecisions(from: m + c)
        ctx.sources            = buildSourceList(m: m, o: o, d: d, c: c)
        ctx.retrievalLatencyMs = Date().timeIntervalSince(start) * 1000

        return ctx
    }

    // MARK: - Memory retrieval

    private func retrieveFromMemory(query: String) async -> [String] {
        // Prefer hybrid search when available
        if let svc = search {
            let results = await svc.hybridSearch(query: query, limit: 8)
            return results
                .filter { $0.kind == .memory }
                .map    { $0.text }
        }
        // Fallback to plain MemoryStore
        if let mem = memories {
            let results = await mem.search(query: query, limit: 8)
            return results.map { $0.text }
        }
        return []
    }

    // MARK: - Obsidian retrieval

    private func retrieveFromObsidian(query: String) async -> [String] {
        guard let vault = obsidian else { return [] }
        let notes = await vault.hybridSearch(query: query, limit: 5)
        return notes.map { note -> String in
            let excerpt = String(note.body.prefix(300))
            return "[\(note.title)]: \(excerpt)"
        }
    }

    // MARK: - Project docs retrieval (FEATURES.md, TODO.md, CLAUDE.md)

    private func retrieveFromProjectDocs(query: String) async -> [String] {
        guard let docsPath = projectDocsPath else { return [] }
        let docFiles = ["FEATURES.md", "TODO.md", "CLAUDE.md"]
        var facts: [String] = []
        let terms = query.lowercased()
            .components(separatedBy: " ")
            .filter { $0.count > 3 }

        for fileName in docFiles {
            let filePath = (docsPath as NSString).appendingPathComponent(fileName)
            guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else { continue }

            // Extract lines that match one or more query terms
            let lines = content.components(separatedBy: "\n")
            let relevant = lines.filter { line in
                let l = line.lowercased()
                return !l.isEmpty && terms.contains(where: { l.contains($0) })
            }

            // Cap at 4 lines per file, prefix with source
            let limited = relevant.prefix(4).map { "[\(fileName)] \($0)" }
            facts.append(contentsOf: limited)
        }

        return Array(facts.prefix(8))
    }

    // MARK: - Conversation memory retrieval

    private func retrieveFromConversationMemory(query: String) async -> [String] {
        let items = await convMemory.search(query: query, limit: 5)
        return items.map { item in
            "[\(item.type.rawValue)] \(item.title): \(item.summary)"
        }
    }

    // MARK: - Extraction helpers

    /// Strip filler words and return a compact term string suitable for search.
    private func extractKeyTerms(from text: String) -> String {
        let stopWords: Set<String> = [
            "i", "the", "a", "an", "that", "this", "it", "is", "are", "was", "were",
            "what", "how", "do", "did", "does", "have", "has", "had", "to", "of",
            "for", "and", "or", "but", "in", "on", "at", "by", "my", "me", "we",
            "you", "think", "about", "just"
        ]
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !stopWords.contains($0) }
        return words.prefix(8).joined(separator: " ")
    }

    private func extractRoadmapItems(from lines: [String]) -> [String] {
        Array(
            lines.filter { line in
                line.contains("TODO")
                || line.contains("🔲")
                || line.contains("⚠️")
                || line.contains("[ ]")
                || line.lowercased().contains("roadmap")
                || line.lowercased().contains("next")
            }
            .prefix(5)
        )
    }

    private func extractDecisions(from items: [String]) -> [String] {
        let keywords = ["decided", "decision", "chose", "using", "will use", "architecture"]
        return Array(
            items.filter { item in
                keywords.contains(where: { item.lowercased().contains($0) })
            }
            .prefix(3)
        )
    }

    private func buildSourceList(m: [String], o: [String], d: [String], c: [String]) -> [String] {
        var sources: [String] = []
        if !m.isEmpty { sources.append(KnowledgeSource.memory.rawValue)       }
        if !o.isEmpty { sources.append(KnowledgeSource.obsidian.rawValue)     }
        if !d.isEmpty { sources.append(KnowledgeSource.projectDocs.rawValue)  }
        if !c.isEmpty { sources.append(KnowledgeSource.conversation.rawValue) }
        return sources
    }
}
