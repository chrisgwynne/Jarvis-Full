import SwiftUI

struct NewsFeedSettingsView: View {
    @State var store: NewsStore
    @State var scheduler: NewsRefreshScheduler

    @State private var selectedFeedID: String? = nil
    @State private var editingFeed: NewsFeed? = nil
    @State private var showAddSheet: Bool = false
    @State private var testResult: String = ""
    @State private var isTesting: Bool = false

    var body: some View {
        HSplitView {
            feedList
                .frame(minWidth: 200, idealWidth: 230, maxWidth: 260)

            Group {
                if let feed = editingFeed {
                    FeedEditorView(
                        feed: feed,
                        isTesting: isTesting,
                        testResult: testResult,
                        onSave: { updated in
                            store.saveFeed(updated)
                            editingFeed = updated
                        },
                        onTest: { testFeed($0) },
                        onDelete: {
                            store.deleteFeed(id: feed.id)
                            editingFeed = nil
                            selectedFeedID = nil
                        }
                    )
                } else {
                    placeholder
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { store.loadFeeds() }
        .sheet(isPresented: $showAddSheet) {
            AddFeedSheet { newFeed in
                store.saveFeed(newFeed) { _ in
                    store.loadFeeds()
                }
            }
        }
    }

    // MARK: - Feed list

    private var feedList: some View {
        VStack(spacing: 0) {
            List(selection: $selectedFeedID) {
                Section("Subscribed Feeds") {
                    ForEach(store.feeds) { feed in
                        feedRow(feed)
                            .tag(feed.id)
                    }
                }
            }
            .listStyle(.sidebar)
            .onChange(of: selectedFeedID) { _, id in
                editingFeed = store.feeds.first { $0.id == id }
                testResult = ""
            }

            Divider()

            HStack {
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add Feed", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.cyan)

                Spacer()

                Button {
                    Task { await scheduler.refreshAll() }
                } label: {
                    Label("Refresh All", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(scheduler.isRefreshing)
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private func feedRow(_ feed: NewsFeed) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(feed.enabled ? Color.cyan.opacity(0.8) : Color.gray.opacity(0.3))
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(feed.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(feed.enabled ? .primary : .secondary)
                Text(feed.category.isEmpty ? feed.sourceType.displayName : feed.category)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let last = store.lastRefreshDates[feed.id] {
                Text(refreshAge(last))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary.opacity(0.6))
            }
        }
        .padding(.vertical, 2)
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "newspaper")
                .font(.system(size: 32))
                .foregroundStyle(.secondary.opacity(0.3))
            Text("Select a feed to edit")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func testFeed(_ feed: NewsFeed) {
        isTesting = true
        testResult = ""
        Task {
            do {
                let items = try await RSSFetcher.fetch(feed: feed)
                testResult = "OK — fetched \(items.count) items"
            } catch {
                testResult = "Error: \(error.localizedDescription)"
            }
            isTesting = false
        }
    }

    private func refreshAge(_ date: Date) -> String {
        let s = -date.timeIntervalSinceNow
        if s < 60 { return "<1m" }
        if s < 3600 { return "\(Int(s/60))m" }
        return "\(Int(s/3600))h"
    }
}

// MARK: - Feed editor

private struct FeedEditorView: View {
    @State var feed: NewsFeed
    let isTesting: Bool
    let testResult: String
    let onSave: (NewsFeed) -> Void
    let onTest: (NewsFeed) -> Void
    let onDelete: () -> Void

    @State private var isDirty: Bool = false
    @State private var showDeleteConfirm: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Edit Feed")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)

                formField("Name", binding: $feed.name)
                formField("URL", binding: $feed.url)
                formField("Category", binding: $feed.category)

                HStack {
                    Text("Type")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .leading)
                    Picker("", selection: $feed.sourceType) {
                        ForEach(NewsSourceType.allCases) { t in
                            Text(t.displayName).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }

                HStack {
                    Text("Interval")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .leading)
                    Picker("", selection: $feed.refreshIntervalMinutes) {
                        Text("15 min").tag(15)
                        Text("30 min").tag(30)
                        Text("1 hour").tag(60)
                        Text("2 hours").tag(120)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                }

                Toggle("Enabled", isOn: $feed.enabled)
                    .font(.system(size: 12))
                    .toggleStyle(.switch)
                    .onChange(of: feed.enabled) { _, _ in isDirty = true }

                // Test result
                if isTesting {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.7)
                        Text("Testing…").font(.caption).foregroundStyle(.secondary)
                    }
                } else if !testResult.isEmpty {
                    Text(testResult)
                        .font(.caption)
                        .foregroundStyle(testResult.hasPrefix("OK") ? .green : .red)
                }

                HStack(spacing: 10) {
                    Button("Save") { onSave(feed); isDirty = false }
                        .buttonStyle(.borderedProminent)
                        .tint(.cyan)
                        .disabled(!isDirty)

                    Button("Test Feed") { onTest(feed) }
                        .buttonStyle(.bordered)
                        .disabled(isTesting)

                    Spacer()

                    Button("Delete", role: .destructive) { showDeleteConfirm = true }
                        .buttonStyle(.bordered)
                        .foregroundStyle(.red)
                }

                Spacer()
            }
            .padding(16)
        }
        .onChange(of: feed.name) { _, _ in isDirty = true }
        .onChange(of: feed.url) { _, _ in isDirty = true }
        .onChange(of: feed.category) { _, _ in isDirty = true }
        .onChange(of: feed.sourceType) { _, _ in isDirty = true }
        .onChange(of: feed.refreshIntervalMinutes) { _, _ in isDirty = true }
        .confirmationDialog("Delete feed?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove \"\(feed.name)\" and all its articles.")
        }
    }

    @ViewBuilder
    private func formField(_ label: String, binding: Binding<String>) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
                .padding(.top, 6)
            TextField(label, text: binding)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
        }
    }
}

// MARK: - Add feed sheet

private struct AddFeedSheet: View {
    let onAdd: (NewsFeed) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var url: String = ""
    @State private var category: String = ""
    @State private var sourceType: NewsSourceType = .rss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Feed")
                .font(.headline)

            Group {
                LabeledContent("Name") {
                    TextField("BBC Technology", text: $name).textFieldStyle(.roundedBorder)
                }
                LabeledContent("URL") {
                    TextField("https://…/rss.xml", text: $url).textFieldStyle(.roundedBorder)
                }
                LabeledContent("Category") {
                    TextField("tech, news…", text: $category).textFieldStyle(.roundedBorder)
                }
                LabeledContent("Type") {
                    Picker("", selection: $sourceType) {
                        ForEach(NewsSourceType.allCases) { t in Text(t.displayName).tag(t) }
                    }.pickerStyle(.segmented)
                }
            }
            .font(.system(size: 12))

            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(.bordered)
                Spacer()
                Button("Add") {
                    guard !name.isEmpty, !url.isEmpty else { return }
                    onAdd(NewsFeed(name: name, url: url, category: category, sourceType: sourceType))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .disabled(name.isEmpty || url.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
