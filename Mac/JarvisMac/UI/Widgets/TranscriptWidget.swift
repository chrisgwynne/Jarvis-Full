import SwiftUI

struct TranscriptWidget: View {
    let state: AppState
    var onClose: (() -> Void)? = nil

    var body: some View {
        WidgetCard(title: "Transcript", systemImage: "text.bubble", accent: .mint, onClose: onClose) {
            VStack(alignment: .leading, spacing: 8) {
                if !state.partialTranscript.isEmpty {
                    Text(state.partialTranscript)
                        .font(.title3)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                } else if !state.lastFinalTranscript.isEmpty {
                    Text(state.lastFinalTranscript)
                        .font(.title3)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                } else {
                    Text("Waiting for input…")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                if let intent = state.lastIntent {
                    Divider().background(Color.white.opacity(0.1))
                    HStack(spacing: 6) {
                        Image(systemName: "scope")
                            .foregroundStyle(.mint)
                        Text("Last intent: \(String(describing: intent))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                if !state.lastSpoken.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "speaker.wave.2.fill")
                            .foregroundStyle(.yellow)
                        Text(state.lastSpoken)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        }
    }
}
