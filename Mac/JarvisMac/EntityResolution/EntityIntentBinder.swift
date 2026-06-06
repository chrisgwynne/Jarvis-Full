import Foundation

// MARK: - EntityIntentBinder

/// Maps an EntityResolutionResult (entity + action) to a concrete Intent.
///
/// Binding precedence:
///   1. Custom alias with explicit intent stored
///   2. entityType + action matrix
///   3. Fallback: openURL if externalURL is present, else openApp if bundleID
@MainActor
enum EntityIntentBinder {

    // MARK: - Bind

    /// Returns (intent, spokenPrefix) or nil if no binding found.
    /// The caller should speak the prefix before executing the intent.
    static func bind(_ result: EntityResolutionResult) -> (intent: Intent, spokenPrefix: String)? {
        let entity = result.entity
        let action = result.action

        // ── App entity ──────────────────────────────────────────────────────
        // Require an explicit open/launch verb — prevents ambient speech or
        // news audio containing an app name from silently launching it.
        if entity.entityType == .app {
            guard action != .unknown else { return nil }
            let spoken = "Opening \(entity.displayName)."
            if let bid = entity.bundleIdentifier {
                return (.openApp(name: bid), spoken)
            }
            return (.openApp(name: entity.displayName), spoken)
        }

        // ── HA device ───────────────────────────────────────────────────────
        if entity.entityType == .haDevice {
            // Camera entities should open the camera overlay, not turn on.
            if entity.entityId.lowercased().hasPrefix("camera.") {
                return (.homeShowCameraOverlay(entity: entity.displayName),
                        "Opening \(entity.displayName) camera.")
            }
            switch action {
            case .control, .open:
                return (.homeTurnOn(entity: entity.entityId), "Turning on \(entity.displayName).")
            case .show:
                return (.homeTurnOn(entity: entity.entityId), "Showing \(entity.displayName).")
            default:
                return (.homeTurnOn(entity: entity.entityId), "Controlling \(entity.displayName).")
            }
        }

        // ── HA room / area ──────────────────────────────────────────────────
        if entity.entityType == .haRoom {
            return (.showHomeOverlay, "Showing \(entity.displayName) devices.")
        }

        // ── GitHub repo ──────────────────────────────────────────────────────
        if entity.entityType == .githubRepo {
            if let url = entity.externalURL {
                return (.openURL(url), "Opening \(entity.displayName) on GitHub.")
            }
            return (.showGitHubOverlay, "Opening GitHub.")
        }

        // ── Apple Note ───────────────────────────────────────────────────────
        if entity.entityType == .appleNote {
            return (.openNotes, "Opening \(entity.displayName) in Notes.")
        }

        // ── File / Folder ────────────────────────────────────────────────────
        if entity.entityType == .file || entity.entityType == .folder {
            if let url = entity.externalURL {
                return (.openURL(url), "Opening \(entity.displayName).")
            }
        }

        // ── Contact ─────────────────────────────────────────────────────────
        if entity.entityType == .contact {
            switch action {
            case .call:
                return (.callContact(name: entity.displayName), "Calling \(entity.displayName).")
            case .send:
                return (.callContact(name: entity.displayName), "Messaging \(entity.displayName).")
            default:
                return (.callContact(name: entity.displayName), "Opening \(entity.displayName).")
            }
        }

        // ── News channel, streaming, website, browser bookmark ─────────────
        // Require an explicit navigation/play verb. A fuzzy entity match alone
        // (score ≥ 0.72) is not enough — the user must have said something like
        // "open", "play", "go to", etc. This prevents news audio or ambient
        // speech that happens to contain a website name from triggering a URL open.
        if [.newsChannel, .youtubeChannel, .stream, .website, .browserBookmark, .mediaSource].contains(entity.entityType) {
            guard action != .unknown else { return nil }
            if let url = entity.externalURL {
                return (.openURL(url), "Opening \(entity.displayName).")
            }
            // App bundle fallback
            if let bid = entity.bundleIdentifier {
                return (.openApp(name: bid), "Opening \(entity.displayName).")
            }
        }

        // ── Generic: URL or app fallback ────────────────────────────────────
        // Same guard: never open a URL or app without an explicit intent verb.
        guard action != .unknown else { return nil }
        if let url = entity.externalURL {
            return (.openURL(url), "Opening \(entity.displayName).")
        }
        if let bid = entity.bundleIdentifier {
            return (.openApp(name: bid), "Opening \(entity.displayName).")
        }

        return nil
    }

    // MARK: - Clarification text

    /// Produces a spoken clarification when two candidates are close.
    static func clarificationText(
        for result: EntityResolutionResult,
        against competitor: EntityCandidate
    ) -> String {
        "Did you mean \(result.displayName) or \(competitor.displayName)?"
    }
}
