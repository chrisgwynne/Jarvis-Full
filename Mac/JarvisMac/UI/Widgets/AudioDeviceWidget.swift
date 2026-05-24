import SwiftUI

struct AudioDeviceWidget: View {
    let state: AppState
    let controller: JarvisController
    var onClose: (() -> Void)? = nil

    var body: some View {
        WidgetCard(title: "Microphone", systemImage: "mic.fill", accent: .cyan, onClose: onClose) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Microphone", selection: micBinding) {
                    Text("System default").tag(String?.none)
                    ForEach(state.availableMicrophones) { dev in
                        Text(dev.name + (dev.isWebcamMic ? " (webcam)" : ""))
                            .tag(Optional(dev.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()

                if let active = state.activeMicrophoneName {
                    HStack(spacing: 6) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .foregroundStyle(.cyan)
                        Text("Active: \(active)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: state.micRoutingStatus.isHealthy ? "checkmark.seal" : "exclamationmark.triangle")
                        .foregroundStyle(state.micRoutingStatus.isHealthy ? .green : .orange)
                    Text("Routing: \(state.micRoutingStatus.label)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        controller.refreshAudioDevices()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Refresh audio device list")
                }
            }
        }
    }

    private var micBinding: Binding<String?> {
        Binding(
            get: { state.preferredMicrophoneUID },
            set: { newID in
                if let newID,
                   let match = state.availableMicrophones.first(where: { $0.id == newID }) {
                    controller.audioDevices.setPreferred(match)
                    state.preferredMicrophoneUID = newID
                    state.activeMicrophoneName = match.name
                } else {
                    controller.audioDevices.setPreferred(nil)
                    state.preferredMicrophoneUID = nil
                }
            }
        )
    }
}
