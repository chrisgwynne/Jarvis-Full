import SwiftUI

struct VoiceStatusWidget: View {
    let state: AppState
    let controller: JarvisController
    var onClose: (() -> Void)? = nil

    var body: some View {
        WidgetCard(title: "Voice", systemImage: "mic.fill", accent: .cyan, onClose: onClose) {
            VStack(alignment: .leading, spacing: 12) {

                // Status pills row
                HStack {
                    statusPill("Mic",    status: state.microphoneStatus)
                    statusPill("Speech", status: state.speechStatus)
                    statusPill("Wake",   status: state.wakeWordStatus)
                }
                .font(.caption)

                // Main phase indicator — replaces the old push-to-talk button
                phaseIndicator

                // Error or barge-in feedback
                if state.phase == .error, let err = state.lastError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                        .lineLimit(2)
                } else if let reason = state.lastBargeInReason, state.phase == .bargedIn {
                    Label("Interrupted: \(reason)", systemImage: "exclamationmark.bubble.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }
        }
    }

    // MARK: - Phase indicator

    @ViewBuilder
    private var phaseIndicator: some View {
        switch state.phase {
        case .wakeListening:
            wakeArmedBanner

        case .listening:
            listeningBanner

        case .conversationalListening:
            conversationalBanner

        case .awaitingResponse:
            phaseBanner(label: "Waiting for reply…",
                        icon: "questionmark.bubble.fill", color: .cyan)

        case .thinking:
            phaseBanner(label: "Thinking…", icon: "ellipsis.circle.fill", color: .purple)

        case .speaking:
            speakingBanner

        case .bargedIn:
            phaseBanner(label: "Resuming…", icon: "exclamationmark.bubble.fill", color: .orange)

        case .error:
            phaseBanner(label: "Error", icon: "arrow.counterclockwise.circle.fill", color: .red)

        case .muted:
            phaseBanner(label: "Muted — say nothing to wake",
                        icon: "moon.zzz.fill", color: .gray)

        case .idle:
            idleBanner
        }
    }

    // MARK: - Individual banners

    private var wakeArmedBanner: some View {
        HStack(spacing: 10) {
            // Pulsing mic icon
            Image(systemName: "waveform.badge.mic")
                .font(.title3)
                .foregroundStyle(.teal)
                .symbolEffect(.pulse, isActive: true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Listening for \"Jarvis\"")
                    .font(.subheadline.weight(.semibold))
                Text("Always on — just say the wake word")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Capsule().fill(Color.teal.opacity(0.12)))
        .overlay(Capsule().strokeBorder(Color.teal.opacity(0.35)))
    }

    private var listeningBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "stop.circle.fill")
                .font(.title3)
                .foregroundStyle(.red)
                .symbolEffect(.pulse, isActive: true)
            Text("Listening…")
                .font(.subheadline.weight(.semibold))
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Capsule().fill(Color.red.opacity(0.12)))
        .overlay(Capsule().strokeBorder(Color.red.opacity(0.35)))
    }

    private var speakingBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.title3)
                .foregroundStyle(.yellow)
                .symbolEffect(.variableColor, isActive: true)
            Text("Speaking — say \"Jarvis\" to interrupt")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Spacer()
            Button {
                controller.stopSpeaking()
            } label: {
                Image(systemName: "stop.circle")
                    .font(.title3)
                    .foregroundStyle(.yellow)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Capsule().fill(Color.yellow.opacity(0.12)))
        .overlay(Capsule().strokeBorder(Color.yellow.opacity(0.35)))
    }

    private var conversationalBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.badge.plus")
                .font(.title3)
                .foregroundStyle(.mint)
                .symbolEffect(.pulse, isActive: true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Follow-up listening…")
                    .font(.subheadline.weight(.semibold))
                Text("Speak your next command, or stay silent to end")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                controller.endConversationalSession()
            } label: {
                Image(systemName: "stop.circle")
                    .font(.title3)
                    .foregroundStyle(.mint)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Capsule().fill(Color.mint.opacity(0.12)))
        .overlay(Capsule().strokeBorder(Color.mint.opacity(0.35)))
    }

    private var idleBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.slash.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Wake word not armed")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Capsule().fill(Color.white.opacity(0.04)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))
    }

    private func phaseBanner(label: String, icon: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            Text(label)
                .font(.subheadline.weight(.semibold))
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Capsule().fill(color.opacity(0.12)))
        .overlay(Capsule().strokeBorder(color.opacity(0.35)))
    }

    // MARK: - Status pill

    private func statusPill(_ label: String, status: DeviceStatus) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(status.isHealthy ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text("\(label): \(status.label)")
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(Color.white.opacity(0.05)))
    }
}
