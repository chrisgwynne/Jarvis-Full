import Foundation

// MARK: - LivingSystem

/// A descriptor for one editable runtime layer. It abstracts over heterogeneous
/// backings (PersonalityFileStore files, HeartbeatStore, LiveDocStore) behind a
/// uniform read/write/validate interface so the `LiveEditEngine` can treat every
/// living system the same way.
///
/// `read`/`write` are MainActor-isolated function values because the backing
/// stores are `@MainActor`. The registry and engine that invoke them are also
/// `@MainActor`, so the isolation lines up without hops.
struct LivingSystem {
    let id: LivingSystemID
    let isProtected: Bool
    /// Whether this system's content is injected into the LLM context by the
    /// registry. Personality-file systems (soul/identity/behaviour) are already
    /// injected by `PersonalityContextBuilder`, so they set this `false` to avoid
    /// duplication; the newer live-doc systems (voice/commands/…) set it `true`.
    let injectsContext: Bool
    let defaultRisk: RiskLevel

    let read: @MainActor () -> String
    let write: @MainActor (String) -> Void
    let validator: (String) -> ValidationResult

    var displayName: String { id.displayName }
    var contextLabel: String { id.contextLabel }

    func validate(_ value: String) -> ValidationResult { validator(value) }

    /// Builds the `[LABEL]\n<content>` block for LLM injection. Returns nil when
    /// the system shouldn't be injected or has no content.
    @MainActor
    func contextBlock() -> String? {
        guard injectsContext else { return nil }
        let body = read().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        return "[\(contextLabel)]\n\(body)"
    }
}
