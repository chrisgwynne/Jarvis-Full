import Foundation
import Contacts

// MARK: - ContactEntityProvider

/// Matches the user's macOS Contacts (CNContactStore).
/// Results are cached for 5 minutes; falls back to empty if access is not granted.
@MainActor
final class ContactEntityProvider: EntityProvider {

    let providerName = "contacts"

    private var cachedCandidates: [EntityCandidate] = []
    private var lastFetch: Date?
    private let cacheInterval: TimeInterval = 300  // 5 min

    func candidates(for spans: [String]) async -> [EntityCandidate] {
        if let last = lastFetch,
           Date().timeIntervalSince(last) < cacheInterval,
           !cachedCandidates.isEmpty {
            return cachedCandidates
        }
        let fresh = await Self.fetchSync()
        cachedCandidates = fresh
        lastFetch = Date()
        return fresh
    }

    /// Synchronous CNContactStore enumeration wrapped in a continuation so it
    /// runs on a global utility thread (not the main actor).
    private static func fetchSync() async -> [EntityCandidate] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
                    continuation.resume(returning: [])
                    return
                }
                let store = CNContactStore()
                let keys: [CNKeyDescriptor] = [
                    CNContactGivenNameKey  as CNKeyDescriptor,
                    CNContactFamilyNameKey as CNKeyDescriptor,
                    CNContactNicknameKey   as CNKeyDescriptor,
                ]
                let request = CNContactFetchRequest(keysToFetch: keys)
                request.sortOrder = .givenName
                var results: [EntityCandidate] = []
                try? store.enumerateContacts(with: request) { contact, _ in
                    let given  = contact.givenName
                    let family = contact.familyName
                    let nick   = contact.nickname
                    let full   = [given, family].filter { !$0.isEmpty }.joined(separator: " ")
                    guard !full.isEmpty else { return }
                    var aliases: [String] = [full.lowercased()]
                    if !given.isEmpty  { aliases.append(given.lowercased()) }
                    if !family.isEmpty { aliases.append(family.lowercased()) }
                    if !nick.isEmpty   { aliases.append(nick.lowercased()) }
                    let slug = full.lowercased().replacingOccurrences(of: " ", with: "_")
                    let entityId = "contact:\(slug)"
                    results.append(EntityCandidate(
                        entityId: entityId,
                        displayName: full,
                        entityType: .contact,
                        provider: "contacts",
                        aliases: aliases,
                        externalURL: nil,
                        bundleIdentifier: nil,
                        baseConfidence: 0.90
                    ))
                }
                continuation.resume(returning: results)
            }
        }
    }
}

// MARK: - GitHubEntityProvider

/// Builds entity candidates from the user's GitHub notification history.
/// Each unique repository becomes a `.githubRepo` candidate so "open my
/// auth service repo" resolves to the right GitHub URL.
final class GitHubEntityProvider: EntityProvider {

    let providerName = "github_repos"

    /// Injected from JarvisController — returns the latest fetched notifications.
    var getNotifications: () -> [GHNotification]

    init(getNotifications: @escaping () -> [GHNotification]) {
        self.getNotifications = getNotifications
    }

    func candidates(for spans: [String]) async -> [EntityCandidate] {
        let notifications = getNotifications()
        // Deduplicate by repo full_name
        var seen = Set<String>()
        var results: [EntityCandidate] = []
        for note in notifications {
            let fullName = note.repository.full_name  // e.g. "owner/repo-name"
            guard seen.insert(fullName).inserted else { continue }
            let parts    = fullName.components(separatedBy: "/")
            let repoName = parts.last ?? fullName
            let owner    = parts.count > 1 ? parts[0] : ""
            var aliases  = [
                repoName.lowercased(),
                fullName.lowercased(),
                repoName.lowercased().replacingOccurrences(of: "-", with: " "),
                repoName.lowercased().replacingOccurrences(of: "_", with: " "),
            ]
            if !owner.isEmpty { aliases.append(owner.lowercased() + " " + repoName.lowercased()) }
            let url = URL(string: "https://github.com/\(fullName)")
            results.append(EntityCandidate(
                entityId: "github:\(fullName.lowercased())",
                displayName: repoName,
                entityType: .githubRepo,
                provider: providerName,
                aliases: aliases,
                externalURL: url,
                bundleIdentifier: nil,
                baseConfidence: 0.85
            ))
        }
        return results
    }
}

// MARK: - FileEntityProvider

/// Surfaces recently-observed files from the EntityMemoryGraph so voice
/// references like "that swift file" or "the config file" resolve correctly.
@MainActor
final class FileEntityProvider: EntityProvider {

    let providerName = "files"

    func candidates(for spans: [String]) async -> [EntityCandidate] {
        EntityMemoryGraph.shared.byKind(.file, limit: 50).compactMap { node in
            let name = node.canonicalName
            let ext  = (name as NSString).pathExtension
            var aliases = [
                name.lowercased(),
                (name as NSString).lastPathComponent.lowercased(),
            ]
            if !ext.isEmpty {
                let noExt = (name as NSString).deletingPathExtension
                aliases.append(noExt.lowercased())
            }
            // Build a file URL from the canonicalName if it looks like a path
            let url: URL? = name.hasPrefix("/") ? URL(fileURLWithPath: name) : nil
            return EntityCandidate(
                entityId: "file:\(name.lowercased())",
                displayName: (name as NSString).lastPathComponent,
                entityType: .file,
                provider: providerName,
                aliases: aliases,
                externalURL: url,
                bundleIdentifier: nil,
                baseConfidence: 0.80
            )
        }
    }
}

// MARK: - NoteEntityProvider

/// Surfaces Apple Notes and Obsidian notes from the ContextGraph so users can
/// say "open my meeting notes" and resolve to a real note entity.
@MainActor
final class NoteEntityProvider: EntityProvider {

    let providerName = "notes"

    func candidates(for spans: [String]) async -> [EntityCandidate] {
        let graph      = ContextGraph.shared
        let appleNodes    = graph.nodes(ofType: .appleNote)
        let obsidianNodes = graph.nodes(ofType: .obsidianNote)

        return (appleNodes + obsidianNodes).map { node in
            let name = node.title
            let slug = name.lowercased().replacingOccurrences(of: " ", with: "_")
            var aliases = [name.lowercased()]
            let words = name.lowercased()
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { $0.count > 3 }
            aliases += words
            let entityType: EntityType = node.type == .appleNote ? .appleNote : .customAlias
            return EntityCandidate(
                entityId: "note:\(slug)",
                displayName: name,
                entityType: entityType,
                provider: providerName,
                aliases: aliases,
                externalURL: nil,
                bundleIdentifier: nil,
                baseConfidence: 0.82
            )
        }
    }
}

// MARK: - HAAreaEntityProvider

/// Exposes distinct Home Assistant room/area names as `.haRoom` entities.
/// "Show the living room" or "what's in the kitchen" resolves to the home overlay.
@MainActor
final class HAAreaEntityProvider: EntityProvider {

    let providerName = "ha_areas"

    private weak var registry: HAEntityRegistry?

    init(registry: HAEntityRegistry?) {
        self.registry = registry
    }

    func candidates(for spans: [String]) async -> [EntityCandidate] {
        guard let reg = registry else { return [] }
        // Collect distinct, non-empty area strings
        var seenAreas = Set<String>()
        var results: [EntityCandidate] = []
        for entity in reg.entities {
            guard let area = entity.area, !area.isEmpty else { continue }
            let lower = area.lowercased()
            guard seenAreas.insert(lower).inserted else { continue }
            // Humanise "living_room" → "Living Room"
            let humanised = area
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
            let aliases = [
                lower,
                area.replacingOccurrences(of: "_", with: " ").lowercased(),
                humanised.lowercased(),
            ]
            results.append(EntityCandidate(
                entityId: "ha_area:\(lower)",
                displayName: humanised,
                entityType: .haRoom,
                provider: providerName,
                aliases: aliases,
                externalURL: nil,
                bundleIdentifier: nil,
                baseConfidence: 0.88
            ))
        }
        return results
    }
}
