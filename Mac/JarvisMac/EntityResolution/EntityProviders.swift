import Foundation
import AppKit

// MARK: - MediaEntityProvider

/// Matches against the built-in MediaEntityDatabase (news, streaming, websites).
final class MediaEntityProvider: EntityProvider {
    let providerName = "media"

    private let entries: [MediaEntityDatabase.Entry] = MediaEntityDatabase.all

    func candidates(for spans: [String]) async -> [EntityCandidate] {
        entries.compactMap { entry in
            guard let url = URL(string: entry.url) else { return nil }
            return EntityCandidate(
                entityId: entry.id,
                displayName: entry.displayName,
                entityType: entry.entityType,
                provider: providerName,
                aliases: entry.aliases,
                externalURL: url,
                bundleIdentifier: entry.bundleID,
                baseConfidence: 1.0
            )
        }
    }
}

// MARK: - AppEntityProvider

/// Matches against locally installed macOS applications.
///
/// Reserved overlay nouns are excluded so that Jarvis's own internal overlay
/// vocabulary ("news", "calendar", "camera", …) can never be hijacked by a
/// same-named system app (News.app, Calendar.app, …).  The phrase-store always
/// runs before EntityFirstResolver now (see JarvisController handleTranscript),
/// but this blocklist is a defence-in-depth guard: even if the order ever
/// changes, "show me the news" can never resolve to com.apple.news.
///
/// Apps that the user explicitly names with an "app" qualifier ("open the News
/// app", "launch Apple News") still reach the app launcher because those
/// transcripts produce longer spans that don't match any overlay noun.
final class AppEntityProvider: EntityProvider {
    let providerName = "app"

    /// Single-word nouns that Jarvis uses as internal overlay command vocabulary.
    /// Any installed app whose lowercase display name exactly equals one of these
    /// is excluded from entity resolution so it cannot shadow an overlay intent.
    static let reservedOverlayNouns: Set<String> = [
        // Jarvis overlay names
        "news", "calendar", "camera", "dashboard", "timeline", "memory",
        "chat", "home", "tasks", "brain", "screen", "mail", "notes",
        "music", "messages", "reminders", "photos", "maps", "weather",
        "github", "settings", "diagnostics", "shopify", "obsidian",
        // Common single-word app names that collide with conversation vocabulary
        "contacts", "finder", "safari", "terminal", "preview",
    ]

    private static let cachedApps: [EntityCandidate] = {
        let searchURLs = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
        ]
        var seen = Set<String>()
        var results: [EntityCandidate] = []
        for dir in searchURLs {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.localizedNameKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for appURL in contents where appURL.pathExtension == "app" {
                let name = (try? appURL.resourceValues(forKeys: [.localizedNameKey]).localizedName)
                    ?? appURL.deletingPathExtension().lastPathComponent
                let normalized = name.lowercased()
                guard !seen.contains(normalized) else { continue }
                // Skip apps whose name exactly matches a reserved overlay noun.
                guard !reservedOverlayNouns.contains(normalized) else { continue }
                seen.insert(normalized)
                let bundle = Bundle(url: appURL)
                let bundleID = bundle?.bundleIdentifier
                results.append(EntityCandidate(
                    entityId: "app:\(normalized)",
                    displayName: name,
                    entityType: .app,
                    provider: "app",
                    aliases: [normalized, name.lowercased()],
                    externalURL: appURL,
                    bundleIdentifier: bundleID,
                    baseConfidence: 0.9
                ))
            }
        }
        return results
    }()

    func candidates(for spans: [String]) async -> [EntityCandidate] {
        Self.cachedApps
    }
}

// MARK: - BrowserEntityProvider

/// Known websites and common browser destinations.
final class BrowserEntityProvider: EntityProvider {
    let providerName = "browser"

    private static let known: [EntityCandidate] = [
        EntityCandidate(entityId: "google_search", displayName: "Google", entityType: .website,
                        provider: "browser",
                        aliases: ["google", "google.com", "google search"],
                        externalURL: URL(string: "https://www.google.com"), bundleIdentifier: nil, baseConfidence: 0.9),
        EntityCandidate(entityId: "gmail", displayName: "Gmail", entityType: .website,
                        provider: "browser",
                        aliases: ["gmail", "google mail", "email"],
                        externalURL: URL(string: "https://mail.google.com"), bundleIdentifier: nil, baseConfidence: 0.9),
        EntityCandidate(entityId: "calendar_web", displayName: "Google Calendar", entityType: .website,
                        provider: "browser",
                        aliases: ["google calendar", "gcal"],
                        externalURL: URL(string: "https://calendar.google.com"), bundleIdentifier: nil, baseConfidence: 0.85),
        EntityCandidate(entityId: "drive", displayName: "Google Drive", entityType: .website,
                        provider: "browser",
                        aliases: ["google drive", "drive"],
                        externalURL: URL(string: "https://drive.google.com"), bundleIdentifier: nil, baseConfidence: 0.85),
        EntityCandidate(entityId: "notion", displayName: "Notion", entityType: .website,
                        provider: "browser",
                        aliases: ["notion", "notion.so"],
                        externalURL: URL(string: "https://www.notion.so"), bundleIdentifier: "notion.id", baseConfidence: 0.9),
        EntityCandidate(entityId: "slack", displayName: "Slack", entityType: .website,
                        provider: "browser",
                        aliases: ["slack"],
                        externalURL: URL(string: "https://slack.com"), bundleIdentifier: "com.tinyspeck.slackmacgap", baseConfidence: 0.9),
    ]

    func candidates(for spans: [String]) async -> [EntityCandidate] {
        Self.known
    }
}

// MARK: - HomeAssistantEntityProvider

/// Matches against the HA alias store and entity registry.
@MainActor
final class HomeAssistantEntityProvider: EntityProvider {
    let providerName = "home_assistant"

    private let aliasStore: HomeEntityAliasStore
    private let registry: HAEntityRegistry?

    init(aliasStore: HomeEntityAliasStore, registry: HAEntityRegistry?) {
        self.aliasStore = aliasStore
        self.registry   = registry
    }

    func candidates(for spans: [String]) async -> [EntityCandidate] {
        var results: [EntityCandidate] = []

        // Flatten alias store entries to candidates.
        // Skip camera.* entities — those are routed through the dedicated HA camera
        // phrase commands (with location keywords) and must never win via entity resolution,
        // which would incorrectly route "show me the camera" to an HA camera.
        for entry in aliasStore.aliases {
            guard !entry.entityID.lowercased().hasPrefix("camera.") else { continue }
            let displayName = entry.friendlyName
            results.append(EntityCandidate(
                entityId: entry.entityID,
                displayName: displayName,
                entityType: .haDevice,
                provider: providerName,
                aliases: [entry.friendlyName.lowercased(), entry.entityID.lowercased()],
                externalURL: nil,
                bundleIdentifier: nil,
                baseConfidence: 0.95
            ))
        }

        // Also expose registry entities if available (camera.* excluded, same reason).
        if let reg = registry {
            for entity in reg.entities {
                guard !entity.entityID.lowercased().hasPrefix("camera.") else { continue }
                let name = entity.friendlyName.isEmpty ? entity.entityID : entity.friendlyName
                results.append(EntityCandidate(
                    entityId: entity.entityID,
                    displayName: name,
                    entityType: .haDevice,
                    provider: providerName,
                    aliases: [name.lowercased(), entity.entityID.lowercased()],
                    externalURL: nil,
                    bundleIdentifier: nil,
                    baseConfidence: 0.85
                ))
            }
        }

        return results
    }
}

// MARK: - MemoryEntityProvider

/// Surfaces recently-mentioned entities from RollingDialogueMemory so
/// recent context boosts resolution of anaphor and near-anaphor references.
final class MemoryEntityProvider: EntityProvider {
    let providerName = "memory"

    func candidates(for spans: [String]) async -> [EntityCandidate] {
        await MainActor.run {
            RollingDialogueMemory.shared.activeEntities.compactMap { entity in
                EntityCandidate(
                    entityId: "mem:\(entity.lowercased())",
                    displayName: entity,
                    entityType: .customAlias,
                    provider: providerName,
                    aliases: [entity.lowercased()],
                    externalURL: nil,
                    bundleIdentifier: nil,
                    baseConfidence: 0.75
                )
            }
        }
    }
}

// MARK: - CustomEntityAliasProvider

/// User-taught aliases, persisted across sessions.
/// Separate from LearnedCommandAliasStore — this one maps spoken names to
/// entity IDs (display name → EntityCandidate).
@MainActor
final class CustomEntityAliasProvider: EntityProvider {
    static let shared = CustomEntityAliasProvider()
    let providerName = "custom_alias"

    private var store = CustomEntityAliasStore.shared

    func candidates(for spans: [String]) async -> [EntityCandidate] {
        store.allAliases().map { entry in
            EntityCandidate(
                entityId: "custom:\(entry.entityId)",
                displayName: entry.displayName,
                entityType: entry.entityType,
                provider: providerName,
                aliases: [entry.alias, entry.displayName.lowercased()],
                externalURL: entry.url,
                bundleIdentifier: nil,
                baseConfidence: 1.0
            )
        }
    }

    /// Called when the user corrects a resolution ("no, I meant EuroNews").
    func learn(alias: String, for result: EntityResolutionResult) {
        store.save(CustomEntityAliasStore.AliasEntry(
            alias: alias.lowercased(),
            entityId: result.entity.entityId,
            displayName: result.displayName,
            entityType: result.entityType,
            url: result.externalURL
        ))
    }
}
