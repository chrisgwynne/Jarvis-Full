import Foundation

// MARK: - GitHubLocalRepoIndex
// Shell-based lightweight local repo analysis.
// Does NOT clone repos; analyzes already-cloned local paths.

@MainActor
final class GitHubLocalRepoIndex {
    static let shared = GitHubLocalRepoIndex()

    private(set) var snapshots: [GHLocalRepoSnapshot] = []
    private let fileURL: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
        let dir = support.appendingPathComponent("JarvisMac", isDirectory: true)
        fileURL = dir.appendingPathComponent("local_repo_index.json")
        load()
    }

    // MARK: - Index

    /// Index (or re-index) a local repo path.
    func index(path: String, fullName: String) async throws -> GHLocalRepoSnapshot {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            throw GHError.notFound
        }

        var snap = GHLocalRepoSnapshot(
            path: path,
            fullName: fullName,
            language: nil,
            indexedAt: Date()
        )

        // File count
        snap.fileCount = (try? countFiles(at: url)) ?? 0

        // TODO/FIXME count
        let (todos, fixmes) = await countTodosFixmes(at: path)
        snap.todoCount  = todos
        snap.fixmeCount = fixmes

        // Large files (> 500KB)
        snap.largeFiles = (try? findLargeFiles(at: url)) ?? []

        // Top languages
        snap.topLanguages = (try? detectLanguages(at: url)) ?? [:]

        // Primary language
        snap.language = snap.topLanguages.max(by: { $0.value < $1.value })?.key

        // Last local commit
        let (sha, msg, date) = await latestLocalCommit(at: path)
        snap.lastLocalCommit = msg
        snap.lastLocalCommitDate = date

        // Stale branches (local branches with no upstream / old commits)
        snap.staleLocalBranches = await staleLocalBranches(at: path)

        // Upsert
        if let idx = snapshots.firstIndex(where: { $0.path == path }) {
            snapshots[idx] = snap
        } else {
            snapshots.append(snap)
        }
        save()
        return snap
    }

    func snapshot(for path: String) -> GHLocalRepoSnapshot? {
        snapshots.first { $0.path == path }
    }

    func snapshot(forFullName fullName: String) -> GHLocalRepoSnapshot? {
        snapshots.first { $0.fullName.lowercased() == fullName.lowercased() }
    }

    // MARK: - Shell Helpers (nonisolated so they don't block main actor)

    nonisolated private func countFiles(at url: URL) throws -> Int {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return 0 }
        var count = 0
        for case let fileURL as URL in enumerator {
            if (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                count += 1
            }
        }
        return count
    }

    nonisolated private func countTodosFixmes(at path: String) async -> (Int, Int) {
        let result = await shell("grep -rI --include='*.swift' --include='*.kt' --include='*.py' --include='*.js' --include='*.ts' -c 'TODO\\|FIXME' '\(path)' 2>/dev/null | awk -F: 'BEGIN{t=0;f=0} {t+=$2} END{print t}' && grep -rI --include='*.swift' --include='*.kt' --include='*.py' --include='*.js' --include='*.ts' -c 'FIXME' '\(path)' 2>/dev/null | awk -F: '{s+=$2} END{print s}'")
        let lines = result.components(separatedBy: "\n").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return (lines.first ?? 0, lines.dropFirst().first ?? 0)
    }

    nonisolated private func findLargeFiles(at url: URL) throws -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]) else { return [] }
        var large: [String] = []
        for case let fileURL as URL in enumerator {
            let vals = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if vals?.isRegularFile == true, let size = vals?.fileSize, size > 500_000 {
                large.append(fileURL.lastPathComponent)
            }
        }
        return large
    }

    nonisolated private func detectLanguages(at url: URL) throws -> [String: Int] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]) else { return [:] }
        var counts: [String: Int] = [:]
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            guard !ext.isEmpty,
                  !["png","jpg","gif","pdf","lock","resolved","pbxproj","DS_Store"].contains(ext)
            else { continue }
            counts[ext, default: 0] += 1
        }
        return counts
    }

    nonisolated private func latestLocalCommit(at path: String) async -> (String, String, Date?) {
        let out = await shell("git -C '\(path)' log -1 --format='%H|%s|%aI' 2>/dev/null")
        let parts = out.components(separatedBy: "|")
        let sha   = parts.first ?? ""
        let msg   = parts.dropFirst().first ?? ""
        let dateStr = parts.dropFirst(2).first ?? ""
        let date = ISO8601DateFormatter().date(from: dateStr)
        return (sha, msg, date)
    }

    nonisolated private func staleLocalBranches(at path: String) async -> [String] {
        let out = await shell("git -C '\(path)' branch -v 2>/dev/null")
        let lines = out.components(separatedBy: "\n")
        return lines.filter { $0.contains("[gone]") }.map {
            $0.trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? $0
        }
    }

    nonisolated private func shell(_ command: String) async -> String {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.launchPath = "/bin/bash"
            process.arguments  = ["-c", command]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError  = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            } catch {
                continuation.resume(returning: "")
            }
        }
    }

    // MARK: - Spoken

    func spokenSnapshot(fullName: String) -> String {
        guard let snap = snapshot(forFullName: fullName) else {
            return "No local index for \(fullName.components(separatedBy: "/").last ?? fullName). Try indexing it first."
        }
        let repoShort = fullName.components(separatedBy: "/").last ?? fullName
        var text = "\(repoShort): \(snap.fileCount) files"
        if let lang = snap.language { text += ", primarily \(lang)" }
        if snap.todoCount > 0      { text += ", \(snap.todoCount) TODOs" }
        if snap.fixmeCount > 0     { text += ", \(snap.fixmeCount) FIXMEs" }
        if !snap.largeFiles.isEmpty { text += ", \(snap.largeFiles.count) large files" }
        if !snap.lastLocalCommit.isEmpty { text += ". Latest commit: \(snap.lastLocalCommit)." }
        return text + "."
    }

    // MARK: - Persistence

    private func save() {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(snapshots) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let snaps = try? JSONDecoder().decode([GHLocalRepoSnapshot].self, from: data)
        else { return }
        snapshots = snaps
    }
}
