import Foundation

// MARK: - TraceRedactor

/// Scrubs sensitive patterns from trace detail strings before they are stored.
/// Patterns are conservative — only clear secrets and credential-shaped strings,
/// not general text. Redaction happens at ingestion so all storage paths are safe.
enum TraceRedactor {

    // Maximum number of characters kept in a detail string (applied after redaction).
    static let maxDetailLength = 500

    static func redact(_ text: String?) -> String? {
        guard let text else { return nil }
        var out = text

        // Order matters: most-specific patterns first.
        let patterns: [(pattern: String, replacement: String)] = [
            // "Bearer <token>" — OAuth/JWT authorization headers
            (#"(?i)bearer\s+[A-Za-z0-9\-._~+/]+=*"#,                  "Bearer [REDACTED]"),
            // "Authorization: <value>" / "auth_token: <value>" / "api_key: <value>"
            (#"(?i)(authorization|auth[\s_-]?token|api[\s_-]?key)\s*[:=]\s*\S+"#,
                                                                        "$1: [REDACTED]"),
            // sk- prefixed keys (OpenAI-style API keys)
            (#"\bsk-[A-Za-z0-9]{20,}\b"#,                              "sk-[REDACTED]"),
            // GitHub personal access tokens (ghp_ / github_pat_ prefixes)
            (#"\b(ghp_|github_pat_)[A-Za-z0-9_]{20,}\b"#,             "$1[REDACTED]"),
            // Hex strings >= 40 chars (avoids false-positives on standard 32-char UUIDs).
            // Catches most raw API tokens, SHA-256 hashes, and bearer credential bytes.
            (#"\b[0-9a-fA-F]{40,}\b"#,                                 "[REDACTED_HEX]"),
            // Base64-like strings >= 40 chars (potential tokens / encoded secrets).
            // Requires at least one non-alphanumeric base64 char (+/=) to reduce noise
            // on long plain-text words.
            (#"\b[A-Za-z0-9+/]{40,}={0,2}\b"#,                        "[REDACTED_B64]"),
        ]

        for (pattern, replacement) in patterns {
            // try? — a malformed pattern must never crash the app.
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(out.startIndex..., in: out)
                out = regex.stringByReplacingMatches(in: out, range: range,
                                                      withTemplate: replacement)
            }
        }

        // Truncate AFTER redaction so a token near the 500-char boundary is still caught.
        return String(out.prefix(maxDetailLength))
    }
}

// MARK: - TraceStep

/// A single step in an execution chain.
struct TraceStep: Identifiable, Sendable {
    let id: UUID = UUID()
    let name: String
    let at: Date
    // Redacted at ingestion by TraceRedactor. Max 500 chars.
    // Do not use for raw API responses or full prompt text.
    let detail: String?
    let runtimeID: String   // which runtime produced this step

    var ageMs: Int { Int(Date().timeIntervalSince(at) * 1000) }
}

// MARK: - ExecutionTrace

/// A causal chain from user command through intent → actions → response.
/// All steps share a correlationID that can be used to filter EventStore.
struct ExecutionTrace: Identifiable {
    let id: UUID            // same as correlationID for EventStore linking
    let correlationID: UUID
    let label: String       // e.g. "call Cath" or "show news"
    let startedAt: Date
    private(set) var steps: [TraceStep] = []
    var completedAt: Date? = nil

    var isComplete: Bool { completedAt != nil }
    var durationMs: Int {
        let end = completedAt ?? Date()
        return Int(end.timeIntervalSince(startedAt) * 1000)
    }

    mutating func addStep(name: String, detail: String? = nil, runtimeID: String = "controller") {
        steps.append(TraceStep(name: name, at: Date(), detail: detail, runtimeID: runtimeID))
    }

    mutating func complete() {
        completedAt = Date()
    }

    var summary: String {
        steps.map { $0.name }.joined(separator: " → ")
    }
}

// MARK: - ExecutionTracer

/// Manages the active execution trace and a bounded history of recent traces.
/// Traces are keyed by correlationID so SystemBus events can be linked.
@MainActor
final class ExecutionTracer {

    static let shared = ExecutionTracer()

    private let capacity = 50
    private(set) var history: [ExecutionTrace] = []
    private(set) var activeTrace: ExecutionTrace?

    // MARK: - Lifecycle

    /// Begin a new execution trace. Returns the correlationID to pass through the call chain.
    @discardableResult
    func begin(label: String) -> UUID {
        // Complete any previous trace that wasn't closed
        if var prev = activeTrace, !prev.isComplete {
            prev.complete()
            archive(prev)
        }

        let correlationID = UUID()
        activeTrace = ExecutionTrace(
            id: correlationID,
            correlationID: correlationID,
            label: label,
            startedAt: Date()
        )
        return correlationID
    }

    /// Add a step to the active trace.
    /// `detail` is redacted by `TraceRedactor` before storage — do not rely on
    /// raw secret values being preserved here.
    func addStep(_ name: String, detail: String? = nil, runtimeID: String = "controller") {
        guard activeTrace != nil else { return }
        let safeDetail = TraceRedactor.redact(detail)
        activeTrace!.addStep(name: name, detail: safeDetail, runtimeID: runtimeID)
    }

    /// Close the active trace.
    func complete() {
        guard var trace = activeTrace else { return }
        trace.complete()
        archive(trace)
        activeTrace = nil
    }

    /// Close the active trace and begin a fresh one with the same label continuation.
    func completeAndBegin(label: String) -> UUID {
        complete()
        return begin(label: label)
    }

    // MARK: - History

    private func archive(_ trace: ExecutionTrace) {
        history.insert(trace, at: 0)
        if history.count > capacity {
            history = Array(history.prefix(capacity))
        }
    }

    func recentTraces(limit: Int = 10) -> [ExecutionTrace] {
        Array(history.prefix(limit))
    }

    var activeCorrelationID: UUID? { activeTrace?.correlationID }
}
