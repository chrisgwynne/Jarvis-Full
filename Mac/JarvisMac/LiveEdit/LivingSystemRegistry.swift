import Foundation
import Observation

// MARK: - LivingSystemRegistry

/// The registry of editable runtime layers. Holds a `LivingSystem` descriptor
/// per registered id and is the single source of truth that the `LiveEditEngine`
/// mutates and the LLM context builder reads from.
///
/// Most systems are backed by stores that already hot-reload from disk
/// (`PersonalityFileStore`, `HeartbeatStore`); the rest are backed by registry-
/// owned `LiveDocStore`s. Either way, a write is visible to the very next read
/// (and therefore the next LLM response) with no restart.
@Observable
@MainActor
final class LivingSystemRegistry {

    static let shared = LivingSystemRegistry()

    private(set) var systems: [LivingSystemID: LivingSystem] = [:]
    private var docStores: [LivingSystemID: LiveDocStore] = [:]
    private(set) var configured = false

    /// The most recently changed system — observable so SwiftUI surfaces refresh.
    var lastChangedID: LivingSystemID?
    var lastChangedAt: Date?

    init() {}

    // MARK: - Registration

    func register(_ system: LivingSystem) {
        systems[system.id] = system
    }

    func system(_ id: LivingSystemID) -> LivingSystem? { systems[id] }

    func all() -> [LivingSystem] {
        LivingSystemID.allCases.compactMap { systems[$0] }
    }

    func docStore(_ id: LivingSystemID) -> LiveDocStore? { docStores[id] }

    func noteChange(_ id: LivingSystemID) {
        lastChangedID = id
        lastChangedAt = Date()
    }

    // MARK: - Configure (wires the real stores)

    /// Registers every living system against its backing store. Idempotent.
    func configure(personality: PersonalityFileStore) {
        guard !configured else { return }
        configured = true

        // ── PersonalityFileStore-backed text systems ──────────────────────────
        // These are already injected into the system prompt by
        // PersonalityContextBuilder, so injectsContext = false (no duplication).
        registerPersonalityFile(.soul,           fileID: "soul",
                                validator: LiveEditValidators.soul,        personality: personality)
        registerPersonalityFile(.identity,       fileID: "identity",
                                validator: LiveEditValidators.identity,    personality: personality)
        registerPersonalityFile(.behaviourRules, fileID: "behaviour",
                                validator: LiveEditValidators.nonEmpty,    personality: personality)
        registerPersonalityFile(.responseRules,  fileID: "response_playbook",
                                validator: LiveEditValidators.nonEmpty,    personality: personality)
        registerPersonalityFile(.boundaries,     fileID: "boundaries",
                                validator: LiveEditValidators.nonEmpty,    personality: personality, isProtected: true)
        // User model IS injected (so "remember X about me" reaches the LLM).
        registerPersonalityFile(.userModel,      fileID: "user_preferences",
                                validator: LiveEditValidators.nonEmpty,    personality: personality, injects: true)

        // ── HeartbeatStore-backed (read-only via the engine; edited through its
        //    own live API). Not re-injected here — it has its own injection path.
        register(LivingSystem(
            id: .heartbeat,
            isProtected: false,
            injectsContext: false,
            defaultRisk: .low,
            read: { HeartbeatStore.shared.state.situationSummary() },
            write: { _ in /* heartbeat is updated via HeartbeatStore's live API */ },
            validator: { _ in .invalid("Heartbeat is updated through its own engine, not freeform text.") }
        ))

        // ── LiveDoc-backed systems (new editable layers) ──────────────────────
        registerDoc(.voice,        defaultText: Defaults.voice,        validator: LiveEditValidators.nonEmpty)
        registerDoc(.commands,     defaultText: Defaults.commands,     validator: LiveEditValidators.commands)
        registerDoc(.goals,        defaultText: Defaults.goals,        validator: LiveEditValidators.nonEmpty)
        registerDoc(.skills,       defaultText: Defaults.skills,       validator: LiveEditValidators.nonEmpty)
        registerDoc(.agents,       defaultText: Defaults.agents,       validator: LiveEditValidators.nonEmpty)
        registerDoc(.memoryRules,  defaultText: Defaults.memoryRules,  validator: LiveEditValidators.nonEmpty)
        registerDoc(.projectState, defaultText: Defaults.projectState, validator: LiveEditValidators.nonEmpty)

        Log.app.info("[LivingSystemRegistry] configured \(self.systems.count) systems")
    }

    private func registerPersonalityFile(_ id: LivingSystemID,
                                         fileID: String,
                                         validator: @escaping (String) -> ValidationResult,
                                         personality: PersonalityFileStore,
                                         isProtected: Bool = false,
                                         injects: Bool = false) {
        guard let file = PersonalityPack.files.first(where: { $0.id == fileID }) else { return }
        register(LivingSystem(
            id: id,
            isProtected: isProtected,
            injectsContext: injects,
            defaultRisk: .medium,
            read: { personality.content(for: file) },
            write: { personality.save(file: file, content: $0) },
            validator: validator
        ))
    }

    private func registerDoc(_ id: LivingSystemID,
                             defaultText: String,
                             validator: @escaping (String) -> ValidationResult) {
        let store = LiveDocStore(id: id.rawValue, defaultText: defaultText)
        docStores[id] = store
        register(LivingSystem(
            id: id,
            isProtected: false,
            injectsContext: true,
            defaultRisk: .low,
            read: { store.text },
            write: { store.setText($0) },
            validator: validator
        ))
    }

    // MARK: - Context injection

    /// Concatenates the `[LABEL]` blocks for every system flagged `injectsContext`.
    /// Injected into the LLM context so edits influence the next response.
    func combinedContextBlock() -> String {
        all().compactMap { $0.contextBlock() }.joined(separator: "\n\n")
    }

    func contextBlock(for id: LivingSystemID) -> String? {
        system(id)?.contextBlock()
    }

    // MARK: - Defaults

    private enum Defaults {
        static let voice = """
        # Jarvis Voice

        **Tone:** calm, direct, grounded.
        **Humour:** dry, sparing.
        **Verbosity:** concise — speakable in under 20 seconds.
        **Confidence:** assured, never sycophantic.

        Voice controls delivery only — tone, humour, verbosity, personality.
        It is independent of Soul (principles) and Identity (role).
        """

        static let commands = """
        # Live Commands
        # One mapping per line:  <trigger> => <action / expansion>

        # Example:
        # shop dashboard => Etsy, Shopify and eBay
        """

        static let goals = """
        # Active Goals
        # One goal per line. Goals influence recommendations.
        """

        static let skills = """
        # Skills
        # Editable list of enabled skills. One per line.
        """

        static let agents = """
        # Agents
        # Specialist agents and their objectives. One per line.
        """

        static let memoryRules = """
        # Memory Rules

        - Every memory carries a confidence score and a source.
        - Stale memories are challenged; incorrect memories decay.
        - Private memories are never injected into external context.
        """

        static let projectState = """
        # Project State
        # Freeform notes on the current active project and its status.
        """
    }
}
