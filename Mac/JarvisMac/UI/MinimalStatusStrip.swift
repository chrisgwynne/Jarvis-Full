import SwiftUI

/// Thin, unobtrusive bottom strip — toggleable via voice or corner button.
/// Shows the minimum needed to confirm Jarvis is alive.
struct MinimalStatusStrip: View {
    let state: AppState

    var body: some View {
        HStack(spacing: 16) {
            statusDot("wake", healthy: state.wakeWordStatus.isHealthy)
            statusDot("mic",  healthy: state.microphoneStatus.isHealthy)
            statusDot("cam",  healthy: state.cameraStatus.isHealthy)

            if !state.memoryRows.isEmpty {
                Text("\(state.memoryRows.count) mem")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if state.isOffline {
                Text("LOCAL")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(Color.green.opacity(0.12)))
                    .overlay(Capsule().strokeBorder(Color.green.opacity(0.28)))
            }

            if let ms = state.latencyMillis["stt"], ms > 0 {
                Text(String(format: "%.0fms", ms))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.50))
        .overlay(Divider().opacity(0.15), alignment: .top)
    }

    private func statusDot(_ label: String, healthy: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(healthy ? Color.green : Color.orange)
                .frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}
