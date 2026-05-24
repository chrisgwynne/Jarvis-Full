import SwiftUI

struct StatusBar: View {
    let state: AppState

    var body: some View {
        HStack(spacing: 8) {
            phasePill
            pill("Mic",     state.microphoneStatus, "mic.fill")
            pill("Speech",  state.speechStatus,     "waveform")
            pill("Wake",    state.wakeWordStatus,   "waveform.badge.mic")
            pill("Camera",  state.cameraStatus,     "video.fill")
            pill("Home",    state.homeAssistantStatus, "house.fill")
            pill("Android", state.androidServerStatus,
                 "antenna.radiowaves.left.and.right")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06))
        )
        .animation(.easeInOut(duration: 0.2), value: state.phase)
    }

    private var phasePill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(phaseColor(state.phase))
                .frame(width: 8, height: 8)
                .overlay(Circle().stroke(phaseColor(state.phase).opacity(0.6), lineWidth: 4)
                            .blur(radius: state.phase == .idle ? 0 : 3))
            Text(phaseLabel(state.phase))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Capsule().fill(phaseColor(state.phase).opacity(0.15)))
        .overlay(Capsule().strokeBorder(phaseColor(state.phase).opacity(0.4)))
    }

    private func phaseLabel(_ phase: AssistantPhase) -> String {
        switch phase {
        case .idle:                    return "Idle"
        case .wakeListening:           return "Wake listening"
        case .listening:               return "Listening"
        case .conversationalListening: return "Follow-up"
        case .awaitingResponse:        return "Awaiting reply"
        case .thinking:                return "Thinking"
        case .speaking:                return "Speaking"
        case .bargedIn:                return "Interrupted"
        case .muted:                   return "Muted"
        case .error:                   return "Error"
        }
    }

    private func phaseColor(_ phase: AssistantPhase) -> Color {
        switch phase {
        case .idle:                    return .secondary
        case .wakeListening:           return .teal
        case .listening:               return .red
        case .conversationalListening: return .mint
        case .awaitingResponse:        return .cyan
        case .thinking:                return .purple
        case .speaking:                return .yellow
        case .bargedIn:                return .orange
        case .muted:                   return .gray
        case .error:                   return .red
        }
    }

    private func pill(_ name: String,
                      _ status: DeviceStatus,
                      _ icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .foregroundStyle(status.isHealthy ? .green : .orange)
            Text(name)
                .font(.caption.weight(.semibold))
            Text(status.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(Color.white.opacity(0.05)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))
    }
}
