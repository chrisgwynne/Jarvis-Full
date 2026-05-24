import SwiftUI
import AppKit
import AVFoundation

/// SwiftUI wrapper around an AVCaptureVideoPreviewLayer-hosting NSView.
private struct CameraPreviewView: NSViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer = CALayer()
        view.layer?.backgroundColor = NSColor.black.cgColor
        previewLayer.frame = view.bounds
        previewLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(previewLayer)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        previewLayer.frame = nsView.bounds
    }
}

struct CameraPreviewWidget: View {
    let state: AppState
    let controller: JarvisController
    var onClose: (() -> Void)? = nil

    var body: some View {
        WidgetCard(title: "Camera", systemImage: "video.fill", accent: .pink, onClose: onClose) {
            VStack(alignment: .leading, spacing: 10) {

                // ── Live feed / placeholder ───────────────────────────────────
                ZStack {
                    // AVCaptureVideoPreviewLayer has a single-parent
                    // constraint — when the camera overlay is open it owns the
                    // layer; we must NOT also attach it here.
                    if state.cameraStatus.isHealthy
                        && !controller.overlayManager.isOpen(.camera) {
                        CameraPreviewView(previewLayer: controller.camera.previewLayer)
                            .frame(minHeight: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.05))
                            .frame(minHeight: 180)
                            .overlay(
                                VStack(spacing: 6) {
                                    Image(systemName: controller.overlayManager.isOpen(.camera)
                                          ? "macwindow.on.rectangle"
                                          : "video.slash.fill")
                                        .font(.system(size: 28))
                                        .foregroundStyle(.secondary)
                                    Text(controller.overlayManager.isOpen(.camera)
                                         ? "Live in overlay"
                                         : state.cameraStatus.label)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            )
                    }

                    // Loading overlay
                    if state.visionIsLoading {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.black.opacity(0.5))
                            .frame(minHeight: 180)
                            .overlay(
                                VStack(spacing: 8) {
                                    ProgressView()
                                        .progressViewStyle(.circular)
                                        .scaleEffect(1.2)
                                    Text("Analysing…")
                                        .font(.caption)
                                        .foregroundStyle(.white)
                                }
                            )
                    }
                }

                // ── Latest visual description ─────────────────────────────────
                if !state.lastVisionSummary.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(state.lastVisionSummary)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 6) {
                            if !state.lastVisionProvider.isEmpty {
                                Label(state.lastVisionProvider,
                                      systemImage: state.lastVisionProvider.contains("MiniMax")
                                        ? "sparkles" : "cpu.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if state.lastVisionTotalMs > 0 {
                                Text("\(state.lastVisionTotalMs)ms")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            if let err = state.lastVisionError {
                                Label(err.prefix(30), systemImage: "exclamationmark.triangle")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }

                // ── Controls ─────────────────────────────────────────────────
                HStack {
                    Picker("Camera", selection: cameraBinding) {
                        Text("Auto").tag(String?.none)
                        ForEach(state.availableCameras) { dev in
                            Text(dev.name).tag(Optional(dev.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 180)

                    Spacer()

                    Button {
                        state.visionIsLoading = true
                        Task {
                            let (summary, result) = await controller.cameraAwareness
                                .captureDescription(mode: .describe)
                            await MainActor.run {
                                controller.applyVisionResult(result, summary: summary)
                                controller.speak(summary)
                            }
                        }
                    } label: {
                        if state.visionIsLoading {
                            Label("Analysing…", systemImage: "ellipsis")
                        } else {
                            Label("Describe", systemImage: "eye.fill")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!state.cameraStatus.isHealthy || state.visionIsLoading)
                }
                .font(.caption)
            }
        }
    }

    private var cameraBinding: Binding<String?> {
        Binding<String?>(
            get: { state.preferredCameraUID },
            set: { newID in
                if let newID,
                   let match = state.availableCameras.first(where: { $0.id == newID }) {
                    controller.camera.setPreferred(match)
                    state.preferredCameraUID = newID
                    do { try controller.camera.startPreview() }
                    catch { state.cameraStatus = .failed(error.localizedDescription) }
                } else {
                    controller.camera.setPreferred(nil)
                    state.preferredCameraUID = nil
                }
            }
        )
    }
}
