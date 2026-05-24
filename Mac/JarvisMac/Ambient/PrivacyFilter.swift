import Foundation

// MARK: - PrivacyFilter

/// Determines which apps should be excluded from ambient context capture.
/// Blocked apps receive no screenshot, no OCR, no window title logging —
/// only a `ContextRedactedEvent` is emitted so subscribers know capture
/// was attempted but suppressed.
struct PrivacyFilter: Equatable, Sendable {

    // MARK: - Defaults

    /// Bundle IDs that are always blocked out of the box.
    static let defaultBlockedBundleIDs: Set<String> = [
        // Password managers
        "com.1password.1password",
        "com.1password.1password-helper",
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword-osx-helper",
        "me.meldium.1password-extension",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "com.dashlane.Dashlane",
        "net.macpass.MacPass",
        "com.apple.keychainaccess",
        // Banking / finance
        "com.mint.Mint",
        "com.robinhood.Robinhood",
        // Private / incognito-mode detection is done separately via window title
    ]

    /// App name substrings (case-insensitive) that trigger blocking.
    static let defaultBlockedNameSubstrings: [String] = [
        "keychain",
        "1password",
        "bitwarden",
        "lastpass",
        "dashlane",
    ]

    // MARK: - Instance config

    /// User-configured additional blocked bundle IDs.
    var additionalBlockedBundleIDs: Set<String> = []
    /// User-configured additional blocked app name substrings.
    var additionalBlockedNames: [String] = []

    // MARK: - Check

    func isBlocked(bundleID: String, appName: String, windowTitle: String) -> Bool {
        // Exact bundle ID match
        let allBundleIDs = Self.defaultBlockedBundleIDs.union(additionalBlockedBundleIDs)
        if allBundleIDs.contains(bundleID) { return true }

        // App name substring match
        let nameLow = appName.lowercased()
        let allNames = Self.defaultBlockedNameSubstrings + additionalBlockedNames
        if allNames.contains(where: { nameLow.contains($0.lowercased()) }) { return true }

        // Private browsing: Safari / Chrome / Firefox / Arc incognito windows
        // These often contain "Private" or "Incognito" in the window title.
        let titleLow = windowTitle.lowercased()
        let isBrowser = ["safari", "chrome", "firefox", "arc", "brave", "edge", "opera"]
            .contains(where: { nameLow.contains($0) })
        if isBrowser {
            let privateHints = ["private", "incognito", "inprivate"]
            if privateHints.contains(where: { titleLow.contains($0) }) { return true }
        }

        return false
    }
}
