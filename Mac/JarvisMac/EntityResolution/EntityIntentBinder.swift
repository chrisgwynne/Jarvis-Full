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
        if entity.entityType == .app {
            let spoken = "Opening \(entity.displayName)."
            if let bid = entity.bundleIdentifier {
                return (.openApp(name: bid), spoken)
            }
            return (.openApp(name: entity.displayName), spoken)
        }

        // ── HA device ───────────────────────────────────────────────────────
        if entity.entityType == .haDevice {
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
        if [.newsChannel, .youtubeChannel, .stream, .website, .browserBookmark, .mediaSource].contains(entity.entityType) {
            if let url = entity.externalURL {
                let verb: String
                switch action {
                case .play, .navigate: verb = "Opening"
                default:               verb = "Opening"
                }
                return (.openURL(url), "\(verb) \(entity.displayName).")
            }
            // App bundle fallback
            if let bid = entity.bundleIdentifier {
                return (.openApp(name: bid), "Opening \(entity.displayName).")
            }
        }

        // ── Generic: URL or app fallback ────────────────────────────────────
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
