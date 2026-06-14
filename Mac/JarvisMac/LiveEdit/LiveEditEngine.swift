import Foundation

// MARK: - LiveEditEngine

/// Performs runtime edits to living systems: validate → persist (via the backing
/// store, which hot-reloads) → audit → publish change event → enable rollback.
///
/// Instance-based with a shared convenience singleton so it can be exercised
/// hermetically in tests (inject a private registry + audit log) while the app
/// uses `.shared`, which is wired to the shared registry and audit log.
@MainActor
final class LiveEditEngine {

    static let shared = LiveEditEngine(registry: .shared, audit: .shared)

    let registry: LivingSystemRegistry
    let audit: LiveEditAuditLog

    /// Full patch history (applied + rollbacks), newest last. Persisted so
    /// rollback survives restarts.
    private(set) var patches: [RuntimePatch] = []
    let fileURL: URL

    init(registry: LivingSystemRegistry, audit: LiveEditAuditLog, fileURL: URL? = nil) {
        self.registry = registry
        self.audit = audit
        self.fileURL = fileURL ?? Self.defaultURL()
        self.patches = Self.loadPatches(from: self.fileURL)
    }

    private static func defaultURL() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true)) ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("JarvisMac", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("live_edit_patches.json")
    }

    // MARK: - Apply a structured edit

    @discardableResult
    func apply(_ id: LivingSystemID,
               newValue: String,
               reason: String,
               source: EditSource,
               risk: RiskLevel? = nil) -> EditOutcome {

        guard let sys = registry.system(id) else {
            return .rejected("Unknown living system: \(id.rawValue)")
        }

        let effectiveRisk = risk ?? (sys.isProtected ? .protectedCore : sys.defaultRisk)
        let before = sys.read()

        // Protected-core guard: never silently apply. Log a proposal instead.
        if sys.isProtected && source != .userApproved {
            let patch = RuntimePatch(systemID: id.rawValue, before: before, after: newValue,
                                     reason: reason, source: source, risk: .protectedCore, applied: false)
            recordAudit(id, action: "proposed", patch: patch,
                        summary: "Proposed (protected — needs approval): \(reason)", rollbackAvailable: false)
            return .needsApproval(patch)
        }

        // Validation.
        switch sys.validate(newValue) {
        case .invalid(let r):
            let patch = RuntimePatch(systemID: id.rawValue, before: before, after: newValue,
                                     reason: reason, source: source, risk: effectiveRisk, applied: false)
            recordAudit(id, action: "rejected", patch: patch,
                        summary: "Rejected: \(r)", rollbackAvailable: false)
            return .rejected(r)
        case .needsApproval(let r):
            if source != .userApproved {
                let patch = RuntimePatch(systemID: id.rawValue, before: before, after: newValue,
                                         reason: reason, source: source, risk: effectiveRisk, applied: false)
                recordAudit(id, action: "proposed", patch: patch,
                            summary: "Proposed (needs approval): \(r)", rollbackAvailable: false)
                return .needsApproval(patch)
            }
        case .valid:
            break
        }

        if before == newValue { return .noChange }

        // Apply through the backing store (hot-reloads immediately).
        sys.write(newValue)
        var patch = RuntimePatch(systemID: id.rawValue, before: before, after: newValue,
                                 reason: reason, source: source, risk: effectiveRisk, applied: true)
        patch.applied = true
        patches.append(patch)
        savePatches()
        recordAudit(id, action: "applied", patch: patch,
                    summary: reason, rollbackAvailable: true)
        registry.noteChange(id)
        SystemBus.shared.publish(LivingSystemChangedEvent(systemID: id.rawValue, action: "applied"))
        Log.app.info("[LiveEdit] applied edit to \(id.rawValue) by \(source.rawValue)")
        return .applied(patch)
    }

    // MARK: - Natural-language edit

    /// Converts a natural-language instruction into a patch for a text system
    /// (append a principle, or remove rules matching a phrase) and applies it.
    @discardableResult
    func applyInstruction(_ id: LivingSystemID,
                          instruction: String,
                          source: EditSource) -> EditOutcome {
        guard let sys = registry.system(id) else {
            return .rejected("Unknown living system: \(id.rawValue)")
        }
        let current = sys.read()
        let newValue = LiveEditInstruction.transform(current: current, instruction: instruction)
        return apply(id, newValue: newValue, reason: "Instruction: \(instruction.auditPreview(80))", source: source)
    }

    // MARK: - Rollback

    @discardableResult
    func rollbackLast() -> EditOutcome {
        guard let last = patches.last(where: { $0.applied }) else {
            return .rejected("There are no changes to roll back.")
        }
        return rollback(patchID: last.id)
    }

    @discardableResult
    func rollback(patchID: UUID) -> EditOutcome {
        guard let idx = patches.firstIndex(where: { $0.id == patchID && $0.applied }) else {
            return .rejected("No applied change with that id to roll back.")
        }
        let target = patches[idx]
        guard let sid = LivingSystemID(rawValue: target.systemID),
              let sys = registry.system(sid) else {
            return .rejected("The system for that change is no longer registered.")
        }
        // Restore the previous value.
        sys.write(target.before)
        patches[idx].applied = false
        let inverse = RuntimePatch(systemID: target.systemID,
                                   before: target.after, after: target.before,
                                   reason: "Rollback of \(target.reason.auditPreview(60))",
                                   source: .system, risk: target.risk,
                                   applied: true, rollbackRef: target.id)
        patches.append(inverse)
        savePatches()
        recordAudit(sid, action: "rolled_back", patch: inverse,
                    summary: "Rolled back: \(target.reason.auditPreview(80))", rollbackAvailable: false)
        registry.noteChange(sid)
        SystemBus.shared.publish(LivingSystemChangedEvent(systemID: sid.rawValue, action: "rolled_back"))
        Log.app.info("[LiveEdit] rolled back \(sid.rawValue)")
        return .applied(inverse)
    }

    // MARK: - Self-fix

    /// Records a failure as a Heartbeat open issue and logs a *proposed* fix in
    /// the audit trail. Returns the proposal patch (never applied automatically).
    @discardableResult
    func reportFailure(systemID: LivingSystemID, detail: String) -> RuntimePatch {
        HeartbeatStore.shared.addOpenIssue("\(systemID.displayName): \(detail)",
                                           source: "self-monitor", confidence: 0.8)
        let sys = registry.system(systemID)
        let risk: RiskLevel = (sys?.isProtected == true) ? .protectedCore : .medium
        let patch = RuntimePatch(systemID: systemID.rawValue,
                                 before: sys?.read() ?? "", after: sys?.read() ?? "",
                                 reason: "Proposed self-fix: \(detail)",
                                 source: .commandFailure, risk: risk, applied: false)
        recordAudit(systemID, action: "proposed", patch: patch,
                    summary: "Self-fix proposed: \(detail.auditPreview(80))", rollbackAvailable: false)
        SystemBus.shared.publish(LivingSystemChangedEvent(systemID: systemID.rawValue, action: "proposed"))
        return patch
    }

    // MARK: - Queries

    func recentPatches(limit: Int = 10) -> [RuntimePatch] {
        Array(patches.reversed().prefix(max(0, limit)))
    }

    func recentEdits(limit: Int = 10) -> [AuditEntry] { audit.recent(limit: limit) }

    // MARK: - Helpers

    private func recordAudit(_ id: LivingSystemID, action: String, patch: RuntimePatch,
                             summary: String, rollbackAvailable: Bool) {
        audit.record(AuditEntry(
            systemID: id.rawValue,
            action: action,
            summary: summary,
            beforePreview: patch.before.auditPreview(),
            afterPreview: patch.after.auditPreview(),
            source: patch.source,
            risk: patch.risk,
            rollbackAvailable: rollbackAvailable,
            patchID: patch.id
        ))
    }

    private func savePatches() {
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted]
            enc.dateEncodingStrategy = .iso8601
            try enc.encode(patches).write(to: fileURL, options: .atomic)
        } catch {
            Log.app.error("[LiveEdit] patch save failed: \(error.localizedDescription)")
        }
    }

    private static func loadPatches(from url: URL) -> [RuntimePatch] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([RuntimePatch].self, from: data)) ?? []
    }
}

// MARK: - LiveEditInstruction

/// Deterministic natural-language → patch transforms for text systems. Keeps the
/// engine usable without an LLM round-trip for the common cases (add a principle,
/// remove a rule). An LLM-assisted patcher can layer on top later.
enum LiveEditInstruction {

    private static let removalVerbs = ["remove", "delete", "drop", "forget", "stop", "no longer"]

    static func transform(current: String, instruction: String) -> String {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return current }

        if let phrase = removalPhrase(in: trimmed) {
            return removeLines(containing: phrase, from: current)
        }
        return appendBullet(trimmed, to: current)
    }

    /// Returns the target phrase if the instruction is a removal, else nil.
    static func removalPhrase(in instruction: String) -> String? {
        let lower = instruction.lowercased()
        guard removalVerbs.contains(where: { lower.hasPrefix($0) || lower.contains(" \($0) ") }) else {
            return nil
        }
        // Strip leading verb + filler so the remainder is the phrase to match.
        var rest = lower
        for verb in removalVerbs where rest.hasPrefix(verb) {
            rest = String(rest.dropFirst(verb.count))
            break
        }
        for filler in ["the rule that says", "the rule about", "the rule", "that says", "the line about",
                       "that rule", "that", "any rule about", "rule about", "the part about", "the bit about", "about"] {
            if rest.contains(filler) {
                rest = rest.replacingOccurrences(of: filler, with: " ")
            }
        }
        let phrase = rest.trimmingCharacters(in: CharacterSet(charactersIn: " .,:;\"'"))
        return phrase.isEmpty ? nil : phrase
    }

    static func removeLines(containing phrase: String, from text: String) -> String {
        let key = phrase.lowercased()
        let kept = text.components(separatedBy: "\n").filter { !$0.lowercased().contains(key) }
        return kept.joined(separator: "\n")
    }

    static func appendBullet(_ instruction: String, to text: String) -> String {
        // Sentence-case the principle and append as a markdown bullet.
        var principle = instruction
        if let first = principle.first, first.isLowercase {
            principle = first.uppercased() + String(principle.dropFirst())
        }
        if !principle.hasSuffix(".") && !principle.hasSuffix("!") { principle += "." }
        let base = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? "- \(principle)" : base + "\n- \(principle)"
    }
}
