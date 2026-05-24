import Foundation
import CryptoKit
import Observation
import os

// MARK: - ProactiveNotificationRecord

/// Persisted record of a proactivity signal that has been seen or spoken.
/// Stored by `dedupeKey` so repeated ingestion of the same story is detected
/// across app launches.
struct ProactiveNotificationRecord: Codable, Identifiable {
    var id: UUID
    /// Stable identifier for the signal (URL or normalised title for news).
    let dedupeKey: String
    /// SHA-256 hex of the signal title (lowercased + trimmed).
    /// A changed title hash = a material change, allowing re-announcement.
    var titleHash: String
    /// SHA-256 hex of the signal body. Used as secondary change indicator.
    var contentHash: String?
    /// `SignalSource.rawValue` of the originating integration.
    let source: String
    let category: String
    /// `SignalPriority.rawValue` (1 = low … 5 = critical).  Stored so we can
    /// detect priority escalation (new > stored = material change).
    var priority: Int
    let firstSeenAt: Date
    var lastSeenAt: Date
    /// `nil` means the signal was queued / shown in the tray but never spoken.
    var lastAnnouncedAt: Date?
    var announceCount: Int
    /// True if TTS was triggered for this signal at any point.
    var wasSpoken: Bool
    /// True if the user opened the associated overlay / article.
    var wasOpened: Bool
    /// True if the user explicitly dismissed this signal. Dismissed signals
    /// are suppressed indefinitely unless priority escalates to urgent/critical.
    var wasDismissed: Bool
    var expirationDate: Date?

    init(
        id: UUID = UUID(),
        dedupeKey: String,
        titleHash: String,
        contentHash: String? = nil,
        source: String,
        category: String,
        priority: Int,
        firstSeenAt: Date = Date(),
        lastSeenAt: Date = Date(),
        lastAnnouncedAt: Date? = nil,
        announceCount: Int = 0,
        wasSpoken: Bool = false,
        wasOpened: Bool = false,
        wasDismissed: Bool = false,
        expirationDate: Date? = nil
    ) {
        self.id             = id
        self.dedupeKey      = dedupeKey
        self.titleHash      = titleHash
        self.contentHash    = contentHash
        self.source         = source
        self.category       = category
        self.priority       = priority
        self.firstSeenAt    = firstSeenAt
        self.lastSeenAt     = lastSeenAt
        self.lastAnnouncedAt = lastAnnouncedAt
        self.announceCount  = announceCount
        self.wasSpoken      = wasSpoken
        self.wasOpened      = wasOpened
        self.wasDismissed   = wasDismissed
        self.expirationDate = expirationDate
    }
}

// MARK: - ShouldAnnounceResult

/// Decision returned by `ProactiveNotificationStore.shouldAnnounce(_:)`.
enum ShouldAnnounceResult {
    /// Never seen before — let the engine proceed normally.
    case announce
    /// Material change (title, content, or priority escalation) — allow re-alert.
    case reannounce(reason: String)
    /// Already spoken within spoken cooldown, no material change, or dismissed.
    /// Signal should be silently ignored (no TTS, no overlay re-open).
    case suppress(reason: String)
}

// MARK: - ProactiveNotificationStore

/// Persistent cross-session deduplication for `ProactivitySignal` values.
///
/// Solves the most common proactivity noise problem: the same breaking news
/// headline being re-spoken every time the app launches, because the in-memory
/// `announcedKeys` set in `ProactivityEngine` is cleared on restart.
///
/// **Flow:**
///  1. On `ingest()`, `ProactivityEngine` calls `shouldAnnounce(_:)`.
///  2. Result drives whether the engine produces `.speakNow`, `.showQuietly`,
///     or `.ignore`.
///  3. After speaking, `markSpoken(_:)` records the timestamp to disk.
///  4. On next launch, the store is rehydrated — repeated stories are blocked.
///
/// **Cooldowns (persistent, longer than engine's in-session cooldowns):**
///  - Breaking / urgent news :  6 h  (spoken)
///  - Normal news            : 24 h  (spoken)
///  - Weather                :  6 h
///  - GitHub / Todoist       :  4 h
///  - Shopify                :  2 h
///  - Calendar               : 30 min  (time-sensitive)
///  - Home Assistant         :  1 h
///  - System                 :  1 h
///  - Default                :  6 h
///
/// **Material change detection:**
///  - Title SHA-256 differs → `.reannounce(reason: "title_changed")`
///  - Priority escalates beyond stored level → `.reannounce(reason: "priority_escalated")`
///  - Body/content hash differs (secondary) → `.reannounce(reason: "content_changed")`
///
/// Persists to `~/Library/Application Support/JarvisMac/proactive-history.json`.
@Observable
@MainActor
final class ProactiveNotificationStore {

    // MARK: - Public state

    private(set) var records: [String: ProactiveNotificationRecord] = [:]

    // MARK: - Private

    private let fileURL: URL
    private let log = Logger(subsystem: "com.jarvis", category: "proactive.store")

    // MARK: - Cooldown table (spoken cooldowns, in seconds)

    private static let sourceCooldowns: [String: TimeInterval] = [
        SignalSource.news.rawValue:          6  * 3600,   // 6 h  (urgent/breaking news)
        SignalSource.github.rawValue:        4  * 3600,
        SignalSource.todoist.rawValue:       4  * 3600,
        SignalSource.shopify.rawValue:       2  * 3600,
        SignalSource.calendar.rawValue:      30 * 60,      // 30 min (time-sensitive)
        SignalSource.homeAssistant.rawValue: 1  * 3600,
        SignalSource.system.rawValue:        1  * 3600,    // also covers weather alerts
        SignalSource.email.rawValue:         4  * 3600,
        SignalSource.memory.rawValue:        4  * 3600,
        SignalSource.obsidian.rawValue:      4  * 3600,
    ]

    /// Normal (non-breaking) news has a longer spoken cooldown.
    private static let normalNewsSpokenCooldown: TimeInterval = 24 * 3600

    /// Max age of a record before it is eligible for auto-purge.
    private static let maxRecordAge: TimeInterval = 7 * 24 * 3600   // 7 days
    /// Dismissed records are kept longer so the dismissal is remembered.
    private static let dismissedRetentionAge: TimeInterval = 30 * 24 * 3600  // 30 days

    // MARK: - Init

    init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("JarvisMac", isDirectory: true)
        fileURL = dir.appendingPathComponent("proactive-history.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
        purgeExpired()
    }

    // MARK: - Main Decision

    /// Ask whether a new incoming signal should be announced.
    ///
    /// Call this *before* the engine produces a `.speakNow` decision.
    /// The engine should respect the result as follows:
    ///  - `.announce`          → proceed normally
    ///  - `.reannounce(reason)` → clear in-memory dedupe; proceed normally
    ///  - `.suppress(reason)`  → return `.ignore` (or at most `.showQuietly`)
    func shouldAnnounce(_ signal: ProactivitySignal) -> ShouldAnnounceResult {
        let key           = signal.dedupeKey
        let newTitleHash  = Self.sha256(signal.title)
        let newBodyHash   = Self.sha256(signal.body)
        let newPriority   = signal.priority.rawValue

        // ── Never seen before ────────────────────────────────────────────────
        guard let record = records[key] else {
            return .announce
        }

        // ── Dismissed signals ────────────────────────────────────────────────
        // Suppress indefinitely unless priority escalates to urgent/critical.
        if record.wasDismissed {
            if newPriority >= SignalPriority.urgent.rawValue
                && newPriority > record.priority {
                return .reannounce(reason: "priority_escalated_past_dismissed")
            }
            return .suppress(reason: "dismissed")
        }

        // ── Priority escalation ──────────────────────────────────────────────
        if newPriority > record.priority {
            return .reannounce(reason: "priority_escalated")
        }

        // ── Title changed (material change) ─────────────────────────────────
        if record.titleHash != newTitleHash {
            return .reannounce(reason: "title_changed")
        }

        // ── Never been spoken (only shown in tray) ───────────────────────────
        // Don't force-speak old tray-only signals on re-ingestion, but allow
        // the engine to decide their tray fate as normal.
        guard record.wasSpoken, let lastAnnounced = record.lastAnnouncedAt else {
            return .suppress(reason: "seen_not_spoken")
        }

        // ── Spoken cooldown ──────────────────────────────────────────────────
        let cooldown = Self.spokenCooldown(for: signal)
        let elapsed  = Date().timeIntervalSince(lastAnnounced)

        if elapsed < cooldown {
            let remainingH = Int((cooldown - elapsed) / 3600)
            let remainingM = Int(((cooldown - elapsed).truncatingRemainder(dividingBy: 3600)) / 60)
            let desc = remainingH > 0 ? "\(remainingH)h" : "\(remainingM)m"
            return .suppress(reason: "cooldown_\(desc)_remaining")
        }

        // ── Cooldown expired but content same ────────────────────────────────
        // Body content changed after cooldown → allow re-announce.
        if record.contentHash != newBodyHash {
            return .reannounce(reason: "content_changed_cooldown_expired")
        }

        // Cooldown fully expired, no change → normal engine flow.
        return .announce
    }

    // MARK: - Recording

    /// Record that a signal was processed. Call for every signal that reaches
    /// `addToPending()` so the store tracks even tray-only events.
    /// - Parameter wasSpoken: `true` only if `markSpoken()` was also called.
    func record(_ signal: ProactivitySignal, wasSpoken: Bool) {
        let key = signal.dedupeKey
        let now = Date()

        if var existing = records[key] {
            existing.lastSeenAt  = now
            existing.titleHash   = Self.sha256(signal.title)
            existing.contentHash = Self.sha256(signal.body)
            existing.priority    = max(existing.priority, signal.priority.rawValue)
            if wasSpoken {
                existing.lastAnnouncedAt = now
                existing.wasSpoken       = true
                existing.announceCount  += 1
            }
            records[key] = existing
        } else {
            records[key] = ProactiveNotificationRecord(
                dedupeKey:       key,
                titleHash:       Self.sha256(signal.title),
                contentHash:     Self.sha256(signal.body),
                source:          signal.source.rawValue,
                category:        signal.category,
                priority:        signal.priority.rawValue,
                firstSeenAt:     now,
                lastSeenAt:      now,
                lastAnnouncedAt: wasSpoken ? now : nil,
                announceCount:   wasSpoken ? 1 : 0,
                wasSpoken:       wasSpoken,
                expirationDate:  signal.expiresAt
            )
        }
        save()
    }

    /// Mark a signal as dismissed by the user.
    /// Dismissed signals are suppressed indefinitely (unless priority escalates).
    func markDismissed(_ dedupeKey: String) {
        guard var rec = records[dedupeKey] else { return }
        rec.wasDismissed = true
        rec.lastSeenAt   = Date()
        records[dedupeKey] = rec
        log.debug("Marked dismissed: \(dedupeKey.prefix(60))")
        save()
    }

    /// Mark a signal as opened (user tapped into its overlay/article).
    func markOpened(_ dedupeKey: String) {
        guard var rec = records[dedupeKey] else { return }
        rec.wasOpened  = true
        rec.lastSeenAt = Date()
        records[dedupeKey] = rec
        save()
    }

    // MARK: - Diagnostics

    /// Returns a human-readable diagnostic for a given dedupeKey, or nil if unknown.
    func diagnostic(for dedupeKey: String) -> ProactiveNotificationDiagnostic? {
        guard let rec = records[dedupeKey] else { return nil }
        let cooldown = Self.spokenCooldown(
            source: SignalSource(rawValue: rec.source) ?? .system,
            priority: SignalPriority(rawValue: rec.priority) ?? .normal
        )
        var suppressionReason = "not_suppressed"
        var isSuppressed = false
        if rec.wasDismissed {
            suppressionReason = "dismissed"; isSuppressed = true
        } else if let last = rec.lastAnnouncedAt,
                  Date().timeIntervalSince(last) < cooldown {
            let rem = Int((cooldown - Date().timeIntervalSince(last)) / 3600)
            suppressionReason = "cooldown_\(rem)h_remaining"; isSuppressed = true
        } else if !rec.wasSpoken {
            suppressionReason = "seen_not_spoken"; isSuppressed = true
        }
        return ProactiveNotificationDiagnostic(
            dedupeKey:        dedupeKey,
            titleHash:        rec.titleHash,
            source:           rec.source,
            firstSeen:        rec.firstSeenAt,
            lastAnnounced:    rec.lastAnnouncedAt,
            announceCount:    rec.announceCount,
            wasSpoken:        rec.wasSpoken,
            wasOpened:        rec.wasOpened,
            wasDismissed:     rec.wasDismissed,
            isSuppressed:     isSuppressed,
            suppressionReason: suppressionReason,
            contentHashChanged: false           // set dynamically when comparing
        )
    }

    // MARK: - Maintenance

    func purgeExpired() {
        let now = Date()
        let normalCutoff    = now.addingTimeInterval(-Self.maxRecordAge)
        let dismissedCutoff = now.addingTimeInterval(-Self.dismissedRetentionAge)
        let before = records.count

        records = records.filter { _, rec in
            if rec.wasDismissed { return rec.lastSeenAt > dismissedCutoff }
            return rec.lastSeenAt > normalCutoff
        }

        if records.count != before {
            log.debug("Purged \(before - self.records.count) expired notification records")
            save()
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            records = try JSONDecoder().decode([String: ProactiveNotificationRecord].self, from: data)
            log.debug("Loaded \(self.records.count) proactive notification records")
        } catch {
            log.error("Failed to decode proactive-history.json: \(error.localizedDescription)")
        }
    }

    func save() {
        let snapshot = records
        let dest = fileURL
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: dest, options: .atomic)
        }
    }

    // MARK: - Cooldown helpers

    static func spokenCooldown(for signal: ProactivitySignal) -> TimeInterval {
        spokenCooldown(source: signal.source, priority: signal.priority)
    }

    static func spokenCooldown(source: SignalSource, priority: SignalPriority) -> TimeInterval {
        // Normal (non-breaking) news has a longer cooldown than urgent/high news.
        if source == .news && priority <= .high {
            return normalNewsSpokenCooldown
        }
        return sourceCooldowns[source.rawValue] ?? 6 * 3600
    }

    // MARK: - Hashing

    static func sha256(_ text: String) -> String {
        let normalised = text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = SHA256.hash(data: Data(normalised.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Diagnostic model

/// Human-readable diagnostic for a persisted notification record.
/// Exposed to `DebugHUDView` and the proactivity settings panel.
struct ProactiveNotificationDiagnostic {
    let dedupeKey: String
    let titleHash: String
    let source: String
    let firstSeen: Date
    let lastAnnounced: Date?
    let announceCount: Int
    let wasSpoken: Bool
    let wasOpened: Bool
    let wasDismissed: Bool
    let isSuppressed: Bool
    let suppressionReason: String
    let contentHashChanged: Bool
}
