import SwiftUI

struct WakeWordWidget: View {
    let state: AppState
    let controller: JarvisController
    var onClose: (() -> Void)? = nil

    var body: some View {
        WidgetCard(title: "Wake Word", systemImage: "waveform.badge.mic", accent: .teal, onClose: onClose) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(state.wakeWordStatus.isHealthy ? Color.green : Color.orange)
                        .frame(width: 10, height: 10)
                    Text(state.wakeWordStatus.label)
                        .font(.subheadline)
                    Spacer()
                    Toggle("", isOn: enabledBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }

                if let event = state.lastWakeEvent {
                    HStack(spacing: 6) {
                        Image(systemName: "scope")
                            .foregroundStyle(.teal)
                        Text("Last: \(event.keyword)")
                            .font(.caption)
                        Spacer()
                        Text(String(format: "%.2f", event.confidence))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                if !state.recentWakeScores.isEmpty {
                    histogram
                        .frame(height: 28)
                }

                HStack {
                    Text("Threshold")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: thresholdBinding, in: 0.05...0.95)
                    Text(String(format: "%.2f", controller.prefs.current.wakeWord.threshold))
                        .font(.caption.monospacedDigit())
                        .frame(width: 36, alignment: .trailing)
                }

                HStack(spacing: 8) {
                    Button {
                        controller.recordWakeFeedback(.falseAccept, for: state.lastWakeEvent)
                    } label: { Label("False accept", systemImage: "xmark.circle") }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(state.lastWakeEvent == nil)
                    Button {
                        controller.recordWakeFeedback(.falseReject, for: state.lastWakeEvent)
                    } label: { Label("Missed", systemImage: "questionmark.circle") }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { controller.prefs.current.wakeWord.enabled },
            set: { newValue in
                controller.prefs.update { $0.wakeWord.enabled = newValue }
                Task { await controller.rebuildWakeWord() }
            }
        )
    }

    private var thresholdBinding: Binding<Double> {
        Binding(
            get: { controller.prefs.current.wakeWord.threshold },
            set: { newValue in
                controller.prefs.update { $0.wakeWord.threshold = newValue }
            }
        )
    }

    private var histogram: some View {
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(state.recentWakeScores.enumerated()), id: \.offset) { _, score in
                    Rectangle()
                        .fill(score >= controller.prefs.current.wakeWord.threshold ? Color.teal : Color.orange.opacity(0.7))
                        .frame(width: max(2, (geo.size.width - 40) / 20),
                               height: CGFloat(score) * geo.size.height)
                }
            }
        }
    }
}
