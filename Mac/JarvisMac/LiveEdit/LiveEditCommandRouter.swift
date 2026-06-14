import Foundation

// MARK: - LiveEditCommandRouter

/// Detects natural-language live-edit commands and routes them to the
/// `LiveEditEngine`. Returns a spoken reply when it handled the utterance, or
/// `nil` to let normal routing proceed.
///
/// Pure dispatch over the shared engine/registry/audit, so it is fully testable
/// and adds exactly one interception point to `handleTranscript`.
@MainActor
enum LiveEditCommandRouter {

    private static var engine: LiveEditEngine { .shared }
    private static var audit: LiveEditAuditLog { .shared }
    private static var registry: LivingSystemRegistry { .shared }

    /// Returns a spoken reply if this was a live-edit command, else nil.
    static func handle(rawText: String, normalized: String) -> String? {
        let n = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return nil }

        // ── Inspection / audit ────────────────────────────────────────────────
        if matchesAny(n, ["show living systems", "list living systems", "show your living systems",
                          "what can you edit", "what living systems"]) {
            return livingSystemsSummary()
        }
        if matchesAny(n, ["show recent changes", "show recent edits", "what did you edit",
                          "what did you change", "recent edits", "recent changes",
                          "what have you changed"]) {
            return recentEditsSummary()
        }
        if matchesAny(n, ["why did you change that", "why did you edit that", "why did you change it"]) {
            return whyLastChange()
        }
        if matchesAny(n, ["diagnose yourself", "self diagnose", "run a self diagnosis",
                          "diagnose your systems", "system health"]) {
            return diagnose()
        }

        // ── Rollback ──────────────────────────────────────────────────────────
        if matchesAny(n, ["rollback last edit", "rollback your last change", "rollback the last change",
                          "roll back the last change", "roll back your last change", "undo the last change",
                          "undo your last change", "undo that change", "undo the last edit", "revert last change"]) {
            return speak(engine.rollbackLast())
        }

        // ── Self-fix ──────────────────────────────────────────────────────────
        if matchesAny(n, ["fix your last mistake", "fix the command that failed",
                          "fix the last command", "fix that command", "repair the failed command"]) {
            _ = engine.reportFailure(systemID: .commands,
                                     detail: "User asked to fix the last failed command.")
            return "I've logged that as an open issue and proposed a fix. It's in your recent changes — say 'apply it' to approve."
        }

        // ── Commands: \"when I say X I mean Y\" / \"add a command …\" ─────────────
        if let (trigger, expansion) = parseAlias(n) {
            return addCommand(trigger: trigger, expansion: expansion)
        }
        if let rest = after(n, anyOf: ["add a command", "add command", "create a command"]) {
            if let (t, e) = splitMapping(rest) { return addCommand(trigger: t, expansion: e) }
            return "Tell me the command as 'when I say X, I mean Y'."
        }
        if let rest = after(n, anyOf: ["disable the command", "disable command", "remove the command", "delete the command"]) {
            return disableCommand(matching: rest)
        }

        // ── Soul / Identity / Voice / Behaviour / User model NL edits ─────────
        if let rest = after(n, anyOf: ["update your soul", "change your soul", "edit your soul", "set your soul"]) {
            return speak(engine.applyInstruction(.soul, instruction: stripConnectors(rest), source: .user), system: .soul)
        }
        if let rest = after(n, anyOf: ["change your identity", "update your identity", "edit your identity", "set your identity"]) {
            return speak(engine.applyInstruction(.identity, instruction: stripConnectors(rest), source: .user), system: .identity)
        }
        if let rest = after(n, anyOf: ["update your voice", "change your voice", "edit your voice", "set your voice"]) {
            return speak(engine.applyInstruction(.voice, instruction: stripConnectors(rest), source: .user), system: .voice)
        }
        if let rest = after(n, anyOf: ["update your behaviour", "change your behaviour", "update your behavior",
                                       "change your behavior", "add a behaviour rule", "add a rule"]) {
            return speak(engine.applyInstruction(.behaviourRules, instruction: stripConnectors(rest), source: .user), system: .behaviourRules)
        }
        if matchesAny(n, ["remove that rule", "remove the rule", "delete that rule", "forget that rule"]) ||
            n.hasPrefix("remove the rule") {
            let instruction = "remove " + stripConnectors(after(n, anyOf: ["remove that rule", "remove the rule",
                                                                           "delete that rule", "forget that rule"]) ?? "")
            return speak(engine.applyInstruction(.behaviourRules, instruction: instruction, source: .user), system: .behaviourRules)
        }

        // ── User model: remember / forget ─────────────────────────────────────
        if let rest = after(n, anyOf: ["remember this about me", "remember that about me"]) {
            return speak(engine.applyInstruction(.userModel, instruction: stripConnectors(rest), source: .user), system: .userModel)
        }
        if let rest = after(n, anyOf: ["forget that i", "forget that", "forget about that", "forget about"]) {
            return speak(engine.applyInstruction(.userModel, instruction: "remove " + stripConnectors(rest), source: .user), system: .userModel)
        }

        return nil
    }

    // MARK: - Command helpers

    private static func addCommand(trigger: String, expansion: String) -> String {
        guard let sys = registry.system(.commands) else { return "Commands aren't available right now." }
        let line = "\(trigger) => \(expansion)"
        let current = sys.read()
        let newValue = current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? line
            : current + "\n" + line
        let outcome = engine.apply(.commands, newValue: newValue,
                                   reason: "Added command \"\(trigger)\"", source: .user)
        switch outcome {
        case .applied:        return "Got it. When you say \"\(trigger)\", I'll take that as \(expansion)."
        case .rejected(let r): return "I couldn't add that command: \(r)"
        default:              return "I couldn't add that command."
        }
    }

    private static func disableCommand(matching needle: String) -> String {
        guard let sys = registry.system(.commands) else { return "Commands aren't available right now." }
        let key = needle.lowercased().trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return "Which command should I disable?" }
        let kept = sys.read().components(separatedBy: "\n").filter { !$0.lowercased().contains(key) }
        let outcome = engine.apply(.commands, newValue: kept.joined(separator: "\n"),
                                   reason: "Disabled command matching \"\(key)\"", source: .user)
        switch outcome {
        case .applied:   return "Removed the command matching \"\(key)\"."
        case .noChange:  return "I couldn't find a command matching \"\(key)\"."
        default:         return "I couldn't disable that command."
        }
    }

    // MARK: - Replies

    private static func speak(_ outcome: EditOutcome, system: LivingSystemID? = nil) -> String {
        switch outcome {
        case .applied:
            let name = system?.displayName ?? "system"
            return "Updated my \(name). Say 'rollback last edit' to undo."
        case .rejected(let r):
            return "I couldn't apply that: \(r)"
        case .needsApproval:
            return "That touches protected core — I've logged a proposal but won't apply it without explicit approval."
        case .noChange:
            return "That's already how I'm set."
        }
    }

    private static func livingSystemsSummary() -> String {
        let names = registry.all().map { $0.displayName }
        guard !names.isEmpty else { return "No living systems are registered yet." }
        return "I have \(names.count) editable systems: \(names.joined(separator: ", "))."
    }

    private static func recentEditsSummary() -> String {
        let recent = audit.recent(limit: 5).filter { $0.action == "applied" || $0.action == "rolled_back" }
        guard !recent.isEmpty else { return "I haven't made any changes yet." }
        let lines = recent.map { "\($0.systemID): \($0.summary)" }
        return "Recent changes — " + lines.joined(separator: "; ") + "."
    }

    private static func whyLastChange() -> String {
        guard let last = audit.lastChange else { return "I haven't changed anything recently." }
        return "I changed \(last.systemID) because: \(last.summary)."
    }

    private static func diagnose() -> String {
        let count = registry.all().count
        let edits = audit.recent(limit: 100).filter { $0.action == "applied" }.count
        let issues = HeartbeatStore.shared.state.openIssues.count
        return "\(count) living systems registered, \(edits) edits on record, \(issues) open issues. All non-core systems are editable and reversible."
    }

    // MARK: - Parsing helpers

    private static func matchesAny(_ text: String, _ phrases: [String]) -> Bool {
        phrases.contains { text == $0 || text.contains($0) }
    }

    /// Returns the remainder after the first matching trigger phrase, or nil.
    private static func after(_ text: String, anyOf triggers: [String]) -> String? {
        for t in triggers {
            if let r = text.range(of: t) {
                return String(text[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Strips leading connective words so "so you always prioritise brevity"
    /// becomes "always prioritise brevity".
    static func stripConnectors(_ s: String) -> String {
        var rest = s.trimmingCharacters(in: CharacterSet(charactersIn: " .,:;\"'"))
        let connectors = ["so that you ", "so that ", "so you ", "so it ", "so ", "to always ", "to be ",
                          "to ", "that you ", "that ", "you should ", "you ", "always remember to ", "remember to ",
                          "it should ", "and "]
        var changed = true
        while changed {
            changed = false
            for c in connectors where rest.hasPrefix(c) {
                rest = String(rest.dropFirst(c.count))
                changed = true
                break
            }
        }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    /// Parses "(remember that) when I say X I mean/want Y" into (X, Y).
    static func parseAlias(_ text: String) -> (String, String)? {
        guard let sayRange = text.range(of: "when i say ") else { return nil }
        let afterSay = String(text[sayRange.upperBound...])
        for connector in [", i mean ", " i mean ", ", i want ", " i want ", ", open ", " open ", ", show ", " show "] {
            if let r = afterSay.range(of: connector) {
                let trigger = String(afterSay[..<r.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: " ,'\""))
                let expansion = String(afterSay[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " .,'\""))
                if !trigger.isEmpty && !expansion.isEmpty { return (trigger, expansion) }
            }
        }
        return nil
    }

    /// Splits "X => Y" / "X means Y" / "X : Y" into (X, Y).
    static func splitMapping(_ s: String) -> (String, String)? {
        for sep in [" => ", "=>", " means ", " is ", ": ", ":"] {
            if let r = s.range(of: sep) {
                let t = String(s[..<r.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: " ,'\""))
                let e = String(s[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " .,'\""))
                if !t.isEmpty && !e.isEmpty { return (t, e) }
            }
        }
        return nil
    }
}
