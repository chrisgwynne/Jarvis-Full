import Foundation
import os

// MARK: - LatencyBudgetSystem

/// Tracks per-operation latency against target budgets.
/// Call `record(_:since:)` with the start time of any instrumented operation.
/// `summaryReport()` produces a human-readable budget status.
@MainActor
final class LatencyBudgetSystem {

    static let shared = LatencyBudgetSystem()

    private let log = Logger(subsystem: "com.jarvis", category: "latency")

    // MARK: - Budget Kinds

    enum BudgetKind: String, CaseIterable {
        case routeClassification = "route_classification"
        case silentActionDispatch = "silent_action"
        case firstSpokenToken    = "first_token"
        case interruptionPivot   = "interruption_pivot"
        case proactiveDecision   = "proactive_decision"
        case retrievalCacheHit   = "retrieval_hit"
        case episodicRetrieval   = "episodic_retrieval"
        case worldStateLookup    = "world_state"
        case streamingTTS        = "streaming_tts"
    }

    // Target budgets in milliseconds
    static let targets: [BudgetKind: Double] = [
        .routeClassification: 50,
        .silentActionDispatch: 100,
        .firstSpokenToken:    500,
        .interruptionPivot:   300,
        .proactiveDecision:   150,
        .retrievalCacheHit:   50,
        .episodicRetrieval:   100,
        .worldStateLookup:    20,
        .streamingTTS:        200,
    ]

    static func warningMs(for kind: BudgetKind) -> Double {
        (targets[kind] ?? 200) * 0.75
    }

    // MARK: - Measurement

    struct Measurement {
        let kind: BudgetKind
        let durationMs: Double
        let timestamp: Date
        let exceededBudget: Bool
        let exceededWarning: Bool
    }

    private var measurements: [Measurement] = []
    private let cap = 500

    // MARK: - Record

    func record(_ kind: BudgetKind, durationMs: Double) {
        let budget = Self.targets[kind] ?? 9999
        let warn   = Self.warningMs(for: kind)
        let m = Measurement(
            kind: kind,
            durationMs: durationMs,
            timestamp: Date(),
            exceededBudget: durationMs > budget,
            exceededWarning: durationMs > warn
        )
        measurements.append(m)
        if measurements.count > cap { measurements.removeFirst() }
        if m.exceededBudget {
            log.warning("latency_budget_exceeded kind=\(kind.rawValue) ms=\(String(format:"%.1f",durationMs)) budget=\(String(format:"%.0f",budget))")
        }
    }

    func record(_ kind: BudgetKind, since start: CFAbsoluteTime) {
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        record(kind, durationMs: ms)
    }

    func startTimer() -> CFAbsoluteTime { CFAbsoluteTimeGetCurrent() }

    // MARK: - Statistics

    func p50(for kind: BudgetKind) -> Double? {
        let values = measurements.filter { $0.kind == kind }.map { $0.durationMs }.sorted()
        guard !values.isEmpty else { return nil }
        return values[values.count / 2]
    }

    func p95(for kind: BudgetKind) -> Double? {
        let values = measurements.filter { $0.kind == kind }.map { $0.durationMs }.sorted()
        guard values.count >= 2 else { return values.first }
        let idx = Int(Double(values.count) * 0.95)
        return values[min(idx, values.count - 1)]
    }

    func recentCount(for kind: BudgetKind) -> Int {
        measurements.filter { $0.kind == kind }.count
    }

    func budgetViolations(since date: Date = Date().addingTimeInterval(-3600)) -> [Measurement] {
        measurements.filter { $0.exceededBudget && $0.timestamp >= date }
    }

    func summaryReport() -> String {
        var lines = ["[LATENCY BUDGET SUMMARY]"]
        for kind in BudgetKind.allCases {
            guard let p50 = p50(for: kind), let p95 = p95(for: kind) else { continue }
            let target = Self.targets[kind] ?? 0
            let status = p95 > target ? "⚠" : "✓"
            lines.append("  \(status) \(kind.rawValue): p50=\(String(format:"%.0f",p50))ms p95=\(String(format:"%.0f",p95))ms budget=\(String(format:"%.0f",target))ms")
        }
        let violations = budgetViolations().count
        if violations > 0 { lines.append("  Budget violations (1h): \(violations)") }
        return lines.joined(separator: "\n")
    }
}
