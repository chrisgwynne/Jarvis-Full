import Foundation

/// Enforces token-budget constraints on LLM prompts.
/// All context trimming should flow through here rather than ad-hoc string slicing.
///
/// Rough token estimate: 1 token ≈ 4 chars (English prose).
/// The budgets here are conservative — better to under-fill than to bloat.
enum PromptBudgeter {

    // MARK: - Budget presets

    struct Budget {
        let maxContextChars: Int
        let maxSystemChars: Int
        let maxUserChars: Int
        let maxTotalEstimatedTokens: Int
    }

    /// Standard budget — general conversational + intent classification queries.
    static let standard = Budget(
        maxContextChars: 600,
        maxSystemChars: 1_200,
        maxUserChars: 500,
        maxTotalEstimatedTokens: 600
    )

    /// Compact budget — simple action classification where context matters less.
    static let compact = Budget(
        maxContextChars: 300,
        maxSystemChars: 800,
        maxUserChars: 300,
        maxTotalEstimatedTokens: 380
    )

    /// Minimal budget — classification-only calls that need speed over richness.
    static let minimal = Budget(
        maxContextChars: 100,
        maxSystemChars: 500,
        maxUserChars: 200,
        maxTotalEstimatedTokens: 220
    )

    // MARK: - Context trimming

    /// Trim a raw context summary to the budget, preserving line boundaries.
    static func trimContext(_ raw: String,
                            budget: Budget = PromptBudgeter.standard) -> String {
        guard raw.count > budget.maxContextChars else { return raw }
        let cut = String(raw.prefix(budget.maxContextChars))
        // Prefer to end at a newline so we don't bisect a field.
        if let lastNL = cut.lastIndex(of: "\n") {
            return String(cut[..<lastNL]) + "\n[context trimmed]"
        }
        return cut + "\n[context trimmed]"
    }

    /// Build a compact context string from a snapshot summary string,
    /// prioritising the first (most important) fields.
    static func compactContext(from summary: String,
                               budget: Budget = PromptBudgeter.standard) -> String? {
        guard !summary.isEmpty else { return nil }
        let trimmed = trimContext(summary, budget: budget)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Token estimation

    static func estimatedTokens(system: String,
                                user: String,
                                context: String?) -> Int {
        let total = system.count + user.count + (context?.count ?? 0)
        return total / 4
    }

    // MARK: - Diagnostics

    struct PromptDiagnostics {
        let systemChars: Int
        let userChars: Int
        let contextChars: Int
        let estimatedTokens: Int
        var isOverBudget: Bool
    }

    static func diagnose(system: String,
                          user: String,
                          context: String?,
                          budget: Budget = PromptBudgeter.standard) -> PromptDiagnostics {
        let ctxChars = context?.count ?? 0
        let est = estimatedTokens(system: system, user: user, context: context)
        return PromptDiagnostics(
            systemChars: system.count,
            userChars: user.count,
            contextChars: ctxChars,
            estimatedTokens: est,
            isOverBudget: est > budget.maxTotalEstimatedTokens
        )
    }
}
