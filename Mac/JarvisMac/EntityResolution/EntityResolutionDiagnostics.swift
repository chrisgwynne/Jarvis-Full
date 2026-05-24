import Foundation
import Observation

// MARK: - EntityResolutionDiagnostics

/// Observable diagnostics for the EntityFirstResolver pipeline.
/// Records every resolution (success or clarification) in a capped ring buffer
/// so the UI, tests, and logging can see what happened at a glance.
@Observable
@MainActor
final class EntityResolutionDiagnostics {

    static let shared = EntityResolutionDiagnostics()

    // MARK: - Resolution log entry

    struct ResolutionLog: Identifiable {
        let id        = UUID()
        let timestamp : Date
        let originalSpan   : String
        let resolvedName   : String
        let entityType     : EntityType
        let provider       : String
        let confidence     : Double
        let needsClarification: Bool
    }

    // MARK: - State

    private(set) var logs: [ResolutionLog] = []
    private let maxLogs = 100

    // MARK: - Recording

    func record(_ result: EntityResolutionResult) {
        let entry = ResolutionLog(
            timestamp          : Date(),
            originalSpan       : result.originalSpan,
            resolvedName       : result.displayName,
            entityType         : result.entityType,
            provider           : result.provider,
            confidence         : result.confidence,
            needsClarification : result.needsClarification
        )
        logs.insert(entry, at: 0)
        if logs.count > maxLogs { logs.removeLast() }
    }

    // MARK: - Computed helpers

    var totalResolutions: Int { logs.count }

    var successCount: Int {
        logs.filter { !$0.needsClarification }.count
    }

    var clarificationCount: Int {
        logs.filter { $0.needsClarification }.count
    }

    var successRate: Double {
        guard !logs.isEmpty else { return 0 }
        return Double(successCount) / Double(logs.count)
    }

    /// Short one-liner suitable for the runtime diagnostics overlay.
    var statusLine: String {
        guard let last = logs.first else { return "No resolutions yet" }
        let pct = Int(successRate * 100)
        return "\(last.resolvedName) (\(Int(last.confidence * 100))%) · \(pct)% success · \(totalResolutions) total"
    }

    /// Per-provider breakdown: providerName → count.
    var byProvider: [String: Int] {
        Dictionary(grouping: logs, by: { $0.provider })
            .mapValues { $0.count }
    }
}
