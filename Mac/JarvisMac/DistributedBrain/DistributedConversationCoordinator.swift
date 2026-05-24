import Foundation

// MARK: - DistributedConversationCoordinator

/// Maintains ONE shared conversation thread across all connected devices.
/// Mac is the authority — it owns the session, assigns sequence numbers,
/// and merges turns from all surfaces. Windows never has its own memory.
@MainActor
final class DistributedConversationCoordinator {

    static let shared = DistributedConversationCoordinator()

    // MARK: - State

    private(set) var sessionId: String?
    private(set) var sessionStartedAt: Date?
    private(set) var frames: [ConversationFrame] = []
    private var seenFrameIds: Set<String> = []
    private var macSequenceNumber: Int = 0

    private static let maxFrames = 40
    private static let recentWindowSeconds: Double = 300

    // MARK: - Session lifecycle

    func beginSession(initiatingDeviceId: String) {
        sessionId = UUID().uuidString
        sessionStartedAt = Date()
        frames = []
        seenFrameIds = []
        macSequenceNumber = 0
    }

    func endSession() {
        sessionId = nil
        sessionStartedAt = nil
    }

    var isActive: Bool { sessionId != nil }

    // MARK: - Frame ingestion

    /// Ingests a turn from any device. Returns false if this is a duplicate (replay protection).
    @discardableResult
    func ingest(_ frame: ConversationFrame) -> Bool {
        guard !seenFrameIds.contains(frame.id) else { return false }
        seenFrameIds.insert(frame.id)

        macSequenceNumber += 1
        frames.append(frame)
        if frames.count > Self.maxFrames {
            frames.removeFirst(frames.count - Self.maxFrames)
        }
        return true
    }

    /// Convenience: record a Mac-originated user turn.
    func recordMacUserTurn(_ transcript: String, intentLabel: String? = nil) {
        let frame = ConversationFrame(
            id: UUID().uuidString,
            deviceId: "mac",
            role: .user,
            transcript: transcript,
            timestamp: Date(),
            sequenceNumber: macSequenceNumber + 1,
            intentLabel: intentLabel,
            emotionalTone: nil
        )
        ingest(frame)
    }

    /// Convenience: record a Mac-originated assistant turn.
    func recordMacAssistantTurn(_ text: String) {
        let frame = ConversationFrame(
            id: UUID().uuidString,
            deviceId: "mac",
            role: .assistant,
            transcript: text,
            timestamp: Date(),
            sequenceNumber: macSequenceNumber + 1,
            intentLabel: nil,
            emotionalTone: nil
        )
        ingest(frame)
    }

    // MARK: - Context block

    /// Returns a `[DISTRIBUTED DIALOGUE]` block for LLM injection.
    func buildContextBlock(limit: Int = 8) -> String {
        guard !frames.isEmpty else { return "" }
        let cutoff = Date().addingTimeInterval(-Self.recentWindowSeconds)
        let recent = frames
            .filter { $0.timestamp >= cutoff }
            .suffix(limit)
        guard !recent.isEmpty else { return "" }
        var lines: [String] = ["[DISTRIBUTED DIALOGUE]"]
        for f in recent {
            let prefix = f.deviceId == "mac" ? "" : "[\(f.deviceId)] "
            let roleLabel = f.role == .user ? "user" : "assistant"
            lines.append("\(roleLabel): \(prefix)\(f.transcript)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Reference hints

    /// Returns the most recent Windows-sourced user turn transcript (for reference resolution).
    func latestWindowsUserTranscript() -> String? {
        frames
            .filter { $0.deviceId != "mac" && $0.role == .user }
            .last?.transcript
    }

    // MARK: - Sync state

    func syncState() -> SessionSyncState? {
        guard let sid = sessionId, let startedAt = sessionStartedAt else { return nil }
        return SessionSyncState(
            sessionId: sid,
            startedAt: startedAt,
            participantCount: Set(frames.map(\.deviceId)).count,
            lastSequenceNumber: frames.last?.sequenceNumber ?? 0,
            macSequenceNumber: macSequenceNumber,
            diverged: false
        )
    }
}
