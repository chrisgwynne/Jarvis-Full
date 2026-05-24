import SwiftUI

struct DebugLogsWidget: View {
    let state: AppState
    var onClose: (() -> Void)? = nil
    @State private var filter: LogFilter = .info

    enum LogFilter: String, CaseIterable, Identifiable {
        case all, info, warn, error
        var id: String { rawValue }
        var displayName: String { rawValue.capitalized }
    }

    var body: some View {
        WidgetCard(title: "Logs", systemImage: "terminal.fill", accent: .gray, onClose: onClose) {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Filter", selection: $filter) {
                    ForEach(LogFilter.allCases) { f in
                        Text(f.displayName).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(filtered) { entry in
                                Text(entry.formatted)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(color(for: entry.level))
                                    .id(entry.id)
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                    .onChange(of: state.logs.count) { _, _ in
                        if let last = filtered.last {
                            withAnimation(.easeOut(duration: 0.1)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
    }

    private var filtered: [LogEntry] {
        switch filter {
        case .all:   return state.logs
        case .info:  return state.logs.filter { $0.level == .info || $0.level == .warn || $0.level == .error }
        case .warn:  return state.logs.filter { $0.level == .warn || $0.level == .error }
        case .error: return state.logs.filter { $0.level == .error }
        }
    }

    private func color(for level: LogEntry.Level) -> Color {
        switch level {
        case .debug: return .secondary
        case .info:  return .primary
        case .warn:  return .yellow
        case .error: return .red
        }
    }
}
