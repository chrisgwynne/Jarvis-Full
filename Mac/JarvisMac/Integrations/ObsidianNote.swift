import Foundation

/// A single note parsed from an Obsidian vault.
/// All regex patterns are compiled once as `static let` to avoid per-call cost.
struct ObsidianNote: Identifiable, Hashable {

    // MARK: - Identity

    /// Stable ID: vault-relative path, e.g. "Projects/Jarvis.md"
    let id: String
    /// Display title — filename without the `.md` extension.
    let title: String
    /// Absolute file URL on disk.
    let url: URL
    /// Last modification date from the filesystem.
    let modifiedAt: Date

    // MARK: - Content

    /// Raw file content including frontmatter.
    let rawContent: String
    /// Body text with YAML frontmatter stripped.
    let body: String
    /// First ~200 characters of body — shown in list views.
    var snippet: String {
        String(body.prefix(200)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Metadata

    /// Tags from YAML frontmatter (`tags: [tag1, tag2]`) and inline `#tag`.
    let tags: [String]
    /// Internal `[[wikilink]]` references to other notes.
    let wikilinks: [String]

    // MARK: - Hashable

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: ObsidianNote, rhs: ObsidianNote) -> Bool { lhs.id == rhs.id }
}

// MARK: - Parsing

extension ObsidianNote {

    /// Parse a note from a file URL within the given vault root.
    /// Returns nil if the file cannot be read.
    static func parse(url: URL, vaultRoot: URL) -> ObsidianNote? {
        guard let rawContent = try? String(contentsOf: url, encoding: .utf8),
              let attrs      = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modifiedAt = attrs[.modificationDate] as? Date
        else { return nil }

        // Derive stable vault-relative ID
        let rootPath = vaultRoot.standardized.path
        let filePath = url.standardized.path
        let relPath  = filePath.hasPrefix(rootPath + "/")
            ? String(filePath.dropFirst(rootPath.count + 1))
            : url.lastPathComponent
        let title = url.deletingPathExtension().lastPathComponent

        let (body, fmTags) = stripFrontmatter(from: rawContent)
        let inlineTags     = extractInlineTags(from: body)
        let wikilinks      = extractWikilinks(from: rawContent)
        let allTags        = Array(Set(fmTags + inlineTags)).sorted()

        return ObsidianNote(
            id:          relPath,
            title:       title,
            url:         url,
            modifiedAt:  modifiedAt,
            rawContent:  rawContent,
            body:        body,
            tags:        allTags,
            wikilinks:   wikilinks
        )
    }

    // MARK: - Frontmatter

    private static func stripFrontmatter(from text: String) -> (body: String, tags: [String]) {
        guard text.hasPrefix("---") else { return (text, []) }
        let lines = text.components(separatedBy: "\n")
        guard lines.count > 1 else { return (text, []) }

        var fmLines: [String] = []
        var foundClose = false
        var closeIndex = 1

        for i in 1..<lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t == "---" || t == "..." {
                foundClose  = true
                closeIndex  = i + 1
                break
            }
            fmLines.append(lines[i])
        }
        guard foundClose else { return (text, []) }

        let body = lines[closeIndex...]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (body, parseFrontmatterTags(from: fmLines))
    }

    private static func parseFrontmatterTags(from lines: [String]) -> [String] {
        var tags: [String] = []
        var inList = false

        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.lowercased().hasPrefix("tags:") {
                inList = false
                let rest = t.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix("[") {
                    // Inline: tags: [a, b, c]
                    let inner = rest.dropFirst().prefix(while: { $0 != "]" })
                    tags += inner.split(separator: ",").map {
                        $0.trimmingCharacters(in: .whitespaces
                            .union(CharacterSet(charactersIn: "\"'")))
                    }
                } else if rest.isEmpty {
                    inList = true
                } else {
                    tags.append(rest.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")))
                }
            } else if inList {
                if t.hasPrefix("- ") {
                    let tag = String(t.dropFirst(2))
                        .trimmingCharacters(in: .whitespaces
                            .union(CharacterSet(charactersIn: "\"'#")))
                    if !tag.isEmpty { tags.append(tag) }
                } else if !t.isEmpty {
                    inList = false
                }
            }
        }
        return tags.filter { !$0.isEmpty }
    }

    // MARK: - Inline tags & wikilinks (static cached regex)

    private static let inlineTagRegex: NSRegularExpression? =
        try? NSRegularExpression(pattern: #"(?<![/\w#])#([A-Za-z][A-Za-z0-9_/\-]*)"#)

    private static let wikilinkRegex: NSRegularExpression? =
        try? NSRegularExpression(pattern: #"\[\[([^\|\]]+?)(?:\|[^\]]+?)?\]\]"#)

    private static func extractInlineTags(from text: String) -> [String] {
        guard let regex = inlineTagRegex else { return [] }
        let ns = NSRange(text.startIndex..., in: text)
        return Array(Set(
            regex.matches(in: text, range: ns).compactMap { m -> String? in
                guard let r = Range(m.range(at: 1), in: text) else { return nil }
                return String(text[r])
            }
        ))
    }

    private static func extractWikilinks(from text: String) -> [String] {
        guard let regex = wikilinkRegex else { return [] }
        let ns = NSRange(text.startIndex..., in: text)
        return Array(Set(
            regex.matches(in: text, range: ns).compactMap { m -> String? in
                guard let r = Range(m.range(at: 1), in: text) else { return nil }
                return String(text[r]).trimmingCharacters(in: .whitespaces)
            }
        ))
    }
}
