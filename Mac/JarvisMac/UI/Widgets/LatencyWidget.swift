import SwiftUI

struct LatencyWidget: View {
    let state: AppState
    var onClose: (() -> Void)? = nil

    private let order: [LatencyStage] = [
        .wakeDetect, .sttFirstPartial, .sttFinal,
        .intentRoute, .fastRoute, .llmStart, .llmComplete,
        .actionExecute, .ttsStart, .ttsComplete, .bargeIn
    ]

    var body: some View {
        WidgetCard(title: "Latency", systemImage: "speedometer", accent: .yellow, onClose: onClose) {
            if state.latencyMillis.isEmpty {
                Text("No measurements yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(order, id: \.rawValue) { stage in
                        if let ms = state.latencyMillis[stage.rawValue] {
                            HStack {
                                Text(displayName(stage))
                                    .font(.caption.weight(.semibold))
                                    .frame(width: 130, alignment: .leading)
                                Bar(value: ms, max: 2000, color: color(for: stage))
                                Text("\(Int(ms)) ms")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 56, alignment: .trailing)
                            }
                        }
                    }
                }
            }
        }
    }

    private func displayName(_ stage: LatencyStage) -> String {
        switch stage {
        case .wakeDetect:      return "Wake → trigger"
        case .sttStart:        return "STT start"
        case .sttFirstPartial: return "STT 1st partial"
        case .sttFinal:        return "STT final"
        case .intentRoute:     return "Intent route"
        case .fastRoute:       return "Fast route"
        case .llmStart:        return "LLM send"
        case .llmComplete:     return "LLM total"
        case .actionExecute:   return "Action"
        case .ttsStart:        return "TTS start"
        case .ttsComplete:     return "TTS total"
        case .bargeIn:         return "Barge-in"
        default:               return stage.rawValue
        }
    }

    private func color(for stage: LatencyStage) -> Color {
        switch stage {
        case .wakeDetect, .sttStart, .sttFirstPartial, .sttFinal: return .cyan
        case .intentRoute, .fastRoute: return .green
        case .llmStart, .llmComplete:  return .indigo
        case .actionExecute:           return .purple
        case .ttsStart, .ttsComplete:  return .yellow
        case .bargeIn:                 return .orange
        default:                       return .secondary
        }
    }
}

private struct Bar: View {
    let value: Double
    let max: Double
    let color: Color
    var body: some View {
        GeometryReader { geo in
            let frac = min(1.0, value / max)
            Capsule()
                .fill(Color.white.opacity(0.08))
                .overlay(
                    Capsule()
                        .fill(color.opacity(0.7))
                        .frame(width: geo.size.width * frac),
                    alignment: .leading
                )
        }
        .frame(height: 6)
    }
}
