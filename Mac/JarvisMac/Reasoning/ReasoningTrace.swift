import Foundation
import SwiftUI

// MARK: - IntentTrace

/// Full record of one command cycle: what was heard, matched, executed.
struct IntentTrace: Identifiable {
    let id: UUID
    let timestamp: Date
    // Input
    let transcript: String
    let intent: Intent
    // Context at time of command
    let activeApp: String
    let attentionState: AttentionState
    let operatingMode: OperatingMode
    let openOverlays: [String]   // overlay kind raw values
    let contextSummary: String   // snapshot from ContextEngine
    // Execution
    let actionSummary: String    // what was done
    let responseSpeaken: String  // text spoken (empty if silent)
    var memoryWrite: String?     // if a memory was saved
    var entityRefs: [String]     // entity IDs touched
    var error: String?

    init(transcript: String,
         intent: Intent,
         activeApp: String,
         attentionState: AttentionState,
         operatingMode: OperatingMode,
         openOverlays: [String],
         contextSummary: String,
         actionSummary: String,
         responseSpeaken: String) {
        self.id = UUID()
        self.timestamp = Date()
        self.transcript = transcript
        self.intent = intent
        self.activeApp = activeApp
        self.attentionState = attentionState
        self.operatingMode = operatingMode
        self.openOverlays = openOverlays
        self.contextSummary = contextSummary
        self.actionSummary = actionSummary
        self.responseSpeaken = responseSpeaken
        self.memoryWrite = nil
        self.entityRefs = []
        self.error = nil
    }

    /// Human-readable explanation for "why did you do that?"
    func explain() -> String {
        var parts: [String] = []
        parts.append("I heard: \"\(transcript)\"")
        parts.append("Matched: \(intentDescription)")
        if !activeApp.isEmpty {
            parts.append("Active app: \(activeApp)")
        }
        if !actionSummary.isEmpty {
            parts.append("Action: \(actionSummary)")
        }
        if let mem = memoryWrite {
            parts.append("Saved to memory: \(mem)")
        }
        if let err = error {
            parts.append("Error: \(err)")
        }
        return parts.joined(separator: "\n")
    }

    private var intentDescription: String {
        switch intent {
        case .openApp(let n):         return "open app '\(n)'"
        case .openURL(let u):         return "open URL \(u.host ?? u.absoluteString)"
        case .rememberThis(let t):    return "remember '\(t.prefix(40))'"
        case .homeTurnOn(let e):      return "turn on \(e)"
        case .homeTurnOff(let e):     return "turn off \(e)"
        case .homeQueryEntity(let e): return "query entity \(e)"
        case .unknown(let t):         return "unmatched '\(t.prefix(30))'"
        default:                      return "\(intent)"
        }
    }
}

// MARK: - ReasoningStore

/// Ring buffer of the last N intent traces. Thread-safe via @MainActor.
@Observable
@MainActor
final class ReasoningStore {

    private(set) var traces: [IntentTrace] = []
    private let limit = 50

    var lastTrace: IntentTrace? { traces.last }

    func record(_ trace: IntentTrace) {
        traces.append(trace)
        if traces.count > limit {
            traces.removeFirst(traces.count - limit)
        }
    }

    func explain(last n: Int = 1) -> String {
        let recent = traces.suffix(n)
        guard !recent.isEmpty else {
            return "No commands recorded yet."
        }
        return recent.map { $0.explain() }.joined(separator: "\n\n---\n\n")
    }
}

// MARK: - ReasoningOverlayView

struct ReasoningOverlayView: View {
    let store: ReasoningStore

    var body: some View {
        if store.traces.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(store.traces.reversed()) { trace in
                        traceCard(trace)
                    }
                }
                .padding(12)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "questionmark.bubble")
                .font(.title2).foregroundStyle(.secondary)
            Text("No commands yet")
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text("Issue a command to see reasoning.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func traceCard(_ trace: IntentTrace) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header row
            HStack(spacing: 8) {
                Circle().fill(Color.purple).frame(width: 6, height: 6)
                Text(trace.timestamp, style: .time)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(trace.attentionState.displayName)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(Color.purple.opacity(0.15)))
            }

            // Transcript
            Text("Heard: \"\(trace.transcript)\"")
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)

            // Intent
            Text("→ \(intentShort(trace.intent))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.purple)

            // Action
            if !trace.actionSummary.isEmpty {
                Text(trace.actionSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            // Error badge
            if let err = trace.error {
                Label(err, systemImage: "xmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }

            // Context strip
            HStack(spacing: 8) {
                if !trace.activeApp.isEmpty {
                    contextChip(trace.activeApp, color: .cyan)
                }
                if !trace.openOverlays.isEmpty {
                    contextChip(trace.openOverlays.joined(separator: "+"), color: .purple)
                }
                contextChip(trace.operatingMode.displayName, color: .secondary)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.purple.opacity(0.18))
        )
        .overlay(
            Rectangle().fill(Color.purple.opacity(0.35)).frame(width: 2),
            alignment: .leading
        )
    }

    private func intentShort(_ intent: Intent) -> String {
        switch intent {
        case .openApp(let n):   return "openApp(\(n))"
        case .openURL(let u):   return "openURL(\(u.host ?? "…"))"
        case .unknown(let t):   return "unknown(\(t.prefix(20)))"
        default:                return "\(intent)".prefix(30).description
        }
    }

    private func contextChip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.10)))
    }
}
