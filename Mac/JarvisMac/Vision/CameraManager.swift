import Foundation
import AVFoundation
import CoreImage
import AppKit

// MARK: - Camera role

/// Named camera roles. Each role gets its own independent AVCaptureSession.
enum CameraRole: String, CaseIterable {
    case primary   = "primary"    // face / presence cam (was the only cam in Phase 1)
    case secondary = "secondary"  // desk cam
}

// MARK: - Per-session state

private final class CameraSession: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let role: CameraRole
    let session         = AVCaptureSession()
    let sessionQueue    = DispatchQueue(label: "com.jarvis.mac.camera.session.\(CameraRole.primary.rawValue)")
    let videoOutput     = AVCaptureVideoDataOutput()
    let outputQueue     = DispatchQueue(label: "com.jarvis.mac.camera.output.\(CameraRole.primary.rawValue)")
    let ciContext       = CIContext()

    private var latestPixelBuffer: CVPixelBuffer?
    fileprivate var latestFrameDate: Date?
    fileprivate let pixelBufferLock = NSLock()

    /// Raw pixel-buffer tap — used by SpatialAmbientCoordinator.
    /// Called from the `outputQueue` (background) so the handler must be thread-safe.
    var pixelBufferTap: ((CVPixelBuffer) -> Void)?

    /// Maximum acceptable frame age before a capture is considered stale.
    static let staleFrameThreshold: TimeInterval = 3.0

    var frameTap: ((CGImage) -> Void)?
    private(set) var currentDevice: AVCaptureDevice?

    init(role: CameraRole) {
        self.role = role
        // Recreate queues with the correct label
        super.init()
    }

    func start(device: AVCaptureDevice) {
        currentDevice = device
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .high

            for input  in self.session.inputs  { self.session.removeInput(input) }
            for output in self.session.outputs { self.session.removeOutput(output) }

            do {
                let input = try AVCaptureDeviceInput(device: device)
                if self.session.canAddInput(input) { self.session.addInput(input) }
                self.videoOutput.setSampleBufferDelegate(self, queue: self.outputQueue)
                self.videoOutput.alwaysDiscardsLateVideoFrames = true
                if self.session.canAddOutput(self.videoOutput) {
                    self.session.addOutput(self.videoOutput)
                }
            } catch {
                Log.vision.error("[\(self.role.rawValue)] camera input failed: \(String(describing: error))")
            }

            self.session.commitConfiguration()
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func captureStill() -> CGImage? {
        captureTimestamped()?.image
    }

    /// Returns a still with its captured timestamp, or nil if no live frame exists.
    func captureTimestamped() -> (image: CGImage, date: Date)? {
        pixelBufferLock.lock()
        let buffer    = latestPixelBuffer
        let frameDate = latestFrameDate
        pixelBufferLock.unlock()
        guard let buffer else { return nil }
        // Reject frames older than the stale threshold.
        if let date = frameDate,
           -date.timeIntervalSinceNow > CameraSession.staleFrameThreshold {
            return nil
        }
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let image = ciContext.createCGImage(ci, from: ci.extent) else { return nil }
        return (image, frameDate ?? Date())
    }

    // MARK: AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        pixelBufferLock.lock()
        latestPixelBuffer = pb
        latestFrameDate   = Date()
        pixelBufferLock.unlock()
        // Raw pixel-buffer tap for spatial hand tracking (no CGImage conversion overhead).
        pixelBufferTap?(pb)
        if let tap = frameTap {
            let ci = CIImage(cvPixelBuffer: pb)
            if let cg = ciContext.createCGImage(ci, from: ci.extent) {
                tap(cg)
            }
        }
    }
}

// MARK: - CameraManager

/// Manages one or two AVCaptureSessions: `.primary` (face/presence) and
/// `.secondary` (desk).  Cleanly degrades when no camera is present or
/// permission is denied.
///
/// Thread model: not actor-isolated. Session reconfiguration is serialised
/// on per-role `sessionQueue`s; the latest frame is guarded by `pixelBufferLock`.
final class CameraManager: NSObject {

    struct Device: Identifiable, Equatable {
        let id: String
        let name: String
        let isExternal: Bool
    }

    private let prefs: PreferencesStore

    // Per-role sessions
    private var sessions: [CameraRole: CameraSession] = [:]

    // Convenience alias: the primary preview layer (unchanged public API)
    let previewLayer: AVCaptureVideoPreviewLayer

    /// Optional sink for every captured frame from the PRIMARY camera.
    /// Phase 2 wires the motion detector into this when the user says "watch the desk".
    var frameTap: ((CGImage) -> Void)? {
        get { sessions[.primary]?.frameTap }
        set { sessions[.primary]?.frameTap = newValue }
    }

    /// Raw pixel-buffer tap — set by `SpatialAmbientCoordinator` when the
    /// SpatialHUD overlay is open.  Receives every camera frame as a
    /// `CVPixelBuffer` so Vision hand-pose inference can run without a
    /// second `AVCaptureSession`.
    ///
    /// Only one consumer at a time (spatial HUD).  Clear this tap on overlay close.
    var pixelBufferTap: ((CVPixelBuffer) -> Void)? {
        get { sessions[.primary]?.pixelBufferTap }
        set { sessions[.primary]?.pixelBufferTap = newValue }
    }

    /// Whether the primary camera session is actively running.
    var isRunning: Bool { sessions[.primary]?.session.isRunning ?? false }

    /// The currently active device for the primary session.
    var currentDevice: AVCaptureDevice? { sessions[.primary]?.currentDevice }

    init(prefs: PreferencesStore) {
        self.prefs = prefs
        // Create a placeholder session so previewLayer is valid before startPreview()
        let primarySession = CameraSession(role: .primary)
        self.previewLayer = AVCaptureVideoPreviewLayer(session: primarySession.session)
        self.previewLayer.videoGravity = .resizeAspectFill
        super.init()
        sessions[.primary] = primarySession
    }

    func requestAuthorization() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized: return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    func enumerate() -> [Device] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        )
        return session.devices.map { d in
            Device(id: d.uniqueID,
                   name: d.localizedName,
                   isExternal: d.deviceType == .external)
        }
    }

    func setPreferred(_ device: Device?) {
        prefs.update { $0.preferredCameraUID = device?.id }
    }

    var preferredUID: String? { prefs.current.preferredCameraUID }

    func resolvePreferred() -> AVCaptureDevice? {
        if let uid = preferredUID, let dev = AVCaptureDevice(uniqueID: uid) {
            return dev
        }
        let all = enumerate()
        if let ext = all.first(where: { $0.isExternal }),
           let dev = AVCaptureDevice(uniqueID: ext.id) { return dev }
        if let any = all.first,
           let dev = AVCaptureDevice(uniqueID: any.id) { return dev }
        return nil
    }

    // MARK: - Backward-compatible single-camera API

    /// Start the primary camera preview (backward-compatible entry point).
    func startPreview() throws {
        guard let device = resolvePreferred() else {
            throw JarvisError.deviceUnavailable("No camera available")
        }
        let cs = sessions[.primary] ?? CameraSession(role: .primary)
        sessions[.primary] = cs
        cs.start(device: device)
    }

    /// Stop the primary camera preview.
    func stopPreview() {
        sessions[.primary]?.stop()
    }

    /// Capture a still from the primary camera.
    func captureStill() -> CGImage? {
        sessions[.primary]?.captureStill()
    }

    /// Capture a still with its frame timestamp and a unique frame ID.
    /// Returns nil if no live frame is available or the frame is stale.
    func captureTimestampedStill() -> (image: CGImage, frameDate: Date, frameID: UUID)? {
        guard let pair = sessions[.primary]?.captureTimestamped() else { return nil }
        return (pair.image, pair.date, UUID())
    }

    // MARK: - Dual-camera API

    /// Start a named session for the given role.
    /// If `deviceUID` is nil, falls back to the system default for that role.
    func startSession(role: CameraRole, deviceUID: String?) {
        let device: AVCaptureDevice?
        if let uid = deviceUID {
            device = AVCaptureDevice(uniqueID: uid)
        } else {
            device = role == .primary ? resolvePreferred() : nil
        }
        guard let device else {
            Log.vision.warning("[CameraManager] no device for role \(role.rawValue) uid=\(deviceUID ?? "nil")")
            return
        }
        let cs: CameraSession
        if let existing = sessions[role] {
            cs = existing
        } else {
            let newSession = CameraSession(role: role)
            sessions[role] = newSession
            cs = newSession
        }
        cs.start(device: device)
    }

    /// Stop a named session.
    func stopSession(role: CameraRole) {
        sessions[role]?.stop()
    }

    /// Capture a still from a specific camera role. Returns nil if that role isn't running.
    func captureFrame(from role: CameraRole) -> CGImage? {
        sessions[role]?.captureStill()
    }

    /// Whether a session is running for this role.
    func isRunning(role: CameraRole) -> Bool {
        sessions[role]?.session.isRunning ?? false
    }
}
