import Foundation

// MARK: - AppContext

/// Structured context extracted by an AppContextAdapter from raw window/OCR data.
struct AppContext: Equatable, Sendable {
    var activeFile: String?
    var repoName: String?
    var branchName: String?
    var projectName: String?
    var activeURL: URL?
    var terminalCommand: String?
    var buildStatus: String?      // "building" | "succeeded" | "failed" | nil
    var selectedText: String?
    var confidence: Double         // 0–1

    static let empty = AppContext(confidence: 0)
}

// MARK: - AppContextAdapter

/// Protocol for per-app context extractors. Each adapter understands the
/// window title and OCR text patterns for a specific app.
protocol AppContextAdapter {
    var bundleID: String { get }
    var appName: String { get }
    func extractContext(windowTitle: String, ocrLines: [String]) -> AppContext
}

// MARK: - CursorAdapter

struct CursorAdapter: AppContextAdapter {
    let bundleID = "com.todesktop.230313mzl4w4u92"
    let appName = "Cursor"

    func extractContext(windowTitle: String, ocrLines: [String]) -> AppContext {
        var ctx = AppContext(confidence: 0.5)

        // Window title: "filename.swift — FolderName" or "filename.swift — repo (branch)"
        let parts = windowTitle.components(separatedBy: " — ")
        if let file = parts.first?.trimmingCharacters(in: .whitespaces), !file.isEmpty {
            ctx.activeFile = file
        }
        if parts.count >= 2 {
            let second = parts[1]
            // Extract repo and branch if present: "repo (branch)"
            if let parenRange = second.range(of: "(") {
                ctx.repoName = String(second[second.startIndex..<parenRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                let after = String(second[parenRange.upperBound...])
                ctx.branchName = after.replacingOccurrences(of: ")", with: "").trimmingCharacters(in: .whitespaces)
            } else {
                ctx.repoName = second.trimmingCharacters(in: .whitespaces)
            }
        }

        // OCR: look for build status indicators
        for line in ocrLines {
            let low = line.lowercased()
            if low.contains("build succeeded") { ctx.buildStatus = "succeeded"; break }
            if low.contains("build failed") || low.contains("compile error") { ctx.buildStatus = "failed"; break }
            if low.contains("building") || low.contains("compiling") { ctx.buildStatus = "building"; break }
        }

        if ctx.activeFile != nil { ctx.confidence = 0.85 }
        return ctx
    }
}

// MARK: - XcodeAdapter

struct XcodeAdapter: AppContextAdapter {
    let bundleID = "com.apple.dt.Xcode"
    let appName = "Xcode"

    func extractContext(windowTitle: String, ocrLines: [String]) -> AppContext {
        var ctx = AppContext(confidence: 0.5)

        // Window title: "filename.swift" or "ProjectName — /path/to/project.xcodeproj"
        let parts = windowTitle.components(separatedBy: " — ")
        if let file = parts.first?.trimmingCharacters(in: .whitespaces), !file.isEmpty {
            ctx.activeFile = file
        }
        if parts.count >= 2 {
            let path = parts[1]
            let components = path.components(separatedBy: "/")
            if let projEntry = components.last(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) {
                ctx.projectName = projEntry
                    .replacingOccurrences(of: ".xcodeproj", with: "")
                    .replacingOccurrences(of: ".xcworkspace", with: "")
            }
        }

        // OCR: build status
        for line in ocrLines {
            let low = line.lowercased()
            if low.contains("build succeeded") { ctx.buildStatus = "succeeded"; break }
            if low.contains("build failed") { ctx.buildStatus = "failed"; break }
            if low.contains("running") || low.contains("building") { ctx.buildStatus = "building"; break }
        }

        if ctx.activeFile != nil { ctx.confidence = 0.85 }
        return ctx
    }
}

// MARK: - TerminalAdapter

struct TerminalAdapter: AppContextAdapter {
    let bundleID = "com.apple.Terminal"
    let appName = "Terminal"

    func extractContext(windowTitle: String, ocrLines: [String]) -> AppContext {
        var ctx = AppContext(confidence: 0.4)
        // Window title is often the current working directory or command
        ctx.terminalCommand = windowTitle.trimmingCharacters(in: .whitespaces).nonEmpty
        // Check last OCR line for prompt + command
        if let lastLine = ocrLines.last?.trimmingCharacters(in: .whitespaces), !lastLine.isEmpty {
            ctx.terminalCommand = lastLine
            ctx.confidence = 0.6
        }
        return ctx
    }
}

// MARK: - SafariAdapter

struct SafariAdapter: AppContextAdapter {
    let bundleID = "com.apple.Safari"
    let appName = "Safari"

    func extractContext(windowTitle: String, ocrLines: [String]) -> AppContext {
        var ctx = AppContext(confidence: 0.5)
        // Title is usually the page title; look for a URL in OCR
        ctx.projectName = windowTitle.trimmingCharacters(in: .whitespaces).nonEmpty

        for line in ocrLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://") {
                ctx.activeURL = URL(string: trimmed)
                ctx.confidence = 0.8
                break
            }
        }
        return ctx
    }
}

// MARK: - AppContextAdapterRegistry

/// Looks up the right adapter for a bundleID.
struct AppContextAdapterRegistry {
    static let shared = AppContextAdapterRegistry()

    private let adapters: [String: any AppContextAdapter] = {
        let all: [any AppContextAdapter] = [
            CursorAdapter(),
            XcodeAdapter(),
            TerminalAdapter(),
            SafariAdapter(),
        ]
        return Dictionary(uniqueKeysWithValues: all.map { ($0.bundleID, $0) })
    }()

    func adapter(for bundleID: String) -> (any AppContextAdapter)? {
        adapters[bundleID]
    }

    func extract(bundleID: String, windowTitle: String, ocrLines: [String]) -> AppContext {
        adapter(for: bundleID)?.extractContext(windowTitle: windowTitle, ocrLines: ocrLines) ?? .empty
    }
}

// MARK: - String helper

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
