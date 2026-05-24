import Foundation

// MARK: - CodebaseIndexer

/// Off-actor codebase scanner that builds a chunk index for semantic retrieval.
///
/// Scanning is always done on a detached utility Task so it never blocks
/// the main actor or the audio pipeline. Results are published to @MainActor
/// via a callback when complete.
@MainActor
final class CodebaseIndexer {
    static let shared = CodebaseIndexer()

    // MARK: - State

    private(set) var chunks: [CodeChunk] = []
    private(set) var isIndexing: Bool = false
    private(set) var lastIndexedAt: Date?
    private(set) var indexedFileCount: Int = 0

    var onIndexingComplete: (([CodeChunk]) -> Void)?

    // MARK: - Disk

    private let indexFileName = "codebase_index.json"
    private var indexURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("JarvisMac/\(indexFileName)")
    }

    // MARK: - Skip rules

    private static let skippedDirectories: Set<String> = [
        "DerivedData", ".git", "build", "node_modules", ".build",
        "xcuserdata", ".claude", "Pods", ".swiftpm", "worktrees"
    ]

    private static let skippedExtensions: Set<String> = [
        "o", "a", "dylib", "so", "xcarchive", "ipa", "dSYM",
        "pbxproj", "xcworkspacedata", "xcscheme", "plist",
        "png", "jpg", "jpeg", "gif", "svg", "pdf", "mp3", "wav",
        "mov", "mp4", "xcassets", "car", "lproj", "strings",
        "stringsdict", "storyboard", "xib", "nib", "onnx", "mlmodel",
        "mlpackage", "bin", "dat", "db", "sqlite", "sqlite3"
    ]

    // MARK: - Reindex

    func reindex(projectRoot: URL) {
        guard !isIndexing else { return }
        isIndexing = true

        Task.detached(priority: .utility) {
            let found = await Self.scanDirectory(projectRoot)
            await MainActor.run {
                self.chunks = found
                self.indexedFileCount = Set(found.map { $0.filePath }).count
                self.lastIndexedAt = Date()
                self.isIndexing = false
                self.saveToDisk(found)
                self.onIndexingComplete?(found)
            }
        }
    }

    // MARK: - Load / Save

    func loadFromDisk() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([CodeChunk].self, from: data) else { return }
        chunks = decoded
        indexedFileCount = Set(decoded.map { $0.filePath }).count
    }

    private func saveToDisk(_ chunks: [CodeChunk]) {
        guard let data = try? JSONEncoder().encode(chunks) else { return }
        try? FileManager.default.createDirectory(at: indexURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: indexURL, options: .atomic)
    }

    // MARK: - Search

    func search(query: String, limit: Int = 8,
                language: CodeChunk.ChunkLanguage? = nil) -> [CodeChunk] {
        let words = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 }
        guard !words.isEmpty else { return [] }

        var scored: [(CodeChunk, Int)] = []
        for chunk in chunks {
            guard language == nil || chunk.language == language else { continue }
            let haystack = (chunk.content + " " + chunk.summary + " " +
                (chunk.symbolName ?? "") + " " + chunk.filePath).lowercased()
            let hits = words.filter { haystack.contains($0) }.count
            if hits > 0 { scored.append((chunk, hits)) }
        }
        return scored
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { $0.0 }
    }

    func chunks(forFeature featureName: String) -> [CodeChunk] {
        let name = featureName.lowercased()
        return chunks.filter {
            $0.relatedFeatures.contains(where: { $0.lowercased().contains(name) }) ||
            $0.filePath.lowercased().contains(name) ||
            ($0.symbolName?.lowercased().contains(name) ?? false)
        }
    }

    // MARK: - Directory scanner (nonisolated, runs off-actor)

    private static func scanDirectory(_ root: URL) async -> [CodeChunk] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var chunks: [CodeChunk] = []

        for case let fileURL as URL in enumerator {
            // Skip excluded directories
            let components = fileURL.pathComponents
            if components.contains(where: { skippedDirectories.contains($0) }) {
                continue
            }

            let ext = fileURL.pathExtension.lowercased()
            if skippedExtensions.contains(ext) { continue }

            guard let resValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  resValues.isRegularFile == true else { continue }

            let modDate = resValues.contentModificationDate ?? Date()

            switch ext {
            case "swift":
                chunks += parseSwiftFile(fileURL, modDate: modDate)
            case "md", "markdown":
                chunks += parseMarkdownFile(fileURL, modDate: modDate)
            case "json":
                if let chunk = parseJSONFile(fileURL, modDate: modDate) {
                    chunks.append(chunk)
                }
            case "kt", "kts":
                chunks += parseKotlinFile(fileURL, modDate: modDate)
            default:
                break
            }
        }

        return chunks
    }

    // MARK: - Swift parser

    private static func parseSwiftFile(_ url: URL, modDate: Date) -> [CodeChunk] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let lines = content.components(separatedBy: "\n")
        guard lines.count > 0 else { return [] }

        var chunks: [CodeChunk] = []
        var currentSymbol: String? = nil
        var currentStart: Int = 0
        var currentLines: [String] = []
        let path = url.path

        let symbolPattern = #"^\s*((?:public|internal|private|open|fileprivate|final|override|static|class|nonisolated|@MainActor|lazy|mutating|async|@discardableResult|\s)*(?:func|class|struct|enum|protocol|extension|actor|var|let))\s+([\w<>\[\]:,\s\.?]+?)[\s\({<]"#

        let markPattern = #"//\s*MARK:\s*-?\s*(.+)"#

        func flushChunk() {
            guard let sym = currentSymbol, !currentLines.isEmpty else { return }
            let blockContent = currentLines.joined(separator: "\n")
            let endLine = currentStart + currentLines.count - 1
            let language = CodeChunk.ChunkLanguage.swift
            let chunk = CodeChunk(
                id: UUID(),
                filePath: path,
                language: language,
                symbolName: sym,
                content: blockContent,
                summary: buildSwiftSummary(sym, content: blockContent),
                startLine: currentStart,
                endLine: endLine,
                lastModified: modDate,
                relatedFeatures: extractFeatureTags(from: blockContent + " " + path)
            )
            chunks.append(chunk)
        }

        func isSymbolDeclaration(_ line: String) -> String? {
            guard let range = line.range(of: symbolPattern, options: .regularExpression) else { return nil }
            // Extract symbol name from the match
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Simple name extraction: take second token
            let tokens = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            for (i, tok) in tokens.enumerated() where i > 0 {
                let clean = tok.trimmingCharacters(in: CharacterSet(charactersIn: "({<:"))
                if !clean.isEmpty && clean.first?.isLetter == true { return clean }
            }
            _ = range
            return nil
        }

        for (i, line) in lines.enumerated() {
            // MARK headers start new chunks
            if let markMatch = line.range(of: markPattern, options: .regularExpression) {
                flushChunk()
                let markText = String(line[markMatch]).replacingOccurrences(of: "// MARK: - ", with: "")
                    .replacingOccurrences(of: "// MARK: ", with: "")
                    .trimmingCharacters(in: .whitespaces)
                currentSymbol = "[\(markText)]"
                currentStart = i
                currentLines = [line]
                continue
            }

            if let sym = isSymbolDeclaration(line) {
                // Only flush if the current block is substantial
                if currentLines.count >= 3 {
                    flushChunk()
                    currentSymbol = sym
                    currentStart = i
                    currentLines = [line]
                } else {
                    currentLines.append(line)
                    if currentSymbol == nil { currentSymbol = sym; currentStart = i }
                }
            } else {
                if currentSymbol != nil {
                    currentLines.append(line)
                    // Cap block at 80 lines, flush and continue
                    if currentLines.count >= 80 {
                        flushChunk()
                        currentSymbol = nil
                        currentLines = []
                    }
                } else {
                    currentLines.append(line)
                    if currentLines.count >= 20 {
                        // Flush as a file-header chunk
                        currentSymbol = url.deletingPathExtension().lastPathComponent
                        flushChunk()
                        currentSymbol = nil
                        currentLines = []
                    }
                }
            }
        }
        flushChunk()

        // If nothing was chunked, make one whole-file chunk capped at 100 lines
        if chunks.isEmpty {
            let preview = lines.prefix(100).joined(separator: "\n")
            chunks.append(CodeChunk(
                id: UUID(),
                filePath: path,
                language: .swift,
                symbolName: url.deletingPathExtension().lastPathComponent,
                content: preview,
                summary: "Swift file: \(url.lastPathComponent)",
                startLine: 0, endLine: max(0, min(100, lines.count - 1)),
                lastModified: modDate,
                relatedFeatures: extractFeatureTags(from: path)
            ))
        }

        return chunks
    }

    // MARK: - Markdown parser

    private static func parseMarkdownFile(_ url: URL, modDate: Date) -> [CodeChunk] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let lines = content.components(separatedBy: "\n")
        let path = url.path

        var chunks: [CodeChunk] = []
        var sectionTitle: String = url.deletingPathExtension().lastPathComponent
        var sectionStart: Int = 0
        var sectionLines: [String] = []

        func flushSection() {
            guard !sectionLines.isEmpty else { return }
            let body = sectionLines.joined(separator: "\n")
            chunks.append(CodeChunk(
                id: UUID(),
                filePath: path,
                language: .markdown,
                symbolName: sectionTitle,
                content: String(body.prefix(3000)),
                summary: "Markdown section: \(sectionTitle) in \(url.lastPathComponent)",
                startLine: sectionStart,
                endLine: sectionStart + sectionLines.count - 1,
                lastModified: modDate,
                relatedFeatures: extractFeatureTags(from: sectionTitle + " " + path)
            ))
        }

        for (i, line) in lines.enumerated() {
            if line.hasPrefix("## ") || line.hasPrefix("# ") {
                flushSection()
                sectionTitle = line.trimmingCharacters(in: CharacterSet(charactersIn: "# \t"))
                sectionStart = i
                sectionLines = [line]
            } else {
                sectionLines.append(line)
                if sectionLines.count >= 120 {
                    flushSection()
                    sectionLines = []
                    sectionStart = i + 1
                }
            }
        }
        flushSection()
        return chunks
    }

    // MARK: - JSON parser

    private static func parseJSONFile(_ url: URL, modDate: Date) -> CodeChunk? {
        guard let data = try? Data(contentsOf: url),
              data.count < 50_000,
              let content = String(data: data, encoding: .utf8) else { return nil }
        return CodeChunk(
            id: UUID(),
            filePath: url.path,
            language: .json,
            symbolName: url.deletingPathExtension().lastPathComponent,
            content: String(content.prefix(10_000)),
            summary: "JSON config: \(url.lastPathComponent)",
            startLine: 0, endLine: content.components(separatedBy: "\n").count,
            lastModified: modDate,
            relatedFeatures: extractFeatureTags(from: url.path)
        )
    }

    // MARK: - Kotlin parser

    private static func parseKotlinFile(_ url: URL, modDate: Date) -> [CodeChunk] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let lines = content.components(separatedBy: "\n")
        let preview = lines.prefix(80).joined(separator: "\n")
        return [CodeChunk(
            id: UUID(),
            filePath: url.path,
            language: .kotlin,
            symbolName: url.deletingPathExtension().lastPathComponent,
            content: preview,
            summary: "Kotlin file: \(url.lastPathComponent)",
            startLine: 0, endLine: max(0, min(80, lines.count - 1)),
            lastModified: modDate,
            relatedFeatures: extractFeatureTags(from: url.path)
        )]
    }

    // MARK: - Helpers

    private static func buildSwiftSummary(_ symbol: String, content: String) -> String {
        // Extract first comment or // description if present
        for line in content.components(separatedBy: "\n").prefix(4) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("///") || t.hasPrefix("//") {
                let comment = t.dropFirst(t.hasPrefix("///") ? 3 : 2).trimmingCharacters(in: .whitespaces)
                if !comment.isEmpty { return "\(symbol): \(comment)" }
            }
        }
        return "Swift symbol: \(symbol)"
    }

    private static func extractFeatureTags(from text: String) -> [String] {
        let featureKeywords = [
            "HomeAssistant", "Obsidian", "Spotify", "Shopify", "Todoist", "GitHub",
            "Weather", "Calendar", "Brain", "Memory", "Speech", "Vision", "Camera",
            "Timer", "Conversation", "LLM", "TTS", "WakeWord", "Overlay", "Gesture",
            "LocalLearning", "ContextGraph", "ProactivityEngine", "SmartHome"
        ]
        return featureKeywords.filter { text.contains($0) }
    }
}
