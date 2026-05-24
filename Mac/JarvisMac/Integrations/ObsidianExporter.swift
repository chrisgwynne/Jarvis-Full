import Foundation

/// Writes daily log notes to an Obsidian vault under `Jarvis/YYYY-MM-DD.md`.
///
/// Responsibilities:
/// - Atomic writes (temp-file → rename) to prevent corruption.
/// - Append-only: never overwrites existing content; inserts new bullets
///   under the correct `## Section` header.
/// - In-memory deduplication: the same content string is never written twice
///   to the same section on the same calendar day.
/// - Queues exports when the vault path is unavailable, flushing them later
///   via `flushPending(vaultPath:)`.
///
/// This class intentionally has no knowledge of `ObsidianVaultService`
/// (which handles reading and indexing). The two cooperate without coupling.
@MainActor
final class ObsidianExporter {

    // MARK: - Types

    struct ExportItem: Codable {
        var section: Section
        var content: String
        var date:    Date
    }

    enum Section: String, Codable, CaseIterable {
        case conversations    = "Conversations"
        case projectProgress  = "Project Progress"
        case decisions        = "Decisions"
        case ideas            = "Ideas"
        case bugs             = "Bugs / Issues"
        case memoryCandidates = "Memory Candidates"
    }

    // MARK: - State

    /// `true` when there are items waiting for a vault path to become available.
    private(set) var hasPendingExports: Bool = false

    private var pendingItems: [ExportItem] = []

    /// Dedup key format: `"YYYY-MM-DD:Section:contentHashValue"`
    private var writtenToday: Set<String> = []
    private var lastDedupDate: String     = ""

    // MARK: - Public API

    /// Export a single bullet to today's daily note.
    ///
    /// - Parameters:
    ///   - content:   The text to write (written as a markdown bullet).
    ///   - section:   Which `## Section` header to append under.
    ///   - vaultPath: Absolute path to the Obsidian vault root. When `nil`
    ///                the item is queued for later.
    func export(content: String, section: Section, vaultPath: String?) async {
        let dateStr = todayString()

        // Reset dedup set if the calendar day rolled over
        if lastDedupDate != dateStr {
            writtenToday  = []
            lastDedupDate = dateStr
        }

        // Skip exact duplicates within the same day
        let dedupKey = "\(dateStr):\(section.rawValue):\(content.hashValue)"
        guard !writtenToday.contains(dedupKey) else { return }
        writtenToday.insert(dedupKey)

        guard let vaultPath else {
            pendingItems.append(ExportItem(section: section, content: content, date: Date()))
            hasPendingExports = true
            return
        }

        await writeToVault(content: content, section: section, vaultPath: vaultPath, dateStr: dateStr)
    }

    /// Convenience: map a `MemoryCandidate` to the most appropriate section
    /// and export it.
    func exportMemoryCandidate(_ candidate: MemoryCandidate, vaultPath: String?) async {
        let section: Section
        switch candidate.type {
        case .projectProgress:  section = .projectProgress
        case .projectDecision:  section = .decisions
        case .idea:             section = .ideas
        case .bugReport:        section = .bugs
        default:                section = .memoryCandidates
        }
        let bullet = "**\(candidate.title)**: \(candidate.summary)"
        await export(content: bullet, section: section, vaultPath: vaultPath)
    }

    /// Write all queued items now that a vault path is available.
    ///
    /// Clears the pending queue regardless of individual write outcomes so
    /// that a single bad note cannot block future exports.
    func flushPending(vaultPath: String) async {
        let items = pendingItems
        pendingItems      = []
        hasPendingExports = false
        let dateStr = todayString()
        for item in items {
            await writeToVault(
                content:   item.content,
                section:   item.section,
                vaultPath: vaultPath,
                dateStr:   dateStr
            )
        }
    }

    // MARK: - Write implementation

    private func writeToVault(
        content:   String,
        section:   Section,
        vaultPath: String,
        dateStr:   String
    ) async {
        let jarvisDir = (vaultPath as NSString).appendingPathComponent("Jarvis")
        let filePath  = (jarvisDir as NSString).appendingPathComponent("\(dateStr).md")

        // Ensure the Jarvis sub-directory exists
        try? FileManager.default.createDirectory(
            atPath: jarvisDir,
            withIntermediateDirectories: true
        )

        // Read existing content (empty string → new file)
        var body = (try? String(contentsOfFile: filePath, encoding: .utf8)) ?? ""

        // Write the file header once on creation
        if body.isEmpty {
            body = "# Jarvis Log — \(dateStr)\n"
        }

        let sectionHeader = "## \(section.rawValue)"
        let bullet        = "- \(content)"

        if body.contains(sectionHeader) {
            // Insert the bullet immediately before the next `## ` heading
            // (or at the very end of the file if this is the last section).
            if let headerRange = body.range(of: sectionHeader) {
                let tail = body[headerRange.upperBound...]
                if let nextSectionRange = tail.range(of: "\n## ") {
                    // Insert just before the next section header
                    let insertIdx = body.index(
                        headerRange.upperBound,
                        offsetBy: tail.distance(
                            from: tail.startIndex,
                            to: nextSectionRange.lowerBound
                        )
                    )
                    body.insert(contentsOf: "\n\(bullet)", at: insertIdx)
                } else {
                    // No later section — append to end
                    body += "\n\(bullet)"
                }
            }
        } else {
            // Section doesn't exist yet — append it
            body += "\n\n\(sectionHeader)\n\(bullet)"
        }

        // Atomic write: write to a temp path then rename over the target
        let tempPath = filePath + ".tmp"
        do {
            try body.write(toFile: tempPath, atomically: false, encoding: .utf8)
            _ = try FileManager.default.replaceItemAt(
                URL(fileURLWithPath: filePath),
                withItemAt: URL(fileURLWithPath: tempPath)
            )
        } catch {
            // replaceItemAt fails when the destination doesn't exist yet;
            // fall back to a direct atomic write.
            try? body.write(toFile: filePath, atomically: true, encoding: .utf8)
            // Clean up temp file if it survived
            try? FileManager.default.removeItem(atPath: tempPath)
        }
    }

    // MARK: - Helpers

    private func todayString() -> String {
        let fmt        = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: Date())
    }
}
