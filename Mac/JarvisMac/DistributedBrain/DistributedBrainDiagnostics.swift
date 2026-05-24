import Foundation
import Observation

// MARK: - DistributedBrainDiagnostics

/// Observable diagnostics for the distributed brain layer.
/// Surfaced in RuntimeDiagnosticsOverlayView and MacBrainSettingsView.
@Observable
@MainActor
final class DistributedBrainDiagnostics {

    static let shared = DistributedBrainDiagnostics()

    // MARK: - Metrics

    var connectedDevices: [DeviceParticipant] = []
    var lastFrameReceivedAt: Date?
    var lastPresenceUpdateAt: Date?
    var framesIngested: Int = 0
    var framesRejected: Int = 0    // duplicates
    var leaseAcquisitions: Int = 0
    var leasePreemptions: Int = 0
    var sessionDivergenceEvents: Int = 0
    var executionRequestsSent: Int = 0
    var executionResultsReceived: Int = 0
    var wsClientsConnected: Int = 0
    var replayFramesIngested: Int = 0
    var activeReplaySessions: Int = 0

    // Bridge latency ring buffer (last 100 samples, ms)
    private var latencySamples: [Double] = []
    private static let latencyCap = 100
    var p50LatencyMs: Double? { percentile(0.50) }
    var p95LatencyMs: Double? { percentile(0.95) }

    // Transcript roundtrip (user speaks on Windows → Mac processes → reply sent back)
    var lastRoundtripMs: Double?

    // MARK: - Recording

    func recordFrame(accepted: Bool) {
        if accepted {
            framesIngested += 1
            lastFrameReceivedAt = Date()
        } else {
            framesRejected += 1
        }
    }

    func recordPresenceUpdate() { lastPresenceUpdateAt = Date() }

    func recordLeaseAcquisition() { leaseAcquisitions += 1 }
    func recordLeasePreemption()  { leasePreemptions += 1 }

    func recordBridgeLatency(_ ms: Double) {
        latencySamples.append(ms)
        if latencySamples.count > Self.latencyCap {
            latencySamples.removeFirst()
        }
    }

    func recordRoundtrip(_ ms: Double) { lastRoundtripMs = ms }
    func recordDivergence()            { sessionDivergenceEvents += 1 }
    func recordExecutionSent()         { executionRequestsSent += 1 }
    func recordExecutionReceived()     { executionResultsReceived += 1 }

    func recordReplayBegin() { activeReplaySessions += 1 }
    func recordReplayEnd()   { if activeReplaySessions > 0 { activeReplaySessions -= 1 } }
    func recordReplayFrame() { replayFramesIngested += 1 }

    // MARK: - Device tracking

    func markConnected(_ device: DeviceParticipant) {
        var d = device
        d = DeviceParticipant(id: device.id, kind: device.kind, name: device.name,
                              lastSeenAt: Date(), isConnected: true)
        if let idx = connectedDevices.firstIndex(where: { $0.id == device.id }) {
            connectedDevices[idx] = d
        } else {
            connectedDevices.append(d)
        }
    }

    func markDisconnected(_ deviceId: String) {
        if let idx = connectedDevices.firstIndex(where: { $0.id == deviceId }) {
            let existing = connectedDevices[idx]
            connectedDevices[idx] = DeviceParticipant(
                id: existing.id, kind: existing.kind, name: existing.name,
                lastSeenAt: existing.lastSeenAt, isConnected: false
            )
        }
    }

    // MARK: - Status line

    var statusLine: String {
        let connected = connectedDevices.filter(\.isConnected).count
        var parts = ["\(connected) device(s) connected"]
        if let p95 = p95LatencyMs { parts.append("p95=\(Int(p95))ms") }
        if framesRejected > 0 { parts.append("dups=\(framesRejected)") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Private

    private func percentile(_ p: Double) -> Double? {
        guard !latencySamples.isEmpty else { return nil }
        let sorted = latencySamples.sorted()
        let idx = Int((p * Double(sorted.count - 1)).rounded())
        return sorted[min(idx, sorted.count - 1)]
    }
}
