import Foundation

// MARK: - DistributedFallbackCoordinator

/// Handles disconnects, reconnects, and replay protection for the distributed
/// session. Ensures frames are not processed twice and that queued frames are
/// replayed in order after a reconnect.
@MainActor
final class DistributedFallbackCoordinator {

    static let shared = DistributedFallbackCoordinator()

    // MARK: - Config

    private static let seenCap = 500       // max de-dup entries
    private static let queueCap = 50       // max frames buffered during disconnect
    private static let divergenceThreshold = 5  // sequence gap that triggers a warning

    // MARK: - State

    private var seenFrameIds: [String] = []          // LRU order
    private var seenSet: Set<String> = []

    private var disconnectedDevices: Set<String> = []
    private var replayQueue: [String: [ConversationFrame]] = [:]  // deviceId → queued frames

    // MARK: - Replay protection

    /// Returns true if the frame should be accepted (first time seen).
    /// Marks the frameId as seen on true.
    func canAccept(_ frameId: String) -> Bool {
        guard !seenSet.contains(frameId) else { return false }
        seenSet.insert(frameId)
        seenFrameIds.append(frameId)
        if seenFrameIds.count > Self.seenCap {
            let removed = seenFrameIds.removeFirst()
            seenSet.remove(removed)
        }
        return true
    }

    // MARK: - Disconnect / reconnect

    func markDisconnected(_ deviceId: String) {
        disconnectedDevices.insert(deviceId)
        replayQueue[deviceId] = []
    }

    func markReconnected(_ deviceId: String) -> [ConversationFrame] {
        disconnectedDevices.remove(deviceId)
        let queued = replayQueue.removeValue(forKey: deviceId) ?? []
        return queued  // caller should ingest these in order
    }

    func isDisconnected(_ deviceId: String) -> Bool {
        disconnectedDevices.contains(deviceId)
    }

    /// Queues a frame during disconnect for replay on reconnect.
    /// Returns false if the queue is full (frame dropped — caller should log).
    @discardableResult
    func buffer(_ frame: ConversationFrame, for deviceId: String) -> Bool {
        guard var q = replayQueue[deviceId] else { return false }
        guard q.count < Self.queueCap else { return false }
        q.append(frame)
        replayQueue[deviceId] = q
        return true
    }

    // MARK: - Divergence detection

    /// Detects if the Mac sequence number and a remote device's reported sequence
    /// have diverged beyond the safe threshold. Returns true if diverged.
    func sessionDivergenceCheck(macSequence: Int, remoteSequence: Int) -> Bool {
        abs(macSequence - remoteSequence) > Self.divergenceThreshold
    }

    // MARK: - Diagnostics

    var bufferedFrameCount: Int { replayQueue.values.reduce(0) { $0 + $1.count } }
    var disconnectedCount: Int { disconnectedDevices.count }
    var seenCount: Int { seenSet.count }

    var oneLiner: String {
        var parts: [String] = []
        if disconnectedDevices.isEmpty {
            parts.append("all connected")
        } else {
            parts.append("disconnected: \(disconnectedDevices.joined(separator: ","))")
        }
        if bufferedFrameCount > 0 { parts.append("queued=\(bufferedFrameCount)") }
        return parts.joined(separator: " · ")
    }
}
