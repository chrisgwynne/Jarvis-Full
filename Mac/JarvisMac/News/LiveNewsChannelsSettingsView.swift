import SwiftUI

/// Settings UI for editing the live news / video channel list that
/// powers "watch news", channel cycling ("next channel"), and the
/// channel selector strip inside the News overlay.
///
/// The data layer (`NewsChannelStore`) persists CRUD to
/// `~/Library/Application Support/JarvisMac/news_channels.json`.
/// This view is the user-facing surface for those operations so the
/// default channel list (BBC / Sky / Bloomberg / DW / Al Jazeera /
/// ABC) is never the only thing the user can use — they can add their
/// own YouTube live URLs, paste raw `<iframe>` snippets, point at HLS
/// streams, or swap any existing channel's URL when YouTube rotates
/// an embed.
struct LiveNewsChannelsSettingsView: View {
    @Bindable var store: NewsChannelStore

    @State private var selectedID: String? = nil
    @State private var editing: NewsChannel? = nil
    @State private var showAddSheet: Bool = false
    @State private var showResetConfirm: Bool = false

    var body: some View {
        HSplitView {
            channelList
                .frame(minWidth: 220, idealWidth: 250, maxWidth: 280)

            Group {
                if let ch = editing {
                    ChannelEditorView(
                        channel: ch,
                        isActive: store.activeChannelID == ch.id,
                        onSave: { updated in
                            store.update(updated)
                            editing = updated
                        },
                        onMakeActive: {
                            if ch.enabled {
                                store.setActive(id: ch.id)
                            }
                        },
                        onDelete: {
                            store.remove(id: ch.id)
                            editing = nil
                            selectedID = nil
                        }
                    )
                } else {
                    placeholder
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Channel list

    private var channelList: some View {
        VStack(spacing: 0) {
            List(selection: $selectedID) {
                Section("Live Channels") {
                    ForEach(store.channels) { ch in
                        channelRow(ch)
                            .tag(ch.id)
                    }
                }
            }
            .listStyle(.sidebar)
            .onChange(of: selectedID) { _, id in
                editing = store.channels.first { $0.id == id }
            }

            Divider()

            HStack {
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add Channel", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.cyan)

                Spacer()

                Button {
                    showResetConfirm = true
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
            }
            .padding(8)
        }
        .sheet(isPresented: $showAddSheet) {
            AddChannelSheet { newChannel in
                store.add(newChannel)
                selectedID = newChannel.id
                editing = newChannel
            }
        }
        .confirmationDialog(
            "Reset live channels to defaults?",
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
            Text("Removes your custom channels and restores BBC, Sky, Bloomberg, DW, Al Jazeera and ABC.")
        }
    }

    @ViewBuilder
    private func channelRow(_ ch: NewsChannel) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(ch.enabled ? Color.cyan.opacity(0.8) : Color.gray.opacity(0.3))
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(ch.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ch.enabled ? .primary : .secondary)
                    if store.activeChannelID == ch.id {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 9))
                            .foregroundStyle(.cyan)
                    }
                    if ch.isDefault {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.yellow.opacity(0.8))
                    }
                }
                Text(ch.kind.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "tv")
                .font(.system(size: 32))
                .foregroundStyle(.secondary.opacity(0.3))
            Text("Select a channel to edit")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Channels are the live video sources used by\n\"watch news\" and channel cycling.")
                .font(.caption)
                .foregroundStyle(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Channel editor

private struct ChannelEditorView: View {
    @State var channel: NewsChannel
    let isActive: Bool
    let onSave: (NewsChannel) -> Void
    let onMakeActive: () -> Void
    let onDelete: () -> Void

    @State private var isDirty: Bool = false
    @State private var showDeleteConfirm: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Edit Channel")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    if isActive {
                        Text("ACTIVE")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.cyan.opacity(0.25))
                            .foregroundStyle(.cyan)
                            .clipShape(Capsule())
                    }
                }

                formField("Name", binding: $channel.name)
                formField("URL", binding: $channel.url)

                HStack {
                    Text("Kind")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .leading)
                    Picker("", selection: $channel.kind) {
                        ForEach(NewsChannel.Kind.allCases) { k in
                            Text(k.displayName).tag(k)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 200)
                }

                Toggle("Enabled", isOn: $channel.enabled)
                    .font(.system(size: 12))
                    .toggleStyle(.switch)
                    .onChange(of: channel.enabled) { _, _ in isDirty = true }

                Toggle("Default channel", isOn: $channel.isDefault)
                    .font(.system(size: 12))
                    .toggleStyle(.switch)
                    .onChange(of: channel.isDefault) { _, _ in isDirty = true }

                kindHint

                HStack(spacing: 10) {
                    Button("Save") { onSave(channel); isDirty = false }
                        .buttonStyle(.borderedProminent)
                        .tint(.cyan)
                        .disabled(!isDirty)

                    Button("Make Active") { onMakeActive() }
                        .buttonStyle(.bordered)
                        .disabled(isActive || !channel.enabled)

                    Spacer()

                    Button("Delete", role: .destructive) { showDeleteConfirm = true }
                        .buttonStyle(.bordered)
                        .foregroundStyle(.red)
                }

                Spacer()
            }
            .padding(16)
        }
        .onChange(of: channel.name) { _, _ in isDirty = true }
        .onChange(of: channel.url) { _, _ in isDirty = true }
        .onChange(of: channel.kind) { _, _ in isDirty = true }
        .confirmationDialog(
            "Delete channel?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove \"\(channel.name)\" from the live channel list.")
        }
    }

    @ViewBuilder
    private var kindHint: some View {
        let hint: String = {
            switch channel.kind {
            case .youtubeEmbed:
                return "Paste a YouTube watch / live / shorts / embed URL. The app rewrites it to youtube-nocookie.com automatically.\n\nFor a live channel, use:\nhttps://www.youtube.com/embed/live_stream?channel=CHANNEL_ID"
            case .iframeEmbed:
                return "Paste a full <iframe …> HTML snippet. The src attribute is extracted and loaded."
            case .hls:
                return "Direct .m3u8 URL. Loaded into a native <video> tag."
            case .webPage:
                return "A normal web page URL (e.g. bbc.co.uk/news/live). YouTube URLs in this field are auto-routed through the embed flow."
            case .custom:
                return "Loaded as-is. Use for anything that doesn't fit the other kinds."
            }
        }()
        Text(hint)
            .font(.caption)
            .foregroundStyle(.secondary.opacity(0.8))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.gray.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
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

// MARK: - Add channel sheet

private struct AddChannelSheet: View {
    let onAdd: (NewsChannel) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var url: String = ""
    @State private var kind: NewsChannel.Kind = .youtubeEmbed

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Channel")
                .font(.headline)

            Group {
                LabeledContent("Name") {
                    TextField("CNN Live", text: $name).textFieldStyle(.roundedBorder)
                }
                LabeledContent("URL") {
                    TextField("https://www.youtube.com/embed/live_stream?channel=…",
                              text: $url)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                }
                LabeledContent("Kind") {
                    Picker("", selection: $kind) {
                        ForEach(NewsChannel.Kind.allCases) { k in
                            Text(k.displayName).tag(k)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            .font(.system(size: 12))

            Text("Tip: YouTube live channel URLs look like\nyoutube.com/embed/live_stream?channel=CHANNEL_ID")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(.bordered)
                Spacer()
                Button("Add") {
                    let trimmedName = name.trimmingCharacters(in: .whitespaces)
                    let trimmedURL  = url.trimmingCharacters(in: .whitespaces)
                    guard !trimmedName.isEmpty, !trimmedURL.isEmpty else { return }
                    let id = "user_" + trimmedName
                        .lowercased()
                        .replacingOccurrences(of: " ", with: "_")
                        + "_" + String(Int(Date().timeIntervalSince1970))
                    let ch = NewsChannel(
                        id: id,
                        name: trimmedName,
                        url: trimmedURL,
                        kind: kind,
                        isDefault: false,
                        enabled: true
                    )
                    onAdd(ch)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                          || url.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
