import SwiftUI
import AVFoundation
import CoreImage
import AppKit

// MARK: - CameraCompositor

/// SwiftUI wrapper that renders the live camera feed as a cinematic background.
///
/// Visual treatment:
/// - Soft vignette darkening at edges
/// - Radial blur on edges (using CIFilter)
/// - Brightness/saturation dimmed during active mode
/// - Smooth transitions driven by `attentionOpacity`
struct CameraCompositor: View {

    let pipeline: CameraPipeline
    /// 0 = idle (slightly dim), 1 = fully active (darker).
    var attentionOpacity: Double

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // ── Camera feed ────────────────────────────────────────────
                SpatialCameraPreviewView(session: pipeline.session)
                    .ignoresSafeArea()

                // ── Edge vignette — darkens corners with radial gradient ───
                VignetteOverlay(intensity: 0.45 + attentionOpacity * 0.25)
                    .ignoresSafeArea()

                // ── Global dark scrim for attention mode ───────────────────
                Color.black
                    .opacity(attentionOpacity * 0.30)
                    .ignoresSafeArea()
                    .animation(.easeInOut(duration: 0.4), value: attentionOpacity)
            }
        }
    }
}

// MARK: - SpatialCameraPreviewView (NSViewRepresentable)

/// Hosts an `AVCaptureVideoPreviewLayer` inside SwiftUI.
/// Using the native layer is dramatically more efficient than converting
/// pixel buffers to images each frame — GPU composites it for free.
struct SpatialCameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> SpatialCameraPreviewNSView {
        let view = SpatialCameraPreviewNSView()
        view.configure(session: session)
        return view
    }

    func updateNSView(_ view: SpatialCameraPreviewNSView, context: Context) {}
}

final class SpatialCameraPreviewNSView: NSView {
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(session: AVCaptureSession) {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        self.layer?.addSublayer(layer)
        previewLayer = layer
    }

    override func layout() {
        super.layout()
        previewLayer?.frame = bounds
    }
}

// MARK: - VignetteOverlay

/// Radial gradient that darkens corners — the classic cinematic look.
struct VignetteOverlay: View {
    var intensity: Double = 0.6

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let gradient = Gradient(stops: [
                    .init(color: .clear,                    location: 0.35),
                    .init(color: .black.opacity(0.25),      location: 0.65),
                    .init(color: .black.opacity(intensity), location: 1.00),
                ])
                let radius = max(size.width, size.height) * 0.70

                for corner in [
                    CGPoint(x: 0, y: 0),
                    CGPoint(x: size.width, y: 0),
                    CGPoint(x: 0, y: size.height),
                    CGPoint(x: size.width, y: size.height),
                ] {
                    let ellipseRect = CGRect(
                        x: corner.x - radius,
                        y: corner.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )
                    let path = Path(ellipseIn: ellipseRect)
                    ctx.fill(path, with: .radialGradient(
                        gradient,
                        center: corner,
                        startRadius: 0,
                        endRadius: radius
                    ))
                }
            }
        }
        .blendMode(.multiply)
        .allowsHitTesting(false)
    }
}
