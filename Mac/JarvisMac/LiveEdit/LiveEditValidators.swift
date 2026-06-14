import Foundation

// MARK: - LiveEditValidators

/// Per-system validation. Every living system must validate before a change is
/// applied. Validators are pure functions so they're trivially testable and run
/// off any actor.
enum LiveEditValidators {

    static let maxLength = 40_000

    // MARK: - Generic building blocks

    static func nonEmpty(_ value: String) -> ValidationResult {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .invalid("Content cannot be empty.") }
        if value.count > maxLength { return .invalid("Content exceeds \(maxLength) characters.") }
        return .valid
    }

    /// Rejects empty/oversized content and requires at least one of the given
    /// anchor phrases to survive, so a core definition can't be wholly erased.
    static func requiresAnchor(_ anchors: [String], systemLabel: String) -> (String) -> ValidationResult {
        { value in
            switch nonEmpty(value) {
            case .invalid(let r): return .invalid(r)
            default: break
            }
            let lower = value.lowercased()
            if anchors.contains(where: { lower.contains($0.lowercased()) }) {
                return .valid
            }
            return .invalid("\(systemLabel) must still reference one of: \(anchors.joined(separator: ", ")).")
        }
    }

    // MARK: - System-specific

    /// Soul: non-empty and must preserve the primary mission anchor.
    static func soul(_ value: String) -> ValidationResult {
        requiresAnchor(["useful", "user", "help", "mission", "assist"], systemLabel: "Soul")(value)
    }

    /// Identity: non-empty; the core identity (the name) must not be erased.
    static func identity(_ value: String) -> ValidationResult {
        requiresAnchor(["jarvis"], systemLabel: "Identity")(value)
    }

    /// Commands: each non-blank line must declare a trigger → action mapping via
    /// `=>` or `:` so a command always has both a trigger and an action.
    static func commands(_ value: String) -> ValidationResult {
        switch nonEmpty(value) {
        case .invalid(let r): return .invalid(r)
        default: break
        }
        var triggers = Set<String>()
        for raw in value.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let sep = line.range(of: "=>") ?? line.range(of: ":") else {
                return .invalid("Each command needs a trigger and an action, e.g. \"shop dashboard => Etsy, Shopify, eBay\".")
            }
            let trigger = line[..<sep.lowerBound].trimmingCharacters(in: .whitespaces).lowercased()
            let action = line[sep.upperBound...].trimmingCharacters(in: .whitespaces)
            if trigger.isEmpty { return .invalid("A command line is missing its trigger.") }
            if action.isEmpty { return .invalid("Command \"\(trigger)\" is missing an action.") }
            if !triggers.insert(trigger).inserted {
                return .invalid("Duplicate command trigger: \"\(trigger)\".")
            }
        }
        return .valid
    }
}
