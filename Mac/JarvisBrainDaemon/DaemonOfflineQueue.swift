import Foundation
import OSLog

private let queueLogger = Logger(subsystem: "com.jarvis.brain", category: "queue")

// MARK: - Queue entry (adds enqueue timestamp + reason for diagnostics)

private struct QueueEntry {
    let envelope: DaemonMessageEnvelope
    let enqueuedAt: Date
    let reason: String        // why this message was queued (for diagnostics)
}

// MARK: - DaemonOfflineQueue

/// Bounded in-memory queue for messages directed at the Mac app when it is offline.
/// Never persisted to disk. Never holds raw audio or images.
///
/// ## Replay-safety classification
///
/// Only message types that are SAFE to deliver after a Mac reconnect are queued.
/// "Safe" means: delivering the message late causes no harmful side effects.
///
/// SAFE to queue (Mac just missed it):
///   transcript.final    — user voice, Mac interprets it late (acceptable)
///   execution.result    — result of a past Android execution; Mac resolves its continuation
///   error.report        — informational, no action required
///
/// UNSAFE to queue — never queued, silently dropped when Mac is offline:
///   execution.request   — Mac wants Android to DO something; replaying later could re-execute
///                         a destructive action (send SMS, make call, navigate) without the
///                         user's current intent. Mac's AndroidToolOrchestrator will time out
///                         and surface an appropriate error.
///   orchestrate.speak   — time-sensitive; stale TTS is confusing
///   orchestrate.silent  — ordering signals; meaningless when stale
///   reply.final / reply.partial — already-answered conversational turns; replaying is disorienting
///   presence.update     — ephemeral sensor data; stale presence is wrong
///   transcript.partial  — ephemeral ASR intermediate; meaningless after session ends
///   proactive.notify    — time-sensitive; stale alerts are alarming
///   heartbeat.*         — transport keep-alive; never meaningful to queue
final class DaemonOfflineQueue {
    static let shared = DaemonOfflineQueue()

    private let maxDepth      = 50
    private let maxAgeSeconds: TimeInterval = 120   // 2-minute window; older = stale

    private var queue: [QueueEntry] = []
    private let lock = NSLock()

    // MARK: - Diagnostics

    private(set) var droppedCount: Int = 0
    private(set) var replayUnsafeDroppedCount: Int = 0
    private(set) var expiredEvictedCount: Int = 0

    // MARK: - Safe-to-queue classification

    /// Message types that are safe to deliver after a Mac reconnect.
    /// Everything NOT in this set is silently dropped when Mac is offline.
    private static let replaySafeTypes: Set<String> = [
        "transcript.final",
        "execution.result",     // canonical canonical result type
        "tool.result",          // legacy alias — kept for backward compat
        "command.result",       // legacy alias — kept for backward compat
        "error.report",
        "android.event",        // phone events (calls, SMS, battery) — informational
    ]

    /// Types that are explicitly UNSAFE to replay and should NEVER be queued,
    /// even if the caller tries to enqueue them.  Listed for documentation clarity.
    static let replayUnsafeTypes: Set<String> = [
        "execution.request",    // would re-execute Android capability (destructive!)
        "orchestrate.speak",
        "orchestrate.silent",
        "reply.final",
        "reply.partial",
        "presence.update",
        "transcript.partial",
        "proactive.notify",
        "heartbeat", "heartbeat.android", "ping", "pong",
    ]

    // MARK: - Enqueue

    func enqueue(_ envelope: DaemonMessageEnvelope, reason: String = "") {
        // Replay-safety gate: drop explicitly unsafe types immediately.
        if Self.replayUnsafeTypes.contains(envelope.type) {
            replayUnsafeDroppedCount += 1
            queueLogger.debug("offline queue: replay-unsafe type=\(envelope.type) — not queued")
            return
        }
        // Whitelist gate: only queue known-safe types.
        guard Self.replaySafeTypes.contains(envelope.type) else {
            queueLogger.debug("offline queue: unknown type=\(envelope.type) not in safe set — not queued")
            return
        }

        lock.withLock {
            evictExpired()
            if queue.count >= maxDepth {
                queue.removeFirst()
                droppedCount += 1
                queueLogger.warning("offline queue overflow — dropped oldest message, total dropped=\(self.droppedCount)")
            }
            queue.append(QueueEntry(envelope: envelope, enqueuedAt: Date(), reason: reason))
            queueLogger.debug("offline queue enqueued type=\(envelope.type) depth=\(self.queue.count)")
        }
    }

    // MARK: - Drain

    /// Drains all non-expired queued messages and returns them in FIFO order.
    /// Should only be called once per Mac reconnect — the caller is responsible
    /// for not calling drain() multiple times (which would replay entries twice).
    func drain() -> [DaemonMessageEnvelope] {
        lock.withLock {
            evictExpired()
            let result = queue.map { $0.envelope }
            queue = []
            queueLogger.info("offline queue drained \(result.count) messages")
            return result
        }
    }

    // MARK: - Diagnostics

    var depth: Int {
        lock.withLock {
            evictExpired()
            return queue.count
        }
    }

    /// Returns a human-readable snapshot for the diagnostics inspector.
    var diagnosticsSummary: String {
        lock.withLock {
            "depth=\(queue.count) dropped=\(droppedCount) replayUnsafeDropped=\(replayUnsafeDroppedCount) expiredEvicted=\(expiredEvictedCount)"
        }
    }

    // MARK: - Private helpers

    private func evictExpired() {
        let cutoff = Date().addingTimeInterval(-maxAgeSeconds)
        let before = queue.count
        queue.removeAll { $0.enqueuedAt < cutoff }
        let evicted = before - queue.count
        if evicted > 0 {
            expiredEvictedCount += evicted
            queueLogger.debug("offline queue evicted \(evicted) expired messages (total evicted=\(self.expiredEvictedCount))")
        }
    }
}
