import Foundation
import AVFoundation
import CoreGraphics
import CoreImage

// MARK: - RTSPStreamManager

/// Manages RTSP (and any AVPlayer-compatible) streams: creates players for display,
/// extracts frames on a periodic schedule, and feeds them to `VisionDetectionPipeline`.
///
/// SwiftUI views obtain an `AVPlayer` via `player(for:)` and wrap it in `VideoPlayer`.
/// Frame extraction for detection runs independently on a per-stream Task.
@MainActor @Observable final class RTSPStreamManager {

    // MARK: - Types

    enum StreamState: String {
        case disconnected
        case connecting
        case connected
        case error
    }

    // MARK: - Public state

    private(set) var streamStates: [UUID: StreamState] = [:]

    // MARK: - Diagnostics

    var activeLoopCount: Int { detectionTasks.count }
    var activeLoopFeedIDs: [UUID] { Array(detectionTasks.keys) }

    // MARK: - Internal state

    private var players: [UUID: StreamPlayer] = [:]
    private var detectionTasks: [UUID: Task<Void, Never>] = [:]

    /// The detection pipeline that receives extracted frames. Injected externally.
    weak var pipeline: VisionDetectionPipeline?

    // MARK: - Stream lifecycle

    /// Add and begin connecting an RTSP (or any URL) stream.
    func addStream(feedID: UUID, url: String) {
        guard players[feedID] == nil else { return }
        guard let parsedURL = URL(string: url) else {
            streamStates[feedID] = .error
            Log.vision.error("[RTSPStreamManager] invalid URL for feed \(feedID): \(url)")
            return
        }

        streamStates[feedID] = .connecting
        let streamPlayer = StreamPlayer(feedID: feedID, url: parsedURL)
        players[feedID] = streamPlayer

        // Observe player status to update state
        Task { [weak self] in
            await self?.monitorPlayer(feedID: feedID, player: streamPlayer)
        }

        streamPlayer.player.play()
    }

    /// Remove a stream, stopping detection and releasing the player.
    func removeStream(feedID: UUID) {
        stopDetectionLoop(feedID: feedID)
        players[feedID]?.player.pause()
        players.removeValue(forKey: feedID)
        streamStates.removeValue(forKey: feedID)
    }

    /// Tear down and reconnect an existing stream.
    func reconnect(feedID: UUID) {
        guard let existing = players[feedID] else { return }
        let urlString = existing.playerItem.asset
            .value(forKey: "URL") as? String

        // Stop detection loop, release old player
        stopDetectionLoop(feedID: feedID)
        existing.player.pause()
        players.removeValue(forKey: feedID)
        streamStates[feedID] = .disconnected

        // Rebuild using the original URL from the AVPlayerItem if available
        let assetURL = (existing.playerItem.asset as? AVURLAsset)?.url
        if let url = assetURL {
            let fresh = StreamPlayer(feedID: feedID, url: url)
            players[feedID] = fresh
            streamStates[feedID] = .connecting
            Task { [weak self] in
                await self?.monitorPlayer(feedID: feedID, player: fresh)
            }
            fresh.player.play()
        } else if let raw = urlString, let url = URL(string: raw) {
            addStream(feedID: feedID, url: url.absoluteString)
        } else {
            Log.vision.warning("[RTSPStreamManager] cannot reconnect feed \(feedID): URL unknown")
        }
    }

    // MARK: - Player access

    /// Returns the `AVPlayer` for a feed so a SwiftUI `VideoPlayer` can display it.
    func player(for feedID: UUID) -> AVPlayer? {
        players[feedID]?.player
    }

    // MARK: - Frame extraction

    /// Synchronously capture the most recent frame from the stream player as a CGImage.
    /// Returns `nil` if the stream has no ready frame.
    func captureFrame(feedID: UUID) -> CGImage? {
        players[feedID]?.currentCGImage()
    }

    /// Begin a periodic loop that extracts frames and sends them to `pipeline`.
    func startDetectionLoop(feedID: UUID, intervalSeconds: TimeInterval = 0.5) {
        guard detectionTasks[feedID] == nil else { return }
        print("[RTSPStreamManager] Starting detection loop for feed \(feedID)")
        let task = Task { [weak self] in
            let nanos = UInt64(max(intervalSeconds, 0.1) * 1_000_000_000)
            while !Task.isCancelled {
                if let self {
                    await self.extractAndSubmitFrame(feedID: feedID)
                }
                try? await Task.sleep(nanoseconds: nanos)
            }
        }
        detectionTasks[feedID] = task
    }

    /// Stop the detection loop for a feed (does not remove the stream).
    func stopDetectionLoop(feedID: UUID) {
        detectionTasks[feedID]?.cancel()
        detectionTasks.removeValue(forKey: feedID)
    }

    /// Stop all active detection loops across all feeds.
    func stopAllDetectionLoops() {
        let count = detectionTasks.count
        print("[RTSPStreamManager] Stopping \(count) detection loop(s)")
        for task in detectionTasks.values { task.cancel() }
        detectionTasks.removeAll()
        print("[RTSPStreamManager] All detection loops stopped")
    }

    // MARK: - Private helpers

    /// Pulls a single frame from the stream player and forwards it to the pipeline.
    private func extractAndSubmitFrame(feedID: UUID) async {
        guard let streamPlayer = players[feedID] else { return }
        guard streamStates[feedID] == .connected else { return }
        guard let pixelBuffer = streamPlayer.currentPixelBuffer() else { return }
        guard let pipeline else { return }

        let timestamp = CACurrentMediaTime()
        await pipeline.process(
            pixelBuffer: pixelBuffer,
            cameraFeedID: feedID,
            timestamp: timestamp
        )
    }

    /// Watches the player's status via periodic polling and updates `streamStates`.
    private func monitorPlayer(feedID: UUID, player: StreamPlayer) async {
        // Poll for up to 10 seconds waiting for the player to become ready
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !Task.isCancelled {
            let status = player.player.status
            switch status {
            case .readyToPlay:
                streamStates[feedID] = .connected
                return
            case .failed:
                streamStates[feedID] = .error
                Log.vision.error("[RTSPStreamManager] player failed for feed \(feedID): \(String(describing: player.player.error))")
                return
            case .unknown:
                break
            @unknown default:
                break
            }
            // Also check the item's error
            if let itemError = player.playerItem.error {
                streamStates[feedID] = .error
                Log.vision.error("[RTSPStreamManager] playerItem error for feed \(feedID): \(itemError)")
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
        }

        // If still not connected after timeout, mark error unless already connected
        if streamStates[feedID] == .connecting {
            streamStates[feedID] = .error
            Log.vision.warning("[RTSPStreamManager] timeout waiting for feed \(feedID) to connect")
        }
    }
}

// MARK: - StreamPlayer

/// Private wrapper pairing an `AVPlayer` with a video output for pixel-buffer extraction.
private final class StreamPlayer: NSObject {

    let feedID: UUID
    let player: AVPlayer
    let playerItem: AVPlayerItem
    let videoOutput: AVPlayerItemVideoOutput

    var connectionError: Error?

    init(feedID: UUID, url: URL) {
        self.feedID = feedID

        let item = AVPlayerItem(url: url)
        self.playerItem = item

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: outputSettings)
        self.videoOutput = output
        item.add(output)

        self.player = AVPlayer(playerItem: item)
        self.player.isMuted = true  // RTSP surveillance feeds don't need audio

        super.init()
    }

    // MARK: Frame extraction

    /// Extracts the current pixel buffer from the video output at the player's current time.
    func currentPixelBuffer() -> CVPixelBuffer? {
        let itemTime = videoOutput.itemTime(forHostTime: CACurrentMediaTime())
        guard videoOutput.hasNewPixelBuffer(forItemTime: itemTime) else { return nil }
        var displayTime = CMTime.zero
        return videoOutput.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &displayTime)
    }

    /// Converts the current video frame to a CGImage, or returns `nil` if unavailable.
    func currentCGImage() -> CGImage? {
        guard let pixelBuffer = currentPixelBuffer() else { return nil }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        return context.createCGImage(ciImage, from: ciImage.extent)
    }
}
