import Foundation
import Observation

/// Persistent, user-editable store of `CommandDefinition` records.
///
/// Follows the `ResponseTemplateStore` pattern:
/// - Loads from `~/Library/Application Support/JarvisMac/commands.json`
/// - Seeds from `CommandPhraseDefaults.all` on first launch
/// - Backs up corrupt JSON before re-seeding
/// - Exposes the full definition list as an `@Observable` property so
///   SwiftUI views re-render automatically when any phrase changes.
@Observable
@MainActor
final class CommandPhraseStore {

    // MARK: - Published state

    /// Full sorted list — always kept in category + displayName order.
    private(set) var definitions: [CommandDefinition] = []

    // MARK: - Private helpers

    private let fileURL: URL = {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("JarvisMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir,
                                                  withIntermediateDirectories: true)
        return dir.appendingPathComponent("commands.json")
    }()

    private var backupURL: URL {
        fileURL.deletingPathExtension()
            .appendingPathExtension("json.bak")
    }

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Init

    init() {
        load()
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            seed()
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            definitions = try decoder.decode([CommandDefinition].self, from: data)
            mergeNewDefaults()   // add any commands that shipped after install
        } catch {
            // Corrupt file — preserve it as a backup and re-seed
            try? FileManager.default.moveItem(at: fileURL, to: backupURL)
            seed()
        }
    }

    func save() {
        do {
            let data = try encoder.encode(definitions)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Non-fatal — will retry on next mutation
        }
    }

    // MARK: - Seeding

    private func seed() {
        definitions = CommandPhraseDefaults.all
        save()
    }

    /// Adds any `CommandDefinition` IDs in the current defaults that are not
    /// already present in the loaded store (handles app updates that ship new
    /// commands without wiping user-edited phrases on existing commands).
    ///
    /// Also merges NEW default phrases into existing commands so that
    /// phrases added in later sprints are automatically available on upgrade.
    /// User-added custom phrases are never removed — only default ones that
    /// the user hasn't disabled are injected if not already present.
    private func mergeNewDefaults() {
        let existingIds = Set(definitions.map(\.id))
        let defaults = CommandPhraseDefaults.all

        // Step 1: add completely new commands
        let newDefs = defaults.filter { !existingIds.contains($0.id) }
        var didChange = !newDefs.isEmpty
        if didChange {
            definitions.append(contentsOf: newDefs)
        }

        // Step 2: merge new phrases into existing commands
        for defaultDef in defaults {
            guard let idx = definitions.firstIndex(where: { $0.id == defaultDef.id }) else { continue }
            let existingNormalized = Set(definitions[idx].phrases.map { $0.normalizedPhrase })
            let newPhrases = defaultDef.phrases.filter {
                !existingNormalized.contains($0.normalizedPhrase)
            }
            if !newPhrases.isEmpty {
                definitions[idx].phrases.append(contentsOf: newPhrases)
                didChange = true
            }
        }

        // Step 3: refresh normalizedPhrase for every stored phrase using the
        // current TranscriptNormalizer.  If the normalizer pipeline changed
        // between sprints (e.g. new contractions, new filler words) the
        // persisted normalizedPhrase values may no longer match freshly-
        // normalised incoming transcripts, causing silent routing failures.
        for idx in definitions.indices {
            for phraseIdx in definitions[idx].phrases.indices {
                let fresh = TranscriptNormalizer.normalize(
                    definitions[idx].phrases[phraseIdx].phrase)
                if definitions[idx].phrases[phraseIdx].normalizedPhrase != fresh {
                    definitions[idx].phrases[phraseIdx].normalizedPhrase = fresh
                    definitions[idx].phrases[phraseIdx].updatedAt = Date()
                    didChange = true
                }
            }
        }

        // Step 4: propagate matchType changes from defaults to stored phrases.
        //
        // Phrases that shipped as `.exact` and were later widened to `.contains`
        // in CommandPhraseDefaults need the stored matchType updated too.
        // Without this, existing user stores keep the old exact-only semantics
        // and fail to match when STT introduces even one extra word.
        //
        // Only widen (exact→contains, exact→startsWith) — never narrow.
        // User-added phrases (no matching default) are left untouched.
        let widenableOrder: [PhraseMatchType: Int] = [
            .exact: 0, .startsWith: 1, .contains: 2, .fuzzy: 3, .regex: 4
        ]
        for defaultDef in defaults {
            guard let idx = definitions.firstIndex(where: { $0.id == defaultDef.id }) else { continue }
            // Build a lookup from normalizedPhrase → default matchType.
            // Two defaults can share the same normalizedPhrase (e.g. "show news"
            // and "show the news" both normalize to "show news").  Using
            // uniquingKeysWith keeps the most-permissive matchType so that the
            // widening logic below promotes stored phrases as broadly as possible.
            let defaultMatchTypes: [String: PhraseMatchType] = Dictionary(
                defaultDef.phrases.map { ($0.normalizedPhrase, $0.matchType) },
                uniquingKeysWith: { a, b in
                    let rank = widenableOrder
                    return (rank[a] ?? 0) >= (rank[b] ?? 0) ? a : b  // keep more permissive
                }
            )
            for phraseIdx in definitions[idx].phrases.indices {
                let norm = definitions[idx].phrases[phraseIdx].normalizedPhrase
                guard let defaultType = defaultMatchTypes[norm] else { continue }
                let storedType = definitions[idx].phrases[phraseIdx].matchType
                // Only change if the default is more permissive than stored.
                let storedRank   = widenableOrder[storedType]   ?? 0
                let defaultRank  = widenableOrder[defaultType]  ?? 0
                guard defaultRank > storedRank else { continue }
                definitions[idx].phrases[phraseIdx].matchType  = defaultType
                definitions[idx].phrases[phraseIdx].updatedAt  = Date()
                didChange = true
            }
        }

        // Step 5: remove phrases that were moved to a more-specific command.
        //
        // HA-named-location phrases (e.g. "show front door camera") were erroneously
        // included in `focus_camera` (surveillance system) and must be removed so they
        // fall through to `show_ha_camera` → homeShowCameraOverlay instead.
        let focusCameraConflicts: Set<String> = [
            "show front door camera", "show driveway camera",
            "show backyard camera",   "show office camera",
        ]
        if let idx = definitions.firstIndex(where: { $0.id == "focus_camera" }) {
            let before = definitions[idx].phrases.count
            definitions[idx].phrases.removeAll { focusCameraConflicts.contains($0.phrase) }
            if definitions[idx].phrases.count != before { didChange = true }
        }

        // Step 6: prune bare generic camera phrases from HA camera commands.
        //
        // "show camera", "show the camera", "open camera", etc. were previously
        // listed as .startsWith matches in `show_ha_camera` / `home_show_camera`
        // at .high priority, causing "show me the camera" (normalised → "show camera")
        // to route to HA instead of the Mac webcam overlay. These bare phrases now
        // belong exclusively to `show_camera`. Remove them from any persisted HA
        // camera command stores so existing users get the corrected routing.
        let haCameraCommandsToClean: Set<String> = ["show_ha_camera", "home_show_camera"]
        let bareCameraPhrasesToRemove: Set<String> = [
            "show camera", "open camera", "show the camera", "open the camera",
            "pull up the camera", "bring up the camera",
        ]
        for id in haCameraCommandsToClean {
            if let idx = definitions.firstIndex(where: { $0.id == id }) {
                let before = definitions[idx].phrases.count
                definitions[idx].phrases.removeAll {
                    bareCameraPhrasesToRemove.contains($0.phrase)
                    || bareCameraPhrasesToRemove.contains($0.normalizedPhrase)
                }
                if definitions[idx].phrases.count != before { didChange = true }
            }
        }

        guard didChange else { return }
        sort()
        save()
    }

    // MARK: - Lookup

    func definition(for commandId: String) -> CommandDefinition? {
        definitions.first { $0.id == commandId }
    }

    func definitions(in category: CommandCategory) -> [CommandDefinition] {
        definitions.filter { $0.category == category }
    }

    // MARK: - Phrase mutations

    /// Appends a new phrase (in raw spoken form) to the given command.
    /// - Returns `true` if the command was found and the phrase was added.
    @discardableResult
    func addPhrase(_ text: String,
                   to commandId: String,
                   matchType: PhraseMatchType = .exact,
                   priority: Int = 0) -> Bool {
        guard let idx = index(of: commandId) else { return false }
        definitions[idx].addPhrase(text, matchType: matchType, priority: priority)
        save()
        return true
    }

    func removePhrase(id phraseId: UUID, from commandId: String) {
        guard let idx = index(of: commandId) else { return }
        definitions[idx].removePhrase(id: phraseId)
        save()
    }

    func updatePhrase(_ updated: CommandPhrase, in commandId: String) {
        guard let idx = index(of: commandId) else { return }
        definitions[idx].updatePhrase(updated)
        save()
    }

    // MARK: - Definition mutations

    func setEnabled(_ enabled: Bool, for commandId: String) {
        guard let idx = index(of: commandId) else { return }
        definitions[idx].enabled = enabled
        save()
    }

    // MARK: - Reset

    /// Restores a single command's phrases to the factory defaults while
    /// keeping the user's `enabled` toggle.
    func reset(commandId: String) {
        guard let idx = index(of: commandId),
              let defaultDef = CommandPhraseDefaults.all.first(where: { $0.id == commandId })
        else { return }
        let wasEnabled = definitions[idx].enabled
        definitions[idx] = defaultDef
        definitions[idx].enabled = wasEnabled
        save()
    }

    /// Restores all commands to factory defaults.
    func resetAll() {
        seed()
    }

    // MARK: - Import / Export

    func exportData() -> Data? {
        try? encoder.encode(definitions)
    }

    /// - Throws: `DecodingError` or `CocoaError` on bad data.
    func importData(_ data: Data) throws {
        let imported = try decoder.decode([CommandDefinition].self, from: data)
        definitions = imported
        sort()
        save()
    }

    // MARK: - Private helpers

    private func index(of commandId: String) -> Int? {
        definitions.firstIndex { $0.id == commandId }
    }

    private func sort() {
        definitions.sort {
            if $0.category.rawValue != $1.category.rawValue {
                return $0.category.rawValue < $1.category.rawValue
            }
            return $0.displayName < $1.displayName
        }
    }
}
