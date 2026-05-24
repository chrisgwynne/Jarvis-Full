import Foundation
import AVFoundation
import CoreVideo

// MARK: - CameraPipeline

/// Manages AVCaptureSession for the webcam.
///
/// Publishes raw `CVPixelBuffer` frames at ~30fps.
/// Separate from hand tracking so each can evolve independently.
@MainActor
final class CameraPipeline: NSObject, ObservableObject {

    // MARK: Published

    @Published private(set) var latestFrame: CVPixelBuffer?
    @Published private(set) var isRunning = false
    @Published private(set) var error: String?

    // MARK: AVFoundation

    let session = AVCaptureSession()
    private var output = AVCaptureVideoDataOutput()
    private let frameQueue = DispatchQueue(label: "com.jarvis.camera.frames",
                                           qos: .userInteractive)

    // MARK: Start / Stop

    func start() async {
        guard !isRunning else { return }

        // Check authorization
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard granted else {
                error = "Camera access denied."
                return
            }
        default:
            error = "Camera access denied. Enable in System Settings → Privacy."
            return
        }

        guard configurePipeline() else { return }

        session.startRunning()
        isRunning = session.isRunning
    }

    func stop() {
        session.stopRunning()
        isRunning = false
        latestFrame = nil
    }

    // MARK: Private configuration

    private func configurePipeline() -> Bool {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .high   // 1280×720 on most Macs

        // ── Input: front-facing / built-in webcam ──────────────────────────
        guard let device = AVCaptureDevice.default(
                .builtInWideAngleCamera, for: .video, position: .front)
                ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            error = "No webcam found."
            return false
        }
        guard session.canAddInput(input) else {
            error = "Cannot add camera input."
            return false
        }
        session.addInput(input)

        // ── Output: pixel buffers ──────────────────────────────────────────
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: frameQueue)

        guard session.canAddOutput(output) else {
            error = "Cannot add video output."
            return false
        }
        session.addOutput(output)

        // Ensure portrait orientation for macOS webcam.
        if let connection = output.connection(with: .video) {
            if connection.isVideoMirroringSupported {
                connection.isVideoMirrored = true   // selfie-mirror
            }
        }

        return true
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraPipeline: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        Task { @MainActor in
            self.latestFrame = pixelBuffer
        }
    }
}
