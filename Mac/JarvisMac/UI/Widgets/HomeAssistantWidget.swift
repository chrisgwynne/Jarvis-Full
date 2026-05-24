import SwiftUI

struct HomeAssistantWidget: View {
    let state: AppState
    let controller: JarvisController
    var onClose: (() -> Void)? = nil

    var body: some View {
        WidgetCard(title: "Home Assistant", systemImage: "house.fill", accent: .indigo, onClose: onClose) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(state.homeAssistantStatus.isHealthy ? Color.green : Color.orange)
                        .frame(width: 10, height: 10)
                    Text(state.homeAssistantStatus.label)
                        .font(.subheadline)
                    Spacer()
                    Button {
                        Task { await controller.refreshHomeAssistant() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .disabled(!controller.smartHome.isConfigured)
                }
                Text("\(state.homeEntitiesCount) entities")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !state.homeSummary.isEmpty {
                    Text(state.homeSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if !controller.smartHome.isConfigured {
                    Text("Add base URL + long-lived token in Settings to enable.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
