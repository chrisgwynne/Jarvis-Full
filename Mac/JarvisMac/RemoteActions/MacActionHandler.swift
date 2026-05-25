import AppKit
import Foundation
import OSLog

/// Executes discrete Mac actions triggered by remote.action.request.
/// All methods are safe to call on any thread. Never executes dangerous/destructive
/// actions without requiresConfirmation being explicitly handled.
enum MacActionHandler {

    private static let logger = Logger(subsystem: "com.jarvis.jarvisapp", category: "mac-action")

    // MARK: - Known launchable apps

    private static let appBundleIds: [String: String] = [
        "notes":                 "com.apple.Notes",
        "note":                  "com.apple.Notes",
        "news":                  "com.apple.news",
        "safari":                "com.apple.Safari",
        "finder":                "com.apple.finder",
        "calendar":              "com.apple.iCal",
        "mail":                  "com.apple.Mail",
        "music":                 "com.apple.Music",
        "system settings":       "com.apple.systempreferences",
        "system preferences":    "com.apple.systempreferences",
        "settings":              "com.apple.systempreferences",
        "messages":              "com.apple.MobileSMS",
        "facetime":              "com.apple.FaceTime",
        "maps":                  "com.apple.Maps",
        "photos":                "com.apple.Photos",
        "reminders":             "com.apple.reminders",
        "terminal":              "com.apple.Terminal",
        "xcode":                 "com.apple.dt.Xcode",
        "preview":               "com.apple.Preview",
        "jarvis":                "com.jarvis.jarvisapp",
    ]

    // MARK: - open_app

    @MainActor
    static func openApp(appName: String) async -> RemoteActionResult {
        let key = appName.lowercased().trimmingCharacters(in: .whitespaces)

        // 1. Check known bundle IDs
        if let bundleId = appBundleIds[key] {
            return launch(bundleId: bundleId, displayName: appName)
        }

        // 2. Fuzzy search in installed apps
        let fuzzyMatch = appBundleIds.first { $0.key.contains(key) || key.contains($0.key) }
        if let (_, bundleId) = fuzzyMatch {
            return launch(bundleId: bundleId, displayName: appName)
        }

        // 3. Try NSWorkspace.urlForApplication(withBundleIdentifier:) with name-based search
        if let appUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.\(key)") {
            let opened = NSWorkspace.shared.open(appUrl)
            if opened {
                return RemoteActionResult(success: true, spokenSummary: "Opening \(appName) on the Mac.")
            }
        }

        logger.warning("mac-action: open_app — unknown app '\(appName, privacy: .public)'")
        return RemoteActionResult(
            success: false,
            spokenSummary: "That Mac action is not supported yet.",
            errorCode: "unsupported_app",
            errorMessage: "App '\(appName)' not found"
        )
    }

    @MainActor
    private static func launch(bundleId: String, displayName: String) -> RemoteActionResult {
        if bundleId == "com.jarvis.jarvisapp" {
            return openJarvis()
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: cfg)
            logger.info("mac-action: opened \(bundleId, privacy: .public)")
            return RemoteActionResult(success: true, spokenSummary: "Opening \(displayName) on the Mac.")
        }
        logger.warning("mac-action: app not installed bundleId=\(bundleId, privacy: .public)")
        return RemoteActionResult(
            success: false,
            spokenSummary: "That app doesn't seem to be installed.",
            errorCode: "unsupported_app"
        )
    }

    // MARK: - create_note

    @MainActor
    static func createNote(title: String?, body: String?) async -> RemoteActionResult {
        // Open Notes first
        guard let notesURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Notes") else {
            return RemoteActionResult(
                success: false,
                spokenSummary: "Notes doesn't seem to be installed.",
                errorCode: "unsupported_action"
            )
        }

        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        try? await NSWorkspace.shared.openApplication(at: notesURL, configuration: cfg)

        // If no title/body, just open Notes
        guard title != nil || body != nil else {
            return RemoteActionResult(
                success: true,
                spokenSummary: "Notes is open. What should I call the note?",
                errorCode: "needs_more_info"
            )
        }

        // Try AppleScript to create the note
        let noteTitle = title ?? "Untitled"
        let noteBody = body ?? ""
        let escapedTitle = noteTitle.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedBody = noteBody.replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "Notes"
            activate
            tell account "iCloud"
                make new note with properties {name:"\(escapedTitle)", body:"\(escapedTitle)\\n\(escapedBody)"}
            end tell
        end tell
        """

        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if error == nil {
                logger.info("mac-action: created note '\(noteTitle, privacy: .public)' via AppleScript")
                let summary = title != nil ? "Creating a note called \(noteTitle) on the Mac." : "Creating a note on the Mac."
                return RemoteActionResult(success: true, spokenSummary: summary)
            } else {
                // AppleScript failed — fall back to just opening Notes
                logger.warning("mac-action: AppleScript failed for create_note — Notes opened only")
                return RemoteActionResult(
                    success: true,
                    spokenSummary: "Notes is open. I couldn't create the note automatically — you may need to grant automation permission.",
                    errorCode: "needs_more_info"
                )
            }
        }

        return RemoteActionResult(success: true, spokenSummary: "Notes is open on the Mac.")
    }

    // MARK: - show_camera

    @MainActor
    static func showCamera() -> RemoteActionResult {
        return RemoteActionResult(
            success: false,
            spokenSummary: "That Mac action is not supported yet.",
            errorCode: "unsupported_action",
            errorMessage: "Camera overlay not available in this configuration"
        )
    }

    // MARK: - open_jarvis

    @MainActor
    static func openJarvis() -> RemoteActionResult {
        NSApp.activate(ignoringOtherApps: true)
        // Bring main window to front
        for window in NSApp.windows {
            window.makeKeyAndOrderFront(nil)
            break
        }
        logger.info("mac-action: Jarvis brought to front")
        return RemoteActionResult(success: true, spokenSummary: "Done on the Mac.")
    }
}
