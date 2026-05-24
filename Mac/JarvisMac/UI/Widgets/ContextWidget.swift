import SwiftUI

struct ContextWidget: View {
    let state: AppState
    let controller: JarvisController
    var onClose: (() -> Void)? = nil

    var body: some View {
        WidgetCard(title: "Context", systemImage: "brain.head.profile", accent: .purple, onClose: onClose) {
            let snap = controller.context.snapshot
            VStack(alignment: .leading, spacing: 6) {
                row("phase",        snap.phase.rawValue)
                row("transcript",   snap.currentTranscript)
                row("last command", snap.lastCommand)
                row("active app",   snap.activeAppName)
                row("camera",       snap.lastCameraSummary)
                row("home",         snap.lastHomeSummary)
                row("android",      snap.lastAndroidContext)

                if !state.timeline.isEmpty {
                    Divider().background(Color.white.opacity(0.1))
                    Text("Recent activity").font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(state.timeline.suffix(4)) { e in
                        HStack(spacing: 6) {
                            Image(systemName: e.symbol).foregroundStyle(.purple)
                                .frame(width: 16)
                            Text(e.title)
                                .font(.caption)
                                .lineLimit(1)
                            if let d = e.detail {
                                Text("· \(d)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        if !value.isEmpty {
            HStack(alignment: .top, spacing: 6) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 96, alignment: .leading)
                Text(value)
                    .font(.caption)
                    .lineLimit(2)
            }
        }
    }
}
