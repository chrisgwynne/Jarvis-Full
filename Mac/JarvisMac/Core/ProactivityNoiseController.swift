import Foundation
import os

// MARK: - SuppressionDecision

struct SuppressionDecision {
    let shouldSuppress: Bool
    let reason: String
    let suggestBundle: Bool
}

// MARK: - ProactivityNoiseController

/// Anti-spam layer for proactive events. Tracks delivery history, enforces
/// per-key cooldowns, hourly rate caps, and per-source limits. Also builds
/// natural-language bundle text (replacing the robotic "Also: X, Y" pattern).
@MainActor
final class ProactivityNoiseController {

    static let shared = ProactivityNoiseController()

    private let log = Logger(subsystem: "com.jarvis", category: "proactivity.noise")

    // MARK: - Configuration

    var sameKeyMinIntervalSeconds: Double = 300       // 5 min per dedup key
    var semanticSimilarIntervalSeconds: Double = 120  // 2 min for similar content
    var maxEventsPerHour: Int = 8
    var maxSameSourcePerHour: Int = 3
    var frustrationMultiplier: Double = 2.0

    // MARK: - State

    private var lastDelivered: [String: Date] = [:]
    private var ignoredCount:  [String: Int]  = [:]
    private var deliveryLog:   [Date] = []
    private var sourceLog:     [String: [Date]] = [:]

    // MARK: - Evaluate

    func evaluate(
        signal: ProactivitySignal,
        context: AttentionContext,
        recentCount: Int
    ) -> SuppressionDecision {
        let multiplier = context.emotionalTone == .frustrated ? frustrationMultiplier : 1.0
        let key = signal.dedupeKey ?? signal.title

        // 1. Same dedup key within cooldown
        if let last = lastDelivered[key] {
            let elapsed = Date().timeIntervalSince(last)
            let required = sameKeyMinIntervalSeconds * multiplier
            if elapsed < required {
                log.debug("noise_suppress key=\(key) elapsed=\(Int(elapsed))s required=\(Int(required))s")
                return SuppressionDecision(
                    shouldSuppress: true,
                    reason: "same_key_cooldown",
                    suggestBundle: false
                )
            }
        }

        // 2. Hourly total rate cap
        let oneHourAgo = Date().addingTimeInterval(-3600)
        let recentTotal = deliveryLog.filter { $0 >= oneHourAgo }.count
        if recentTotal >= maxEventsPerHour {
            return SuppressionDecision(
                shouldSuppress: true,
                reason: "hourly_cap total=\(recentTotal)",
                suggestBundle: true
            )
        }

        // 3. Per-source rate cap
        let srcKey = signal.source.rawValue
        let recentSource = (sourceLog[srcKey] ?? []).filter { $0 >= oneHourAgo }.count
        if recentSource >= maxSameSourcePerHour {
            return SuppressionDecision(
                shouldSuppress: true,
                reason: "source_cap source=\(srcKey)",
                suggestBundle: recentCount >= 2
            )
        }

        // 4. Repeatedly ignored
        if (ignoredCount[key] ?? 0) >= 3 {
            return SuppressionDecision(
                shouldSuppress: true,
                reason: "repeatedly_ignored",
                suggestBundle: false
            )
        }

        return SuppressionDecision(shouldSuppress: false, reason: "ok", suggestBundle: false)
    }

    func markDelivered(_ signal: ProactivitySignal) {
        let key = signal.dedupeKey ?? signal.title
        lastDelivered[key] = Date()
        deliveryLog.append(Date())
        let src = signal.source.rawValue
        sourceLog[src, default: []].append(Date())
        pruneOldLogs()
    }

    func markIgnored(_ dedupeKey: String) {
        ignoredCount[dedupeKey, default: 0] += 1
    }

    // MARK: - Smart Bundling

    struct BundledSignals {
        let signals: [ProactivitySignal]
        let spokenText: String
    }

    /// Attempt to bundle pending signals into one natural-language utterance.
    /// Returns nil if fewer than 2 bundleable signals exist.
    func tryBundle(_ pending: [ProactivitySignal]) -> BundledSignals? {
        guard pending.count >= 2 else { return nil }
        let take = Array(pending.prefix(3))
        return BundledSignals(signals: take, spokenText: buildBundleText(from: take))
    }

    /// Build a natural-language bundle string.
    /// e.g. "Three quick things: the build finished, you've got a PR waiting, and your meeting's in ten."
    func buildBundleText(from signals: [ProactivitySignal]) -> String {
        guard !signals.isEmpty else { return "" }
        let items = signals.compactMap { sig -> String? in
            let raw = sig.spokenText ?? (sig.title.isEmpty ? nil : sig.title)
            return raw?.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        guard !items.isEmpty else { return "" }
        if items.count == 1 { return items[0] + "." }
        if items.count == 2 {
            return "Two things — \(items[0].lowercased()) and \(items[1].lowercased())."
        }
        let last = items.last!.lowercased()
        let rest = items.dropLast().map { $0.lowercased() }.joined(separator: ", ")
        return "\(items.count) quick things: \(rest), and \(last)."
    }

    // MARK: - Internal

    private func pruneOldLogs() {
        let cutoff = Date().addingTimeInterval(-7200)
        deliveryLog.removeAll { $0 < cutoff }
        for k in sourceLog.keys { sourceLog[k]?.removeAll { $0 < cutoff } }
    }
}
