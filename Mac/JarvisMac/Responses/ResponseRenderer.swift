import Foundation

/// Resolves a response key to a spoken string by selecting a phrase variant
/// according to the active style and substituting named placeholders.
@MainActor
struct ResponseRenderer {
    let store: ResponseTemplateStore

    func render(_ key: String, _ vars: [String: String] = [:]) -> String {
        let candidates = store.phrases(for: key)
        guard !candidates.isEmpty else {
            Log.app.warning("ResponseRenderer: unknown key '\(key)' — using built-in fallback")
            let fallback = ResponsePlaybook.defaults[key]?.first ?? ""
            return substitute(fallback, vars: vars)
        }

        let template: String
        switch store.style {
        case .consistent:
            template = candidates[0]
        case .varied:
            template = candidates.randomElement() ?? candidates[0]
        case .minimal:
            template = candidates.min(by: { $0.count < $1.count }) ?? candidates[0]
        }
        return substitute(template, vars: vars)
    }

    // MARK: - Private

    private func substitute(_ template: String, vars: [String: String]) -> String {
        var result = template
        for (k, v) in vars {
            result = result.replacingOccurrences(of: "{\(k)}", with: v)
        }
        // Strip any unresolved placeholders gracefully
        if let regex = try? NSRegularExpression(pattern: #"\{[a-zA-Z_]+\}"#) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }
        // Collapse double spaces that may result from stripped placeholders
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}
