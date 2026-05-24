import Foundation
import AppKit

/// Phase-1 set of macOS actions. Future phases extend this with browser
/// control, Shortcuts, Accessibility API, clipboard, files, window mgmt.
@MainActor
final class MacActionExecutor {

    /// Hard-coded allowlist for `runAllowlistedShell`. Adding new entries is
    /// a deliberate code change — never grow this from user input.
    private let shellAllowlist: Set<String> = [
        "/usr/bin/open",
        "/usr/bin/say",
        "/usr/bin/pmset"
    ]

    /// Open an installed application by its display name (e.g. "Safari").
    /// Uses NSWorkspace's URL-based API which is the modern, sandbox-aware path.
    func openApp(named name: String) async throws {
        let workspace = NSWorkspace.shared
        // NSWorkspace.urlForApplication(withBundleIdentifier:) only works with
        // bundle ids, so try a couple of strategies for a friendly name.
        if let url = appURL(forName: name) {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            _ = try await workspace.openApplication(at: url, configuration: cfg)
            return
        }
        // Fall back to /usr/bin/open which understands "open -a 'Safari'".
        try runAllowlistedShell(executable: "/usr/bin/open", arguments: ["-a", name])
    }

    private func appURL(forName name: String) -> URL? {
        let workspace = NSWorkspace.shared
        // Try a guess at the bundle id first (works for Safari → com.apple.Safari).
        let candidates = [
            "com.apple.\(name)",
            "com.google.\(name)"
        ]
        for cand in candidates {
            if let url = workspace.urlForApplication(withBundleIdentifier: cand) {
                return url
            }
        }
        // Search /Applications for an exact .app match.
        let apps = ["/Applications/\(name).app", "/System/Applications/\(name).app"]
        for path in apps {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Open any URL in the user's default browser.
    func openURL(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Phase-1 placeholder — captures a screen rect via `screencapture` to a
    /// temp file. Future phases will use CGWindowListCreateImage / ScreenCaptureKit.
    @discardableResult
    func captureScreenshotPlaceholder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("jarvis-screenshot-\(Int(Date().timeIntervalSince1970)).png")
        try runAllowlistedShell(executable: "/usr/bin/open",
                                arguments: ["-R", url.path]) // no-op safe — real impl is Phase 2
        return url
    }

    /// Run a tightly-allowlisted shell command. Throws if the executable
    /// path is not in `shellAllowlist`.
    func runAllowlistedShell(executable: String, arguments: [String]) throws {
        guard shellAllowlist.contains(executable) else {
            throw JarvisError.invalidPayload("Executable not allowlisted: \(executable)")
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        try task.run()
    }
}
