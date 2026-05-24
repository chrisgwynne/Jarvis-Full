import AVFoundation
import ImageIO
import AppKit

/// Wraps AVCaptureSession, captures video frames, and pushes JPEG data into
/// MacCameraFrameStore. Session management runs on a private DispatchQueue;
/// frame delivery and state callbacks hop back to @MainActor.
@MainActor
final class MacCameraService: NSObject {

    enum PermissionStatus {
        case notDetermined, denied, granted
        var string: String {
            switch self {
            case .notDetermined: "notDetermined"
            case .denied:        "denied"
            case .granted:       "granted"
            }
        }
    }

    private(set) var permission: PermissionStatus = .notDetermined
    private(set) var isRunning = false
    private(set) var lastError: String? = nil

    weak var frameStore:   MacCameraFrameStore?
    weak var diagnostics:  MacCameraDiagnostics?

    private var captureSession: AVCaptureSession?
    private let sessionQueue = DispatchQueue(label: "com.jarvis.camera.session", qos: .userInitiated)
    // CIContext is thread-safe when created once and reused.
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // JPEG quality — needs to be readable from the nonisolated AVCapture delegate.
    // QualityBox is @unchecked Sendable with an internal NSLock for thread safety.
    private final class QualityBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: CGFloat = 0.6
        func get() -> CGFloat { lock.withLock { value } }
        func set(_ v: CGFloat) { lock.withLock { value = v } }
    }
    private let qualityBox = QualityBox()

    func setQuality(_ q: CGFloat) { qualityBox.set(q) }

    // MARK: - Permission

    func checkPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:              permission = .granted
        case .denied, .restricted:     permission = .denied
        default:                       permission = .notDetermined
        }
        diagnostics?.permission = permission.string
    }

    func requestPermission() async {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        permission = granted ? .granted : .denied
        diagnostics?.permission = permission.string
        if !granted { diagnostics?.log(.permissionDenied) }
    }

    // MARK: - Lifecycle

    func start() {
        guard permission == .granted, !isRunning else { return }
        sessionQueue.async { [weak self] in self?._startSession() }
    }

    func stop() {
        guard isRunning else { return }
        let session = captureSession
        sessionQueue.async { [weak self] in
            session?.stopRunning()
            Task { @MainActor [weak self] in
                guard let self else { return }
                captureSession = nil
                isRunning = false
                diagnostics?.log(.captureStopped)
                frameStore?.clear()
            }
        }
    }

    private func _startSession() {
        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .medium

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            Task { @MainActor [weak self] in
                self?.lastError = "No camera device available"
                self?.diagnostics?.log(.error("No camera device found"))
            }
            return
        }

        if session.canAddInput(input) { session.addInput(input) }

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: sessionQueue)
        if session.canAddOutput(output) { session.addOutput(output) }

        session.commitConfiguration()
        session.startRunning()

        Task { @MainActor [weak self] in
            guard let self else { return }
            captureSession = session
            isRunning = true
            lastError = nil
            diagnostics?.log(.captureStarted)
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension MacCameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }

        // Encode JPEG via ImageIO — no AppKit needed on this thread.
        let quality = qualityBox.get()
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
                mutableData, "public.jpeg" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cgImage, [
            kCGImageDestinationLossyCompressionQuality: quality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return }

        let jpegData = mutableData as Data
        Task { @MainActor [weak self] in
            self?.frameStore?.update(jpeg: jpegData)
            self?.diagnostics?.log(.frameEncoded)
        }
    }
}
