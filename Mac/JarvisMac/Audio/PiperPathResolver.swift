import Foundation

// MARK: - PiperPathResolution

/// Result of resolving a single Piper path.
struct PiperPathResolution {

    enum Status: Equatable {
        case empty                                   // input was nil / blank
        case resolved(String)                        // canonical absolute path, all checks passed
        case directory(String)                       // path is a directory, not a file
        case notExecutable(String)                   // file exists but lacks executable bit
        case notFound(String)                        // normalised path does not exist
        case wrongExtension(String, expected: String)// file exists but wrong extension
    }

    let rawPath: String
    let resolvedPath: String?    // non-nil whenever status == .resolved or .notExecutable
    let status: Status

    var isValid: Bool {
        if case .resolved = status { return true }
        return false
    }

    /// Human-readable description for UI and logs.
    var statusLabel: String {
        switch status {
        case .empty:                              return "No path configured."
        case .resolved(let p):                   return "Ready: \(p)"
        case .directory(let p):                  return "Path is a directory, not a file: \(p)"
        case .notExecutable(let p):              return "File exists but is not executable: \(p)"
        case .notFound(let p):                   return "File not found: \(p)"
        case .wrongExtension(let p, let ext):    return "Expected \(ext) file: \(p)"
        }
    }

    /// Short single-line error for inline Settings display.
    var errorDescription: String? {
        if case .resolved = status { return nil }
        return statusLabel
    }
}

// MARK: - PiperPathResolver

/// Canonical path resolver for all Piper TTS file references.
///
/// Handles:
///   - ~ expansion and file:// prefix removal
///   - Quoted paths (shell-style single or double quotes)
///   - Symlink resolution
///   - Directory-to-executable probing (piper/piper/piper layout)
///   - Executable bit checking vs. mere existence
///   - .onnx / .json extension validation
///
/// Settings validation AND runtime synthesis both call this resolver so they
/// are always consistent.
enum PiperPathResolver {

    // MARK: - Executable

    /// Resolves the Piper CLI executable path.
    ///
    /// If the supplied path is a directory, probes common sub-paths:
    ///   selected/piper
    ///   selected/piper/piper
    ///   selected/bin/piper
    static func resolveExecutable(_ rawPath: String) -> PiperPathResolution {
        let norm = normalise(rawPath)
        guard !norm.isEmpty else {
            return .init(rawPath: rawPath, resolvedPath: nil, status: .empty)
        }

        // Try the path itself first (covers the common correct case).
        if let hit = probeExecutable(norm, raw: rawPath) { return hit }

        // If it's a directory, probe inside.
        if isDirectory(norm) {
            let probes = [
                (norm as NSString).appendingPathComponent("piper"),
                (norm as NSString).appendingPathComponent("piper/piper"),
                (norm as NSString).appendingPathComponent("bin/piper"),
            ]
            for probe in probes {
                if let hit = probeExecutable(probe, raw: rawPath) { return hit }
            }
            return .init(rawPath: rawPath, resolvedPath: nil, status: .directory(norm))
        }

        return .init(rawPath: rawPath, resolvedPath: nil, status: .notFound(norm))
    }

    // MARK: - Model (.onnx)

    static func resolveModel(_ rawPath: String) -> PiperPathResolution {
        resolveDataFile(rawPath, expectedSuffix: ".onnx")
    }

    // MARK: - Config (.onnx.json / .json)

    static func resolveConfig(_ rawPath: String) -> PiperPathResolution {
        resolveDataFile(rawPath, expectedSuffix: ".json")
    }

    // MARK: - Normalisation (public — used by UI for display)

    /// Expands ~, strips file:// prefix, removes shell quoting, standardises separators.
    static func normalise(_ rawPath: String) -> String {
        var p = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return "" }

        // Strip file:// scheme.
        if p.hasPrefix("file://") {
            p = String(p.dropFirst(7))
            p = p.removingPercentEncoding ?? p
        }

        // Strip enclosing shell quotes.
        if p.count >= 2 {
            let first = p.first!, last = p.last!
            if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                p = String(p.dropFirst().dropLast())
            }
        }

        // Expand tilde.
        if p.hasPrefix("~") {
            p = (p as NSString).expandingTildeInPath
        }

        // Standardise (removes //, resolves ..).
        p = (p as NSString).standardizingPath

        // Remove trailing slash unless root.
        if p.count > 1 && p.hasSuffix("/") { p = String(p.dropLast()) }

        return p
    }

    // MARK: - Debug helpers

    /// Output of `file <path>` — shows Mach-O architecture etc.
    static func fileTypeInfo(_ path: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/file")
        p.arguments = [path]
        let out = Pipe(); let err = Pipe()
        p.standardOutput = out; p.standardError = err
        do {
            try p.run(); p.waitUntilExit()
            return String(data: out.fileHandleForReading.readDataToEndOfFile(),
                          encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch { return nil }
    }

    /// Shell-safe copy-pasteable command for manual testing.
    static func debugCommand(executablePath: String,
                             modelPath: String,
                             configPath: String,
                             outputPath: String = "/tmp/jarvis-piper-test.wav") -> String {
        func q(_ s: String) -> String {
            "'\(s.replacingOccurrences(of: "'", with: "'\\''"))'"
        }
        var lines = [
            "echo 'Jarvis online.' | \(q(executablePath)) \\",
            "  --model \(q(modelPath)) \\",
        ]
        if !configPath.isEmpty {
            lines.append("  --config \(q(configPath)) \\")
        }
        lines.append("  --output_file \(q(outputPath))")
        return lines.joined(separator: "\n") + "\n\nafplay \(q(outputPath))"
    }

    // MARK: - Private helpers

    private static func probeExecutable(_ path: String, raw: String) -> PiperPathResolution? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { return nil }

        let canonical = (path as NSString).resolvingSymlinksInPath
        guard fm.isExecutableFile(atPath: canonical) else {
            return .init(rawPath: raw, resolvedPath: canonical, status: .notExecutable(canonical))
        }
        return .init(rawPath: raw, resolvedPath: canonical, status: .resolved(canonical))
    }

    private static func resolveDataFile(_ rawPath: String, expectedSuffix: String) -> PiperPathResolution {
        let norm = normalise(rawPath)
        guard !norm.isEmpty else {
            return .init(rawPath: rawPath, resolvedPath: nil, status: .empty)
        }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: norm, isDirectory: &isDir) else {
            return .init(rawPath: rawPath, resolvedPath: nil, status: .notFound(norm))
        }
        if isDir.boolValue {
            return .init(rawPath: rawPath, resolvedPath: nil, status: .directory(norm))
        }
        let canonical = (norm as NSString).resolvingSymlinksInPath
        guard canonical.lowercased().hasSuffix(expectedSuffix.lowercased()) else {
            return .init(rawPath: rawPath, resolvedPath: canonical,
                         status: .wrongExtension(canonical, expected: expectedSuffix))
        }
        return .init(rawPath: rawPath, resolvedPath: canonical, status: .resolved(canonical))
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return isDir.boolValue
    }
}
