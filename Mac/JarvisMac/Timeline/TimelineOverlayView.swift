import SwiftUI

/// Activity timeline overlay: shows grouped, filterable recent events.
struct TimelineOverlayView: View {
    let store: ActivityTimelineStore
    let activeApp: String

    @State private var searchText = ""
    @State private var filterKind: ActivityEventKind? = nil

    private var filtered: [ActivityEvent] {
        var base = searchText.isEmpty ? store.recent(limit: 80) : store.search(searchText)
        if let kind = filterKind { base = base.filter { $0.kind == kind } }
        return base
    }

    private var grouped: [(label: String, events: [ActivityEvent])] {
        store.groupedByHour(from: filtered)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            filterStrip
            Divider().overlay(Color.white.opacity(0.07))
            if grouped.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                        ForEach(grouped, id: \.label) { group in
                            Section(header: groupHeader(group.label,
                                                        count: group.events.count)) {
                                ForEach(group.events) { event in
                                    eventRow(event)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("Search timeline…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.caption)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.04))
    }

    // MARK: - Filter strip

    private var filterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                filterChip(label: "All", kind: nil)
                filterChip(label: "Commands", kind: .command)
                filterChip(label: "Overlays", kind: .overlayOpened)
                filterChip(label: "Memory", kind: .memorySaved)
                filterChip(label: "Screen", kind: .screenCapture)
                filterChip(label: "Camera", kind: .cameraCapture)
                filterChip(label: "Apps", kind: .appSwitch)
                filterChip(label: "Errors", kind: .error)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private func filterChip(label: String, kind: ActivityEventKind?) -> some View {
        let active = filterKind == kind
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { filterKind = kind }
        } label: {
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.5)
                .foregroundStyle(active ? .black : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(active ? Color.cyan : Color.white.opacity(0.07))
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Group header

    private func groupHeader(_ label: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .tracking(1)
            Spacer()
            Text("\(count)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .background(Color(red: 0.03, green: 0.05, blue: 0.10).opacity(0.9))
    }

    // MARK: - Event row

    private func eventRow(_ event: ActivityEvent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // Kind dot
            Circle()
                .fill(Color(hex: event.kind.accentHex))
                .frame(width: 6, height: 6)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(event.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    Text(event.timestamp, style: .time)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                if let detail = event.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let app = event.appName, !app.isEmpty {
                    Text(app)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.0))
        .overlay(
            Rectangle()
                .fill(Color(hex: event.kind.accentHex).opacity(0.20))
                .frame(width: 2),
            alignment: .leading
        )
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(searchText.isEmpty ? "No activity yet" : "No results")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            if searchText.isEmpty {
                Text("Commands and events appear here.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

// MARK: - Color hex helper (scoped to this file if not already global)

private extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: h).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
