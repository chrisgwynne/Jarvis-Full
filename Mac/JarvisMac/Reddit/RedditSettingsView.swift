import SwiftUI

/// Settings → Reddit.  Edits the same `RedditStore` the overlay reads,
/// so every change here is visible to "show reddit" / "what are people
/// saying about X" without a relaunch.
///
/// Layout follows the LiveNewsChannelsSettingsView pattern (sidebar +
/// editor + add/delete) so the entire Settings module stays visually
/// consistent.
struct RedditSettingsView: View {
    @Bindable var store: RedditStore

    @State private var selectedID: String? = nil
    @State private var editing: RedditSource? = nil
    @State private var showAddSheet: Bool = false
    @State private var showResetConfirm: Bool = false
    @State private var testResult: String = ""
    @State private var isTesting: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                sidebar
                    .frame(minWidth: 220, idealWidth: 250, maxWidth: 290)

                Group {
                    if let s = editing {
                        editor(s)
                    } else {
                        placeholder
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Toggle("Enable Reddit", isOn: $store.enabled)
                .toggleStyle(.switch)
                .font(.system(size: 12, weight: .semibold))

            if let lastFull = store.lastFullRefreshAt {
                Label("Last refresh: \(relativeAge(lastFull))",
                      systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Label("\(store.sources.count) sources, \(store.posts.count) posts cached",
                  systemImage: "tray.full")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                Task { await store.refreshAllEnabledSources() }
            } label: {
                Label(store.isRefreshing ? "Refreshing…" : "Refresh Now",
                      systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(store.isRefreshing || !store.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selectedID) {
                Section("Subreddits") {
                    ForEach(store.sources) { s in
                        sourceRow(s).tag(s.id)
                    }
                }
            }
            .listStyle(.sidebar)
            .onChange(of: selectedID) { _, id in
                editing = store.sources.first { $0.id == id }
                testResult = ""
            }

            Divider()

            HStack {
                Button { showAddSheet = true } label: {
                    Label("Add Subreddit", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
                Spacer()
                Button { showResetConfirm = true } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(8)
        }
        .sheet(isPresented: $showAddSheet) {
            AddSubredditSheet { name, display in
                if let s = store.addSource(name: name, displayName: display) {
                    selectedID = s.id
                    editing = s
                }
            }
        }
        .confirmationDialog(
            "Reset Reddit sources to defaults?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                store.resetToDefaults()
                editing = nil
                selectedID = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes all configured subreddits and restores the default set.")
        }
    }

    @ViewBuilder
    private func sourceRow(_ s: RedditSource) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(s.enabled ? Color.orange.opacity(0.8) : Color.gray.opacity(0.3))
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text("r/\(s.subreddit)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(s.enabled ? .primary : .secondary)
                HStack(spacing: 4) {
                    Text(s.sortMode.displayName)
                    if s.sortMode == .top {
                        Text("·").foregroundStyle(.secondary.opacity(0.5))
                        Text(s.timeRange.displayName)
                    }
                    if let last = store.lastRefreshDates[s.id] {
                        Text("·").foregroundStyle(.secondary.opacity(0.5))
                        Text(relativeAge(last))
                    }
                    if store.lastErrors[s.id] != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red.opacity(0.85))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    // MARK: - Editor

    @ViewBuilder
    private func editor(_ s: RedditSource) -> some View {
        let binding = Binding<RedditSource>(
            get: { editing ?? s },
            set: { editing = $0 })
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Edit Subreddit")
                    .font(.system(size: 15, weight: .semibold))

                row("Name") {
                    Text("r/\(s.subreddit)")
                        .font(.system(size: 12, design: .monospaced))
                }
                row("Display") {
                    TextField("r/technology", text: binding.displayName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                }

                row("Sort") {
                    Picker("", selection: binding.sortMode) {
                        ForEach(RedditSource.SortMode.allCases) { m in
                            Text(m.displayName).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 280)
                }
                if (editing ?? s).sortMode == .top {
                    row("Window") {
                        Picker("", selection: binding.timeRange) {
                            ForEach(RedditSource.TimeRange.allCases) { t in
                                Text(t.displayName).tag(t)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 180)
                    }
                }
                row("Limit") {
                    Stepper(value: binding.limit, in: 5...100, step: 5) {
                        Text("\((editing ?? s).limit) posts")
                            .font(.system(size: 12))
                    }
                    .frame(width: 200)
                }
                row("Refresh") {
                    Picker("", selection: binding.refreshIntervalMinutes) {
                        Text("15 min").tag(15)
                        Text("30 min").tag(30)
                        Text("1 hour").tag(60)
                        Text("2 hours").tag(120)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 280)
                }

                Toggle("Enabled", isOn: binding.enabled)
                    .toggleStyle(.switch)
                Toggle("Include NSFW", isOn: binding.includeNSFW)
                    .toggleStyle(.switch)

                Divider()

                if let err = store.lastErrors[s.id] {
                    Text("Last error: \(err)")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if isTesting {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.6)
                        Text("Testing…").font(.caption).foregroundStyle(.secondary)
                    }
                } else if !testResult.isEmpty {
                    Text(testResult)
                        .font(.caption)
                        .foregroundStyle(testResult.hasPrefix("OK") ? .green : .red)
                }

                HStack(spacing: 10) {
                    Button("Save") {
                        if let e = editing { store.update(e) }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)

                    Button("Test") {
                        if let e = editing { test(e) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isTesting)

                    Button("Refresh Now") {
                        Task {
                            if let e = editing {
                                await store.refreshSource(e)
                            }
                        }
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button("Delete", role: .destructive) {
                        store.remove(id: s.id)
                        editing = nil
                        selectedID = nil
                    }
                    .buttonStyle(.bordered)
                    .foregroundStyle(.red)
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func row<Trailing: View>(_ label: String,
                                     @ViewBuilder _ trailing: () -> Trailing) -> some View {
        HStack(alignment: .center) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            trailing()
            Spacer(minLength: 0)
        }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 32))
                .foregroundStyle(.secondary.opacity(0.3))
            Text("Select a subreddit to edit")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Or click + to add one.\nReddit JSON feeds — no API key required.")
                .font(.caption)
                .foregroundStyle(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Test action

    private func test(_ s: RedditSource) {
        isTesting = true
        testResult = ""
        Task {
            let client = RedditClient()
            do {
                let posts = try await client.fetchSubreddit(s)
                testResult = "OK — fetched \(posts.count) posts."
            } catch {
                testResult = "Error: \(error.localizedDescription)"
            }
            isTesting = false
        }
    }

    private func relativeAge(_ date: Date) -> String {
        let s = -date.timeIntervalSinceNow
        if s < 60     { return "just now" }
        if s < 3600   { return "\(Int(s/60))m ago" }
        if s < 86_400 { return "\(Int(s/3600))h ago" }
        return "\(Int(s/86_400))d ago"
    }
}

// MARK: - Add sheet

private struct AddSubredditSheet: View {
    let onAdd: (String, String?) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var displayName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Subreddit").font(.headline)

            LabeledContent("Subreddit") {
                TextField("technology, apple, LocalLLaMA…", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Display") {
                TextField("Optional — defaults to r/<name>", text: $displayName)
                    .textFieldStyle(.roundedBorder)
            }
            .font(.system(size: 12))

            Text("You can paste 'r/technology' or 'https://reddit.com/r/technology' — the prefix and URL bits are stripped automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(.bordered)
                Spacer()
                Button("Add") {
                    let cleaned = RedditSource.normalise(name: name) ?? ""
                    guard !cleaned.isEmpty else { return }
                    onAdd(cleaned, displayName.isEmpty ? nil : displayName)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(RedditSource.normalise(name: name) == nil)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
