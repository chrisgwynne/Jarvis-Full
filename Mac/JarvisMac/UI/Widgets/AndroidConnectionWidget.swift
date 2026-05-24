import SwiftUI

struct AndroidConnectionWidget: View {
    let state: AppState
    var onClose: (() -> Void)? = nil

    var body: some View {
        WidgetCard(title: "Android Link",
                   systemImage: "iphone.radiowaves.left.and.right",
                   accent: .green, onClose: onClose) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Circle()
                        .fill(state.androidServerStatus.isHealthy ? Color.green : Color.orange)
                        .frame(width: 10, height: 10)
                    Text(state.androidServerStatus.label)
                        .font(.subheadline)
                    Spacer()
                    if state.androidAuthRequired {
                        Label("Token", systemImage: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("ws://<your-mac-ip>:\(state.webSocketPort)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("\(state.connectedClients) client\(state.connectedClients == 1 ? "" : "s") connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !state.lastAndroidContext.isEmpty {
                    Divider().background(Color.white.opacity(0.1))
                    Text("Last handoff")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(state.lastAndroidContext)
                        .font(.caption)
                        .lineLimit(3)
                    if let ts = state.lastAndroidTimestamp {
                        Text(ts, format: .relative(presentation: .named))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
