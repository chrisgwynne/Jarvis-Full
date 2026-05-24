import SwiftUI

struct VisionWidget: View {
    let state: AppState
    let controller: JarvisController
    var onClose: (() -> Void)? = nil

    var body: some View {
        WidgetCard(title: "Vision", systemImage: "eye.fill", accent: .pink, onClose: onClose) {
            VStack(alignment: .leading, spacing: 10) {
                if state.lastVisionSummary.isEmpty {
                    Text("Ask \"what can you see\" or hit a button below.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text(state.lastVisionSummary)
                        .font(.subheadline)
                        .lineLimit(4)
                    if let ts = state.lastVisionTimestamp {
                        Text(ts, format: .relative(presentation: .named))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: "person.fill")
                        .foregroundStyle(state.faceCount > 0 ? .green : .secondary)
                    Text("People: \(state.faceCount)")
                        .font(.caption.monospacedDigit())
                    Spacer()
                    Image(systemName: state.motionDetected ? "figure.walk.motion" : "moon.zzz")
                        .foregroundStyle(state.motionDetected ? .yellow : .secondary)
                    Text(state.motionDetected ? "Motion" : "Still")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    Button { run(.describe) }    label: { Label("Describe",    systemImage: "eye") }
                    Button { run(.readText) }    label: { Label("Read",        systemImage: "text.viewfinder") }
                    Button { run(.detectPeople) } label: { Label("Who's there", systemImage: "person.crop.square") }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!state.cameraStatus.isHealthy)

                Toggle("Watch the desk", isOn: watchBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.caption)
            }
        }
    }

    private func run(_ mode: VisionMode) {
        Task { await controller.captureCameraAndDescribe(announce: true, mode: mode) }
    }

    private var watchBinding: Binding<Bool> {
        Binding(
            get: { state.watchingDesk },
            set: { newValue in
                if newValue { controller.beginWatchingDesk() }
                else        { controller.stopWatchingDesk() }
            }
        )
    }
}
