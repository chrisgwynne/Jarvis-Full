import Foundation
import OSLog

private let timelineLogger = Logger(subsystem: "com.jarvis.brain", category: "timeline")

// MARK: - TimelineEventKind

enum TimelineEventKind: String, Codable {
    case transcript       // user speech
    case reply            // assistant reply
    case remoteAction     // tool execution
    case fileTransfer     // file sent between devices
    case proactivePrompt  // daemon-initiated prompt
    case commEvent        // phone call/sms/whatsapp watchdog event
    case handoff          // cross-device handoff
    case presence         // presence state change (high-confidence only)
    case deviceConnect    // device connected
    case deviceDisconnect // device disconnected
    case agentJob         // daemon job ran
}

// MARK: - TimelineEvent

struct TimelineEvent: Codable {
    let id: String
    let kind: TimelineEventKind
    let deviceId: String
    let platform: String      // "android" | "mac" | "windows" | "daemon"
    let timestamp: Date
    let summary: String       // SHORT human-readable (max 200 chars, already redacted)
    let tags: [String]        // for search: ["phone", "alice"] etc.
}

// MARK: - DaemonTimeline

/// Bounded, searchable cross-device event log. Keeps the last 500 events in memory.
/// Privacy-aware: redacts sensitive fields on append.
final class DaemonTimeline {
    static let shared = DaemonTimeline()
    private init() {}

    private let maxEvents = 500
    private var events: [TimelineEvent] = []
    private let lock = NSLock()

    // MARK: - Append

    /// Appends an event to the timeline. Enforces privacy rules and capacity limits.
    func append(kind: TimelineEventKind,
                deviceId: String,
                platform: String,
                summary: String,
                tags: [String] = []) {
        let cleanSummary = sanitize(summary: summary)
        let cleanTags = sanitize(tags: tags)

        guard !cleanSummary.isEmpty else {
            timelineLogger.debug("timeline: dropping event — empty summary after sanitization kind=\(kind.rawValue)")
            return
        }

        let event = TimelineEvent(
            id: UUID().uuidString,
            kind: kind,
            deviceId: deviceId,
            platform: platform,
            timestamp: Date(),
            summary: cleanSummary,
            tags: cleanTags
        )

        lock.withLock {
            events.append(event)
            if events.count > maxEvents {
                let overflow = events.count - maxEvents
                events.removeFirst(overflow)
            }
        }

        timelineLogger.debug("timeline: appended kind=\(kind.rawValue) deviceId=\(deviceId) summary=\(cleanSummary)")
    }

    // MARK: - Query: recent

    /// Returns recent events (newest first), optionally filtered by kind or tag.
    func recent(limit: Int = 50,
                kind: TimelineEventKind? = nil,
                tag: String? = nil) -> [TimelineEvent] {
        lock.withLock {
            var result = events

            if let kindFilter = kind {
                result = result.filter { $0.kind == kindFilter }
            }
            if let tagFilter = tag {
                let lower = tagFilter.lowercased()
                result = result.filter { $0.tags.contains { $0.lowercased() == lower } }
            }

            // Reverse for newest-first, then take limit
            return Array(result.reversed().prefix(limit))
        }
    }

    // MARK: - Query: search

    /// Simple text search over summaries and tags (case-insensitive).
    func search(query: String, limit: Int = 20) -> [TimelineEvent] {
        guard !query.isEmpty else { return recent(limit: limit) }
        let lower = query.lowercased()

        return lock.withLock {
            events
                .reversed()
                .filter { event in
                    event.summary.lowercased().contains(lower) ||
                    event.tags.contains { $0.lowercased().contains(lower) }
                }
                .prefix(limit)
                .map { $0 }  // collapse the slice to Array
        }
    }

    // MARK: - Diagnostics

    var count: Int {
        lock.withLock { events.count }
    }

    var diagnosticsSummary: String {
        lock.withLock {
            guard !events.isEmpty else { return "events=0" }
            let now = Date()
            let oldestAge = now.timeIntervalSince(events.first!.timestamp)
            let newestAge = now.timeIntervalSince(events.last!.timestamp)
            return "events=\(events.count) oldest=\(formatAge(oldestAge)) newest=\(formatAge(newestAge))"
        }
    }

    // MARK: - Private: sanitization

    /// Enforces privacy rules on the summary string:
    /// - Max 200 characters (truncated if longer)
    /// - Must not contain raw phone numbers (7+ consecutive digits)
    ///   (masked forms like ****1234 are accepted)
    private func sanitize(summary: String) -> String {
        var s = summary

        // Truncate to 200 chars
        if s.count > 200 {
            s = String(s.prefix(200))
        }

        // Reject summaries containing 7+ consecutive unmasked digits (raw phone numbers)
        if containsRawPhoneNumber(s) {
            timelineLogger.warning("timeline: redacted summary containing raw phone number")
            // Redact the digits but preserve the rest
            s = redactDigitRuns(in: s)
            // If still too long after redaction, truncate again
            if s.count > 200 { s = String(s.prefix(200)) }
        }

        return s
    }

    /// Enforces tag constraints: max 10 tags, each max 50 chars.
    private func sanitize(tags: [String]) -> [String] {
        Array(tags.prefix(10)).map { tag in
            tag.count > 50 ? String(tag.prefix(50)) : tag
        }
    }

    /// Returns true if the string contains 7 or more consecutive ASCII digits
    /// that are NOT part of a masked pattern (****NNNN).
    private func containsRawPhoneNumber(_ s: String) -> Bool {
        // We look for 7+ consecutive digits NOT preceded by asterisks
        // A simple heuristic: find runs of ≥7 digits
        var consecutiveDigits = 0
        for ch in s {
            if ch.isNumber {
                consecutiveDigits += 1
                if consecutiveDigits >= 7 {
                    return true
                }
            } else {
                consecutiveDigits = 0
            }
        }
        return false
    }

    /// Redacts runs of 7+ consecutive digits with [REDACTED].
    private func redactDigitRuns(in s: String) -> String {
        // Use a simple state machine to replace runs of 7+ digits
        var result = ""
        var digitBuffer = ""
        for ch in s {
            if ch.isNumber {
                digitBuffer.append(ch)
            } else {
                if digitBuffer.count >= 7 {
                    result += "[REDACTED]"
                } else {
                    result += digitBuffer
                }
                digitBuffer = ""
                result.append(ch)
            }
        }
        // Flush remaining buffer
        if digitBuffer.count >= 7 {
            result += "[REDACTED]"
        } else {
            result += digitBuffer
        }
        return result
    }

    // MARK: - Private: formatting

    private func formatAge(_ seconds: TimeInterval) -> String {
        if seconds < 60    { return "\(Int(seconds))s ago" }
        if seconds < 3600  { return "\(Int(seconds / 60))m ago" }
        return "\(Int(seconds / 3600))h ago"
    }
}
