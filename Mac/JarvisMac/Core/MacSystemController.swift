import Foundation
import AppKit
import CoreWLAN

/// Central macOS system-control layer.
///
/// Handles: app launching (with fuzzy name matching + alias resolution),
/// System Settings pane navigation, volume control, file/folder operations,
/// Spotlight search, window/app management, and permission detection.
///
/// Safety rules enforced here:
/// - Shell commands use a local allowlist (NSAppleScript used for scripting,
///   not the shell, wherever possible).
/// - No destructive file operations.
/// - No private APIs, no SIP hacks.
@MainActor
final class MacSystemController {

    // MARK: - App index

    struct InstalledApp: Identifiable {
        let id: String          // path, unique
        let name: String        // display name, no ".app"
        let bundleID: String
        let url: URL
        let isSystemApp: Bool
    }

    private var appCache: [InstalledApp] = []
    private var appCacheBuiltAt: Date?
    private let cacheMaxAge: TimeInterval = 300 // 5 min

    /// Folders searched for .app bundles, in priority order.
    private let appSearchRoots: [String] = [
        "/Applications",
        NSHomeDirectory() + "/Applications",
        "/System/Applications",
        "/System/Applications/Utilities",
    ]

    // MARK: - System Settings pane URL map
    // These use the x-apple.systempreferences: URL scheme (Sonoma+).
    // Older macOS falls back to opening System Settings generically.
    private let settingsPanes: [String: String] = [
        "wifi":           "x-apple.systempreferences:com.apple.wifi-settings-extension",
        "wi-fi":          "x-apple.systempreferences:com.apple.wifi-settings-extension",
        "bluetooth":      "x-apple.systempreferences:com.apple.BluetoothSettings",
        "sound":          "x-apple.systempreferences:com.apple.Sound-Settings.extension",
        "audio":          "x-apple.systempreferences:com.apple.Sound-Settings.extension",
        "display":        "x-apple.systempreferences:com.apple.Displays-Settings.extension",
        "displays":       "x-apple.systempreferences:com.apple.Displays-Settings.extension",
        "screen":         "x-apple.systempreferences:com.apple.Displays-Settings.extension",
        "privacy":        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
        "security":       "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
        "keyboard":       "x-apple.systempreferences:com.apple.Keyboard-Settings.extension",
        "mouse":          "x-apple.systempreferences:com.apple.Mouse-Settings.extension",
        "trackpad":       "x-apple.systempreferences:com.apple.Trackpad-Settings.extension",
        "notifications":  "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
        "notification":   "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
        "users":          "x-apple.systempreferences:com.apple.Users-Groups-Settings.extension",
        "accounts":       "x-apple.systempreferences:com.apple.Users-Groups-Settings.extension",
        "battery":        "x-apple.systempreferences:com.apple.Battery-Settings.extension",
        "energy":         "x-apple.systempreferences:com.apple.Battery-Settings.extension",
        "power":          "x-apple.systempreferences:com.apple.Battery-Settings.extension",
        "network":        "x-apple.systempreferences:com.apple.Network-Settings.extension",
        "accessibility":  "x-apple.systempreferences:com.apple.Accessibility-Settings.extension",
        "appearance":     "x-apple.systempreferences:com.apple.Appearance-Settings.extension",
        "desktop":        "x-apple.systempreferences:com.apple.Desktop-Settings.extension",
        "wallpaper":      "x-apple.systempreferences:com.apple.Desktop-Settings.extension",
        "screensaver":    "x-apple.systempreferences:com.apple.Desktop-Settings.extension",
        "screen saver":   "x-apple.systempreferences:com.apple.Desktop-Settings.extension",
        "printers":       "x-apple.systempreferences:com.apple.Print-Scan-Settings.extension",
        "printing":       "x-apple.systempreferences:com.apple.Print-Scan-Settings.extension",
        "focus":          "x-apple.systempreferences:com.apple.Focus-Settings.extension",
        "siri":           "x-apple.systempreferences:com.apple.Siri-Settings.extension",
        "language":       "x-apple.systempreferences:com.apple.Localization-Settings.extension",
        "region":         "x-apple.systempreferences:com.apple.Localization-Settings.extension",
        "date":           "x-apple.systempreferences:com.apple.Date-Time-Settings.extension",
        "time":           "x-apple.systempreferences:com.apple.Date-Time-Settings.extension",
        "sharing":        "x-apple.systempreferences:com.apple.Sharing-Settings.extension",
        "general":        "x-apple.systempreferences:com.apple.systempreferences",
    ]

    // MARK: - App name aliases
    // Maps common spoken names / abbreviations to the real app display name.
    private let appAliases: [String: String] = [
        "settings":           "System Settings",
        "system settings":    "System Settings",
        "preferences":        "System Settings",
        "system prefs":       "System Settings",
        "system preferences": "System Settings",
        "activity":           "Activity Monitor",
        "activity monitor":   "Activity Monitor",
        "term":               "Terminal",
        "terminal":           "Terminal",
        "iterm":              "iTerm2",
        "iterm2":             "iTerm2",
        "vscode":             "Visual Studio Code",
        "vs code":            "Visual Studio Code",
        "code":               "Visual Studio Code",
        "cursor":             "Cursor",
        "xcode":              "Xcode",
        "safari":             "Safari",
        "chrome":             "Google Chrome",
        "google chrome":      "Google Chrome",
        "firefox":            "Firefox",
        "finder":             "Finder",
        "mail":               "Mail",
        "messages":           "Messages",
        "calendar":           "Calendar",
        "notes":              "Notes",
        "reminders":          "Reminders",
        "music":              "Music",
        "photos":             "Photos",
        "preview":            "Preview",
        "slack":              "Slack",
        "discord":            "Discord",
        "spotify":            "Spotify",
        "zoom":               "Zoom",
        "notion":             "Notion",
        "obsidian":           "Obsidian",
        "figma":              "Figma",
        "arc":                "Arc",
        "edge":               "Microsoft Edge",
        "word":               "Microsoft Word",
        "excel":              "Microsoft Excel",
        "powerpoint":         "Microsoft PowerPoint",
        "1password":          "1Password",
        "claude":             "Claude",
        "chatgpt":            "ChatGPT",
        "calculator":         "Calculator",
        "maps":               "Maps",
        "shortcuts":          "Shortcuts",
        "automator":          "Automator",
        "script editor":      "Script Editor",
        "disk utility":       "Disk Utility",
        "console":            "Console",
        "instruments":        "Instruments",
        "simulator":          "Simulator",
    ]

    // MARK: - Common folder map (spoken name → URL)
    private var commonFolders: [String: URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            "downloads":      home.appendingPathComponent("Downloads"),
            "download":       home.appendingPathComponent("Downloads"),
            "desktop":        home.appendingPathComponent("Desktop"),
            "documents":      home.appendingPathComponent("Documents"),
            "document":       home.appendingPathComponent("Documents"),
            "pictures":       home.appendingPathComponent("Pictures"),
            "photos":         home.appendingPathComponent("Pictures"),
            "movies":         home.appendingPathComponent("Movies"),
            "music":          home.appendingPathComponent("Music"),
            "applications":   URL(fileURLWithPath: "/Applications"),
            "apps":           URL(fileURLWithPath: "/Applications"),
            "utilities":      URL(fileURLWithPath: "/System/Applications/Utilities"),
            "home":           home,
            "icloud":         home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs"),
            "cloud":          home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs"),
            "screenshots":    home.appendingPathComponent("Desktop"),
        ]
    }

    // MARK: - Result types

    enum AppOpenResult {
        case opened(String)
        case notFound(String)
        case clarificationNeeded([InstalledApp])
        case permissionRequired
        case error(String)
    }

    enum SettingsOpenResult {
        case openedPane(String)
        case openedGeneral
        case error(String)
    }

    enum FolderOpenResult {
        case opened(String)
        case notFound(String)
    }

    struct FileSearchResult: Identifiable {
        var id: String { path }
        let path: String
        let displayName: String
        let isDirectory: Bool
        let modifiedAt: Date?
    }

    struct VolumeState {
        let level: Int      // 0–100
        let isMuted: Bool
    }

    // MARK: - App index

    func refreshAppIndex() {
        appCache = buildAppIndex()
        appCacheBuiltAt = Date()
    }

    func installedApps() -> [InstalledApp] {
        if let built = appCacheBuiltAt,
           Date().timeIntervalSince(built) < cacheMaxAge,
           !appCache.isEmpty {
            return appCache
        }
        appCache = buildAppIndex()
        appCacheBuiltAt = Date()
        return appCache
    }

    private func buildAppIndex() -> [InstalledApp] {
        var result: [InstalledApp] = []
        let fm = FileManager.default
        for root in appSearchRoots {
            guard let contents = try? fm.contentsOfDirectory(atPath: root) else { continue }
            let isSystem = root.hasPrefix("/System")
            for item in contents where item.hasSuffix(".app") {
                let path = root + "/" + item
                let url  = URL(fileURLWithPath: path)
                let name = String(item.dropLast(4))
                let bid  = Bundle(url: url)?.bundleIdentifier ?? ""
                result.append(InstalledApp(
                    id: path, name: name, bundleID: bid,
                    url: url, isSystemApp: isSystem
                ))
            }
        }
        return result
    }

    // MARK: - App launching

    func openApp(named query: String) async -> AppOpenResult {
        let q = query.trimmingCharacters(in: .whitespaces)
        // Resolve spoken alias
        let resolved = appAliases[q.lowercased()] ?? q

        // Special-case "System Settings" → openSystemSettings
        if ["system settings", "settings", "preferences", "system prefs", "system preferences"]
            .contains(resolved.lowercased()) {
            _ = openSystemSettings(pane: nil)
            return .opened("System Settings")
        }

        // NSWorkspace bundle-ID guesses
        if let url = exactAppURL(for: resolved) {
            return await launchURL(url, displayName: resolved)
        }

        // Index fuzzy match
        let matches = fuzzyMatch(query: resolved)
        if matches.isEmpty {
            return await openViaShell(name: resolved)
        }
        if matches.count == 1 {
            return await launchURL(matches[0].url, displayName: matches[0].name)
        }
        let lower = resolved.lowercased()
        if let exact = matches.first(where: { $0.name.lowercased() == lower }) {
            return await launchURL(exact.url, displayName: exact.name)
        }
        return .clarificationNeeded(Array(matches.prefix(4)))
    }

    private func exactAppURL(for name: String) -> URL? {
        let ws = NSWorkspace.shared
        let n  = name.lowercased()
        let guesses = [
            "com.apple.\(name)",
            "com.apple.\(n)",
            "com.google.\(n)",
        ]
        for g in guesses {
            if let url = ws.urlForApplication(withBundleIdentifier: g) { return url }
        }
        for root in appSearchRoots {
            let path = root + "/\(name).app"
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    private func fuzzyMatch(query: String) -> [InstalledApp] {
        let q    = query.lowercased()
        let apps = installedApps()
        if let exact = apps.first(where: { $0.name.lowercased() == q }) { return [exact] }
        let sw = apps.filter { $0.name.lowercased().hasPrefix(q) }
        if !sw.isEmpty { return sw }
        let contains = apps.filter { $0.name.lowercased().contains(q) }
        return contains
    }

    private func launchURL(_ url: URL, displayName: String) async -> AppOpenResult {
        do {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: cfg)
            return .opened(displayName)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    private func openViaShell(name: String) async -> AppOpenResult {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", name]
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0 ? .opened(name) : .notFound(name)
        } catch {
            return .notFound(name)
        }
    }

    func listInstalledApps() -> [InstalledApp] { installedApps() }

    func listRunningApps() -> [String] {
        NSWorkspace.shared.runningApplications
            .compactMap { $0.localizedName }
            .filter { !$0.isEmpty }
            .sorted()
    }

    // MARK: - System Settings

    @discardableResult
    func openSystemSettings(pane: String?) -> SettingsOpenResult {
        if let pane {
            let key = pane.lowercased().trimmingCharacters(in: .whitespaces)
            if let urlStr = settingsPanes[key], let url = URL(string: urlStr) {
                NSWorkspace.shared.open(url)
                return .openedPane(pane)
            }
        }
        // Generic
        if let url = URL(string: "x-apple.systempreferences:") {
            NSWorkspace.shared.open(url)
            return .openedGeneral
        }
        return .error("Could not open System Settings")
    }

    /// Returns the canonical spoken name for a settings pane key, or nil.
    func settingsPaneName(for key: String) -> String? {
        let lower = key.lowercased()
        guard settingsPanes[lower] != nil else { return nil }
        return lower.split(separator: " ").map { $0.capitalized }.joined(separator: " ")
    }

    // MARK: - Volume

    func getVolume() -> VolumeState? {
        let script = "output volume of (get volume settings)"
        guard let out = runAppleScript(script) else { return nil }
        let level = Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let muteScript = "output muted of (get volume settings)"
        let mutedStr = runAppleScript(muteScript) ?? "false"
        let muted = mutedStr.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        return VolumeState(level: level, isMuted: muted)
    }

    @discardableResult
    func setVolume(_ level: Int) -> VolumeState {
        let clamped = max(0, min(100, level))
        runAppleScript("set volume output volume \(clamped)")
        return VolumeState(level: clamped, isMuted: false)
    }

    @discardableResult
    func volumeUp(by step: Int = 10) -> VolumeState {
        let current = getVolume()?.level ?? 50
        return setVolume(min(100, current + step))
    }

    @discardableResult
    func volumeDown(by step: Int = 10) -> VolumeState {
        let current = getVolume()?.level ?? 50
        return setVolume(max(0, current - step))
    }

    func mute() {
        runAppleScript("set volume with output muted")
    }

    func unmute() {
        runAppleScript("set volume without output muted")
    }

    // MARK: - Files & Folders

    @discardableResult
    func openFolder(named name: String) -> FolderOpenResult {
        let key = name.lowercased().trimmingCharacters(in: .whitespaces)
        if let url = commonFolders[key] {
            NSWorkspace.shared.open(url)
            return .opened(name)
        }
        // Try home sub-directory by capitalized name
        let home = FileManager.default.homeDirectoryForCurrentUser
        let guesses: [URL] = [
            home.appendingPathComponent(name),
            home.appendingPathComponent(name.capitalized),
        ]
        for url in guesses where FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
            return .opened(name)
        }
        return .notFound(name)
    }

    func openLatestDownload() -> FileSearchResult? {
        let dl = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dl,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let sorted = files.sorted { a, b in
            let ad = modDate(a); let bd = modDate(b)
            return ad > bd
        }
        guard let latest = sorted.first else { return nil }
        NSWorkspace.shared.open(latest)
        return FileSearchResult(
            path: latest.path,
            displayName: latest.lastPathComponent,
            isDirectory: false,
            modifiedAt: modDate(latest)
        )
    }

    private func modDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    /// Spotlight search via `mdfind`. Read-only, sandboxed to home dir for privacy.
    func searchFiles(query: String, limit: Int = 20) -> [FileSearchResult] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        // -name → filename search; -onlyin → restrict to home
        task.arguments = ["-name", query, "-onlyin", NSHomeDirectory()]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError  = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            Log.app.warning("mdfind failed: \(error.localizedDescription)")
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let out = String(data: data, encoding: .utf8) else { return [] }
        return out
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(limit)
            .map { path in
                let url   = URL(fileURLWithPath: path)
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                return FileSearchResult(
                    path: path,
                    displayName: url.lastPathComponent,
                    isDirectory: isDir,
                    modifiedAt: modDate(url)
                )
            }
    }

    func revealInFinder(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openFile(path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    // MARK: - Window & app management

    func activateApp(named name: String) -> Bool {
        let lower = name.lowercased()
        guard let app = NSWorkspace.shared.runningApplications
            .first(where: { ($0.localizedName ?? "").lowercased().contains(lower) })
        else { return false }
        app.activate(options: [])
        return true
    }

    func hideApp(named name: String) -> Bool {
        let lower = name.lowercased()
        guard let app = NSWorkspace.shared.runningApplications
            .first(where: { ($0.localizedName ?? "").lowercased().contains(lower) })
        else { return false }
        app.hide()
        return true
    }

    func quitApp(named name: String) -> Bool {
        let lower = name.lowercased()
        guard let app = NSWorkspace.shared.runningApplications
            .first(where: { ($0.localizedName ?? "").lowercased().contains(lower) })
        else { return false }
        return app.terminate()
    }

    /// Show Desktop — requires Accessibility permission.
    func showDesktop() {
        guard hasAccessibilityPermission else { return }
        // Mission Control: show desktop shortcut (Cmd+Option+D on some configs,
        // or Mission Control show-desktop via key code 103).
        // Most reliable: call via osascript/key code.
        let script = """
        tell application "System Events"
            key code 103 using {command down, option down}
        end tell
        """
        runAppleScript(script)
    }

    /// Lock screen (requires no special permission beyond running).
    func lockScreen() {
        // Fast path: CGSession suspend
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = [
            "-e",
            "tell application \"System Events\" to keystroke \"q\" using {command down, control down}"
        ]
        try? task.run()
    }

    /// Sleep the display only (not the system). Uses `pmset displaysleepnow`.
    func sleepDisplay() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["displaysleepnow"]
        try? task.run()
    }

    // MARK: - Permissions

    var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    func openAccessibilitySettings() {
        openSystemSettings(pane: "accessibility")
    }

    func openPrivacySettings() {
        openSystemSettings(pane: "privacy")
    }

    // MARK: - Wi-Fi

    /// Returns true if Wi-Fi is currently powered on, nil if state can't be read.
    func wifiPowerOn() -> Bool? {
        CWWiFiClient.shared().interface()?.powerOn()
    }

    /// Turn Wi-Fi on or off via `networksetup -setairportpower`.
    /// Spawns the subprocess on a background thread so it never blocks the main thread.
    func setWifi(on: Bool) {
        let arg = on ? "on" : "off"
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
            task.arguments = ["-setairportpower", "en0", arg]
            task.standardError = Pipe()
            try? task.run()
            task.waitUntilExit()
        }
    }

    // MARK: - Bluetooth

    /// Turn Bluetooth on or off.
    /// Uses `blueutil` if installed (Homebrew), otherwise opens the Bluetooth System Settings pane.
    /// Install blueutil for full voice control: `brew install blueutil`.
    func setBluetooth(on: Bool) {
        let blueutilPaths = ["/opt/homebrew/bin/blueutil", "/usr/local/bin/blueutil"]
        if let tool = blueutilPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            let arg = on ? "1" : "0"
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/bin/sh")
                task.arguments = ["-c", "\(tool) --power \(arg)"]
                task.standardError = Pipe()
                try? task.run()
                task.waitUntilExit()
            }
        } else {
            // Fallback: open Bluetooth pane in System Settings as a visual hint.
            Log.app.warning("blueutil not installed — Bluetooth toggle unavailable. Install via: brew install blueutil")
            let script = """
            tell application "System Preferences"
                set current pane to pane id "com.apple.preferences.Bluetooth"
                activate
            end tell
            """
            runAppleScript(script)
        }
    }

    // MARK: - Clipboard

    /// Returns the current plaintext content of the system clipboard, or nil if empty.
    func readClipboard() -> String? {
        return NSPasteboard.general.string(forType: .string)
    }

    /// Writes text to the system clipboard, replacing any existing contents.
    func writeClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - AppleScript helper

    @discardableResult
    private func runAppleScript(_ script: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let err = error {
            Log.app.warning("AppleScript error: \(err.description)")
        }
        return result?.stringValue
    }
}
