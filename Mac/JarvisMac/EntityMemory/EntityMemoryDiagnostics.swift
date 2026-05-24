import Foundation
import Observation

// MARK: - EntityMemoryDiagnostics

@Observable
@MainActor
final class EntityMemoryDiagnostics {

    static let shared = EntityMemoryDiagnostics()

    // Graph state
    var totalNodes: Int = 0
    var expiredNodes: Int = 0
    var nodesByKind: [String: Int] = [:]

    // Resolution stats
    var resolutionsAttempted: Int = 0
    var resolutionsSucceeded: Int = 0
    var resolutionsClarified: Int = 0
    var resolutionsFailed: Int = 0
    var lastResolutionSource: String = "—"
    var lastResolutionConfidence: Double = 0
    var lastResolvedEntity: String = "—"

    // MARK: - Update

    func refresh() {
        let all = EntityMemoryGraph.shared.all()
        totalNodes   = all.count
        expiredNodes = all.filter(\.isExpired).count
        var kinds: [String: Int] = [:]
        for node in all { kinds[node.entityKind.rawValue, default: 0] += 1 }
        nodesByKind = kinds
    }

    func recordResolution(_ result: ResolutionResult) {
        resolutionsAttempted += 1
        if result.entity != nil {
            if result.needsClarification { resolutionsClarified += 1 } else { resolutionsSucceeded += 1 }
            lastResolutionSource     = result.source
            lastResolutionConfidence = result.confidence
            lastResolvedEntity       = result.entity?.canonicalName ?? "—"
        } else {
            resolutionsFailed += 1
            lastResolutionSource     = "none"
            lastResolutionConfidence = 0
        }
    }

    // MARK: - Status line

    var statusLine: String {
        let pct = resolutionsAttempted > 0
            ? Int(Double(resolutionsSucceeded) / Double(resolutionsAttempted) * 100)
            : 0
        return "\(totalNodes) entities · \(pct)% resolved · last: \(lastResolvedEntity)"
    }
}
