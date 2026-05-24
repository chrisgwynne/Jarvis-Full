import SwiftUI

// MARK: - BrainOverlayView

struct BrainOverlayView: View {

    enum Tab: String, CaseIterable {
        case memories = "Memories"
        case episodes = "Episodes"
        case tasks    = "Tasks"
    }

    @State private var selectedTab: Tab = .memories
    @State private var searchText = ""
    @State private var memories:  [MemoryCandidate] = []
    @State private var episodes:  [ConversationEpisode] = []
    @State private var tasks:     [BrainTask] = []
    @State private var isLoading  = false

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search brain…", text: $searchText)
                    .textFieldStyle(.plain)
                    .onSubmit { Task { await reload() } }
                if !searchText.isEmpty {
                    Button { searchText = ""; Task { await reload() } } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
            .padding(.top, 10)

            // Tab bar
            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.top, 8)

            Divider().padding(.top, 8)

            // Content
            if isLoading {
                Spacer()
                ProgressView().scaleEffect(0.8)
                Spacer()
            } else {
                switch selectedTab {
                case .memories: memoriesList
                case .episodes: episodesList
                case .tasks:    tasksListView
                }
            }
        }
        .task { await reload() }
        .onChange(of: selectedTab) { _, _ in Task { await reload() } }
    }

    // MARK: - Memories tab

    private var memoriesList: some View {
        List {
            if memories.isEmpty {
                ContentUnavailableView("No memories yet",
                    systemImage: "brain",
                    description: Text("Brain memory builds up over time as you interact with Jarvis."))
            } else {
                ForEach(memories) { entry in
                    BrainMemoryItemRow(entry: entry)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task {
                                    await BrainMemoryStore.shared.delete(id: entry.id)
                                    await reload()
                                }
                            } label: { Label("Delete", systemImage: "trash") }

                            Button {
                                Task {
                                    await BrainMemoryStore.shared.pin(entry.id, pinned: !entry.isPinned)
                                    await reload()
                                }
                            } label: {
                                Label(entry.isPinned ? "Unpin" : "Pin",
                                      systemImage: entry.isPinned ? "pin.slash" : "pin")
                            }.tint(.indigo)
                        }
                }
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Episodes tab

    private var episodesList: some View {
        List {
            if episodes.isEmpty {
                ContentUnavailableView("No episodes",
                    systemImage: "clock.arrow.2.circlepath",
                    description: Text("Episodes group related activity into time-bounded sessions."))
            } else {
                ForEach(episodes) { ep in
                    BrainEpisodeItemRow(episode: ep)
                }
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Tasks tab

    private var tasksListView: some View {
        List {
            if tasks.isEmpty {
                ContentUnavailableView("No queued tasks",
                    systemImage: "checklist",
                    description: Text("Brain background tasks appear here."))
            } else {
                ForEach(tasks) { task in
                    BrainQueueTaskRow(task: task)
                }
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Data loading

    @MainActor
    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        switch selectedTab {
        case .memories:
            if searchText.isEmpty {
                memories = BrainMemoryStore.shared.recent(limit: 50)
            } else {
                memories = await BrainMemoryStore.shared.search(query: searchText, limit: 50)
            }
        case .episodes:
            episodes = EpisodeStore.shared.recentEpisodes(limit: 20)
        case .tasks:
            tasks = BrainTaskQueue.shared.allActive()
        }
    }
}

// MARK: - Row views

private struct BrainMemoryItemRow: View {
    let entry: MemoryCandidate

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                if entry.isPinned {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.indigo)
                }
                Text(entry.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer()
                scoreBar
            }
            Text(entry.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 6) {
                typeBadge
                Text(relativeTime(entry.updatedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private var scoreBar: some View {
        let score = min(1.0, entry.importance * entry.confidence)
        return HStack(spacing: 2) {
            ForEach(0..<5) { i in
                RoundedRectangle(cornerRadius: 2)
                    .frame(width: 4, height: 10)
                    .foregroundStyle(Double(i) / 5.0 < score ? Color.indigo : Color.secondary.opacity(0.2))
            }
        }
    }

    private var typeBadge: some View {
        Text(entry.type.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.indigo.opacity(0.15), in: Capsule())
            .foregroundStyle(.indigo)
    }

    private func relativeTime(_ date: Date) -> String {
        let secs = -date.timeIntervalSinceNow
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(Int(secs / 60))m ago" }
        if secs < 86400 { return "\(Int(secs / 3600))h ago" }
        return "\(Int(secs / 86400))d ago"
    }
}

private struct BrainEpisodeItemRow: View {
    let episode: ConversationEpisode

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: episode.episodeType.systemImage)
                    .font(.caption)
                    .foregroundStyle(.indigo)
                Text(episode.title)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Text(durationText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !episode.dominantTopics.isEmpty {
                Text(episode.dominantTopics.prefix(4).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(episode.startedAt, style: .relative)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
    }

    private var durationText: String {
        let mins = Int(episode.durationMinutes ?? 0)
        if mins < 60 { return "\(mins)m" }
        return "\(mins / 60)h \(mins % 60)m"
    }
}

private struct BrainQueueTaskRow: View {
    let task: BrainTask

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .frame(width: 8, height: 8)
                .foregroundStyle(statusColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(task.type.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("•").font(.caption2).foregroundStyle(.tertiary)
                    Text(task.status.rawValue.capitalized)
                        .font(.caption2)
                        .foregroundStyle(statusColor)
                    if task.progress > 0 {
                        Text("•").font(.caption2).foregroundStyle(.tertiary)
                        Text("\(Int(task.progress * 100))%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 3)
    }

    private var statusColor: Color {
        switch task.status {
        case .queued:    return .orange
        case .running:   return .blue
        case .paused:    return .yellow
        case .cancelled: return .secondary
        case .completed: return .green
        case .failed:    return .red
        }
    }
}
