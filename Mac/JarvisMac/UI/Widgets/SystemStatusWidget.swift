import SwiftUI

struct SystemStatusWidget: View {
    let state: AppState
    var onClose: (() -> Void)? = nil

    var body: some View {
        WidgetCard(title: "System", systemImage: "cpu.fill", accent: .orange, onClose: onClose) {
            VStack(alignment: .leading, spacing: 6) {
                row("Microphone", state.microphoneStatus, "mic.fill")
                row("Speech",     state.speechStatus,     "waveform")
                row("Wake word",  state.wakeWordStatus,   "waveform.badge.mic")
                row("Camera",     state.cameraStatus,     "video.fill")
                row("Android",    state.androidServerStatus, "antenna.radiowaves.left.and.right")
                row("Home",       state.homeAssistantStatus, "house.fill")
                row("Engine",     .ready,                 "brain.head.profile",
                    override: state.speechEngine.displayName + (state.isOffline ? " · offline" : ""))
            }
        }
    }

    private func row(_ label: String,
                     _ status: DeviceStatus,
                     _ icon: String,
                     override: String? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .frame(width: 18)
                .foregroundStyle(status.isHealthy ? .green : .orange)
            Text(label).font(.subheadline)
            Spacer()
            Text(override ?? status.label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
