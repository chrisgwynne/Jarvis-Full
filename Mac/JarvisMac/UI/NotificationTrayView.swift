import SwiftUI

/// Notification tray overlay — shows pending proactivity signals with
/// dismiss, open, and snooze actions. Opened via "what needs my attention"
/// or the `.notifications` OverlayKind.
struct NotificationTrayView: View {
    let proactivity: ProactivityEngine
    let overlayManager: OverlayManager
    var onOpenArticle: ((String) -> Void)?   // signal ID → open source article

    @State private var selectedSource: SignalSource? = nil

    var filteredSignals: [ProactivitySignal] {
        guard let src = selectedSource else { return proactivity.pendingSignals }
        return proactivity.pendingSignals.filter { $0.source == src }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if proactivity.isPaused {
                pausedBanner
            }
            sourceFilter
            Divider().opacity(0.2)
            signalList
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "bell.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
            Text("Notifications")
                .font(.headline)
            if proactivity.pendingCount > 0 {
                Text("\(proactivity.pendingCount)")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.orange))
                    .foregroundStyle(.black)
            }
            Spacer()
            if !proactivity.pendingSignals.isEmpty {
                Button("Clear all") {
                    withAnimation { proactivity.dismissAll() }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Paused banner

    private var pausedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.yellow)
            Text("Proactivity paused")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Resume") { proactivity.resume() }
                .font(.caption.weight(.medium))
                .foregroundStyle(.yellow)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.yellow.opacity(0.08))
    }

    // MARK: Source filter

    @ViewBuilder
    private var sourceFilter: some View {
        let sources = Array(Set(proactivity.pendingSignals.map(\.source))).sorted {
            $0.rawValue < $1.rawValue
        }
        if !sources.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    filterChip(label: "All", icon: "tray.fill",
                               active: selectedSource == nil) {
                        selectedSource = nil
                    }
                    ForEach(sources, id: \.rawValue) { src in
                        filterChip(label: src.displayName,
                                   icon: src.systemImage,
                                   active: selectedSource == src) {
                            selectedSource = selectedSource == src ? nil : src
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
    }

    private func filterChip(label: String, icon: String,
                             active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption2)
                Text(label).font(.caption.weight(active ? .semibold : .regular))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(active ? Color.orange.opacity(0.25) : Color.white.opacity(0.06))
            )
            .overlay(Capsule().strokeBorder(
                active ? Color.orange.opacity(0.5) : Color.clear, lineWidth: 1))
            .foregroundStyle(active ? .orange : .secondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: Signal list

    @ViewBuilder
    private var signalList: some View {
        if filteredSignals.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "bell.slash.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text(proactivity.pendingSignals.isEmpty
                     ? "No notifications" : "No notifications for this source")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredSignals) { signal in
                        SignalRow(signal: signal) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                proactivity.dismiss(signal.id)
                            }
                        } onOpen: {
                            onOpenArticle?(signal.id)
                        }
                        if signal.id != filteredSignals.last?.id {
                            Divider().opacity(0.15).padding(.leading, 52)
                        }
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }
}

// MARK: - Signal Row

private struct SignalRow: View {
    let signal: ProactivitySignal
    var onDismiss: () -> Void
    var onOpen: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            // Priority dot + source icon
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: signal.source.systemImage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                if signal.priority >= .high {
                    Circle()
                        .fill(signal.priority >= .urgent ? .red : .orange)
                        .frame(width: 8, height: 8)
                        .offset(x: 3, y: 3)
                }
            }

            // Content
            VStack(alignment: .leading, spacing: 3) {
                Text(signal.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(signal.source.displayName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(Color(white: 0.4))
                    Text(signal.createdAt.formatted(.relative(presentation: .named)))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Actions on hover
            if isHovered {
                HStack(spacing: 5) {
                    if signal.suggestedAction != nil {
                        rowButton("arrow.up.forward.app", tip: "Open") { onOpen() }
                    }
                    rowButton("xmark", tip: "Dismiss") { onDismiss() }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(isHovered ? Color.white.opacity(0.05) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.13), value: isHovered)
    }

    @ViewBuilder
    private func rowButton(_ icon: String, tip: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(Color.white.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(tip)
    }
}
