import SwiftUI

struct SpeechEngineWidget: View {
    let state: AppState
    let controller: JarvisController
    var onClose: (() -> Void)? = nil

    var body: some View {
        WidgetCard(title: "Speech Engine", systemImage: "waveform", accent: .mint, onClose: onClose) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Engine", selection: engineBinding) {
                    ForEach(SpeechEngine.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                HStack(spacing: 6) {
                    Image(systemName: state.isOffline ? "wifi.slash" : "wifi")
                        .foregroundStyle(state.isOffline ? .green : .secondary)
                    Text(state.isOffline ? "On-device" : "May use network")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if state.speechEngine == .whisper {
                    HStack(spacing: 6) {
                        Image(systemName: state.whisperStatus.isHealthy ? "checkmark.seal" : "exclamationmark.triangle")
                            .foregroundStyle(state.whisperStatus.isHealthy ? .green : .orange)
                        Text(state.whisperStatus.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                if let ms = state.latencyMillis[LatencyStage.sttFirstPartial.rawValue] {
                    Text("First partial: \(Int(ms)) ms avg")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let ms = state.latencyMillis[LatencyStage.sttFinal.rawValue] {
                    Text("Final: \(Int(ms)) ms avg")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var engineBinding: Binding<SpeechEngine> {
        Binding(
            get: { state.speechEngine },
            set: { engine in controller.setSpeechEngine(engine) }
        )
    }
}
