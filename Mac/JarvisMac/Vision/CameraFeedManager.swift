import Foundation
import AVFoundation
import CoreGraphics
import CoreImage
import SwiftUI

// MARK: - CameraFeedManager

/// Manages multiple simultaneous camera feeds (local AVCapture + RTSP) and routes
/// pixel buffers to a shared `VisionDetectionPipeline` actor for analysis.
///
/// - Note: Does NOT conflict with `CameraManager`, which owns the app's primary
///   AVCaptureSession keyed by `CameraRole`. This class manages an independent set of
///   feeds identified by `CameraFeedDescriptor.id` (UUID), used exclusively by the
///   Person-of-Interest visual intelligence system.
@MainActor @Observable final class CameraFeedManager: NSObject {

    // MARK: - Public state

    /// All registered feed descriptors.
    private(set) var feeds: [CameraFeedDescriptor] = []

    /// Most-recent display frame (CGImage) per feed UUID. Updated on every arriving frame.
    private(set) var latestFrames: [UUID: CGImage] = [:]

    // MARK: - Internal state

    /// Active local AVCaptureSession wrappers keyed by feed UUID.
    private var captureSessions: [UUID: LocalCaptureSession] = [:]

    /// Shared CIContext for frame conversion — creating one per frame causes GPU heap churn.
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Timestamp of the last display-frame update. Used to throttle @Observable
    /// change notifications to ≤30fps so SwiftUI does not re-render every camera frame.
    private var lastDisplayFrameTime: CFTimeInterval = 0

    /// The detection pipeline that receives pixel buffers. Injected externally.
    weak var pipeline: VisionDetectionPipeline?

    // MARK: - Constants

    /// Stable UUID used as the default primary webcam feed identifier.
    static let primaryFeedID = UUID(uuidString: "FEEDFEED-0001-0001-0001-FEEDFEED0001")!

    // MARK: - Feed management

    /// Register a feed descriptor. Does not start capturing automatically.
    func addFeed(_ feed: CameraFeedDescriptor) {
        guard !feeds.contains(where: { $0.id == feed.id }) else { return }
        feeds.append(feed)
    }

    /// Unregister and stop a feed.
    func removeFeed(id: UUID) {
        stopFeed(id: id)
        feeds.removeAll { $0.id == id }
        latestFrames.removeValue(forKey: id)
    }

    /// Start capturing on a previously-registered feed.
    func startFeed(id: UUID) {
        guard let feed = feeds.first(where: { $0.id == id }), feed.isEnabled else { return }

        switch feed.source {
        case .localWebcam(let deviceUID):
            guard captureSessions[id] == nil else { return }
            guard let session = makeLocalSession(for: feed) else {
                Log.vision.warning("[CameraFeedManager] could not create capture session for feed \(id) uid=\(deviceUID ?? "nil")")
                return
            }
            captureSessions[id] = session
            session.start()

        case .rtsp, .homeAssistant:
            // RTSP / HA streams are managed by RTSPStreamManager; nothing to do here.
            break
        }
    }

    /// Stop capturing on a feed (does not remove it from the registry).
    func stopFeed(id: UUID) {
        captureSessions[id]?.stop()
        captureSessions.removeValue(forKey: id)
    }

    /// Start all registered, enabled local-webcam feeds.
    func startAll() {
        for feed in feeds where feed.isEnabled {
            startFeed(id: feed.id)
        }
    }

    /// Stop all active local-webcam feeds.
    func stopAll() {
        for id in captureSessions.keys {
            stopFeed(id: id)
        }
    }

    // MARK: - Frame ingestion

    /// Called from `LocalCaptureSession.onFrame` (dispatched to @MainActor).
    func receivedFrame(_ pixelBuffer: CVPixelBuffer, feedID: UUID, timestamp: CMTime) {
        // 1. Convert to CGImage for display (reuse shared CIContext — never allocate per frame).
        // Throttle @Observable updates to ≤30fps so SwiftUI doesn't re-render on every
        // camera frame (which would cause 30 layout+render requests per second).
        let now = CACurrentMediaTime()
        let minDisplayInterval: CFTimeInterval = 1.0 / 30.0
        if now - lastDisplayFrameTime >= minDisplayInterval {
            lastDisplayFrameTime = now
            let ci = CIImage(cvPixelBuffer: pixelBuffer)
            if let cgImage = ciContext.createCGImage(ci, from: ci.extent) {
                latestFrames[feedID] = cgImage
            }
        }

        // 2. Forward to pipeline (actor hop — fire and forget)
        let timeInterval = CMTimeGetSeconds(timestamp)
        if let pipeline {
            Task {
                await pipeline.process(
                    pixelBuffer: pixelBuffer,
                    cameraFeedID: feedID,
                    timestamp: timeInterval.isNaN || timeInterval.isInfinite
                        ? CACurrentMediaTime()
                        : timeInterval
                )
            }
        }
    }

    // MARK: - Device enumeration

    /// Returns all locally-available AVCaptureDevice video devices.
    func availableDevices() -> [AVCaptureDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices
    }

    // MARK: - Convenience factory

    /// Creates a `CameraFeedDescriptor` for the system default webcam using the stable `primaryFeedID`.
    func makeDefaultWebcamFeed() -> CameraFeedDescriptor {
        CameraFeedDescriptor(
            id: CameraFeedManager.primaryFeedID,
            name: "Webcam",
            source: .localWebcam(deviceUID: nil),
            location: "Primary",
            isEnabled: true
        )
    }

    // MARK: - Private helpers

    private func makeLocalSession(for feed: CameraFeedDescriptor) -> LocalCaptureSession? {
        guard case .localWebcam(let deviceUID) = feed.source else { return nil }
        let session = LocalCaptureSession(feedID: feed.id, deviceUID: deviceUID)
        session.onFrame = { [weak self] pixelBuffer, time in
            // Hop to MainActor for @Observable state mutation
            Task { @MainActor [weak self] in
                self?.receivedFrame(pixelBuffer, feedID: feed.id, timestamp: time)
            }
        }
        return session
    }
}

// MARK: - LocalCaptureSession

/// Private wrapper for a single AVCaptureSession tied to one feed UUID.
private final class LocalCaptureSession: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    let feedID: UUID
    let session: AVCaptureSession
    let outputQueue: DispatchQueue

    /// Reused serial queue for session start/stop operations.
    /// Creating a new DispatchQueue per call leaks kernel objects — store and reuse.
    private let sessionControlQueue: DispatchQueue

    /// Called on `outputQueue` with each new pixel buffer and its presentation time.
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?

    private let deviceUID: String?

    init(feedID: UUID, deviceUID: String?) {
        self.feedID = feedID
        self.deviceUID = deviceUID
        self.session = AVCaptureSession()
        self.outputQueue = DispatchQueue(
            label: "com.jarvis.mac.feedmanager.output.\(feedID.uuidString)",
            qos: .userInitiated
        )
        self.sessionControlQueue = DispatchQueue(
            label: "com.jarvis.mac.feedmanager.control.\(feedID.uuidString)",
            qos: .utility
        )
        super.init()
        configure()
    }

    // MARK: Start / stop

    func start() {
        sessionControlQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    func stop() {
        sessionControlQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    // MARK: AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        onFrame?(pixelBuffer, pts)
    }

    // MARK: Private setup

    private func configure() {
        // Resolve device
        let device: AVCaptureDevice?
        if let uid = deviceUID {
            device = AVCaptureDevice(uniqueID: uid)
        } else {
            // Prefer an external camera, then fall back to built-in
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.external, .builtInWideAngleCamera],
                mediaType: .video,
                position: .unspecified
            )
            device = discovery.devices.first(where: { $0.deviceType == .external })
                ?? discovery.devices.first
        }

        guard let device else {
            Log.vision.warning("[LocalCaptureSession] no video device found for feed \(self.feedID)")
            return
        }

        session.beginConfiguration()
        session.sessionPreset = .high

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
            }
        } catch {
            Log.vision.error("[LocalCaptureSession] input error for feed \(self.feedID): \(error)")
            session.commitConfiguration()
            return
        }

        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: outputQueue)

        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        session.commitConfiguration()
    }
}
