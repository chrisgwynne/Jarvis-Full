import SwiftUI

/// Obsidian vault overlay — search, browse recent notes, view note content,
/// and create new notes by voice or keyboard.
struct ObsidianOverlayView: View {

    let vault: ObsidianVaultService
    let prefs: PreferencesStore

    @State private var query: String = ""
    @State private var selectedNote: ObsidianNote? = nil
    @State private var results: [ObsidianNote] = []
    @State private var isSearching = false
    @State private var showNewNoteSheet = false
    @State private var newNoteTitle = ""
    @State private var newNoteContent = ""
    @State private var statusMessage: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            // ── Top bar ──────────────────────────────────────────────────────
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search vault…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .rounded))
                    .onSubmit { runSearch() }
                    .onChange(of: query) { _, _ in scheduleSearch() }

                if !query.isEmpty {
                    Button { query = ""; results = [] } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                // Vault status badge
                Group {
                    if vault.isIndexed {
                        Label("\(vault.noteCount)", systemImage: "doc.text.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }

                Button {
                    showNewNoteSheet = true
                } label: {
                    Label("New Note", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial)

            Divider()

            // ── Status message ───────────────────────────────────────────────
            if let msg = statusMessage {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(msg).font(.caption)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color.green.opacity(0.1))
                Divider()
            }

            // ── Main split ───────────────────────────────────────────────────
            HSplitView {
                noteList
                    .frame(minWidth: 240, idealWidth: 280, maxWidth: 340)

                noteDetail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
        .onAppear {
            if vault.isIndexed {
                results = vault.recentNotes(limit: 20)
            }
        }
        .onChange(of: vault.isIndexed) { _, indexed in
            if indexed, query.isEmpty {
                results = vault.recentNotes(limit: 20)
            }
        }
        .sheet(isPresented: $showNewNoteSheet) {
            newNoteSheet
        }
    }

    // MARK: - Note list

    private var noteList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if results.isEmpty && !vault.isIndexed {
                    indexingPlaceholder
                } else if results.isEmpty {
                    emptyState
                } else {
                    ForEach(results) { note in
                        noteRow(note)
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private func noteRow(_ note: ObsidianNote) -> some View {
        Button {
            selectedNote = note
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(note.title)
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    Text(note.modifiedAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if !note.snippet.isEmpty {
                    Text(note.snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if !note.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(note.tags.prefix(4), id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.purple.opacity(0.15))
                                .foregroundStyle(.purple)
                                .clipShape(Capsule())
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                selectedNote?.id == note.id
                    ? Color.purple.opacity(0.12)
                    : Color.clear
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        Divider().padding(.leading, 12)
    }

    // MARK: - Note detail

    @ViewBuilder
    private var noteDetail: some View {
        if let note = selectedNote {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Header
                    VStack(alignment: .leading, spacing: 4) {
                        Text(note.title)
                            .font(.title2.bold())
                        HStack(spacing: 8) {
                            Label(note.modifiedAt.formatted(date: .abbreviated, time: .shortened),
                                  systemImage: "clock")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !note.tags.isEmpty {
                                ForEach(note.tags.prefix(6), id: \.self) { tag in
                                    Text("#\(tag)")
                                        .font(.caption)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.purple.opacity(0.15))
                                        .foregroundStyle(.purple)
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }
                    Divider()
                    // Body (plain text — Obsidian markdown)
                    Text(note.body)
                        .font(.system(.body, design: .serif))
                        .textSelection(.enabled)
                        .lineSpacing(4)
                    // Wikilinks section
                    if !note.wikilinks.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Linked notes")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            FlowLayout(spacing: 6) {
                                ForEach(note.wikilinks, id: \.self) { link in
                                    Button {
                                        if let linked = vault.findNote(matching: link) {
                                            selectedNote = linked
                                        }
                                    } label: {
                                        Text("[[  \(link)  ]]")
                                            .font(.caption)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(Color.purple.opacity(0.1))
                                            .foregroundStyle(.purple)
                                            .clipShape(RoundedRectangle(cornerRadius: 6))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "doc.richtext")
                    .font(.system(size: 40))
                    .foregroundStyle(.quaternary)
                Text("Select a note to read")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - New note sheet

    private var newNoteSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Note")
                .font(.title2.bold())

            TextField("Title", text: $newNoteTitle)
                .textFieldStyle(.roundedBorder)
                .font(.body)

            TextEditor(text: $newNoteContent)
                .font(.system(.body, design: .serif))
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

            HStack {
                Spacer()
                Button("Cancel") { showNewNoteSheet = false }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Create") {
                    createNote()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(newNoteTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 280)
    }

    // MARK: - Placeholder states

    private var indexingPlaceholder: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("Indexing vault…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: query.isEmpty ? "doc.text" : "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.quaternary)
            Text(query.isEmpty ? "No notes found" : "No results for \"\(query)\"")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    // MARK: - Actions

    private func scheduleSearch() {
        guard !query.isEmpty else {
            results = vault.recentNotes(limit: 20)
            return
        }
        // Immediate FTS for low latency; semantic runs async
        results = vault.search(query: query, limit: 15)
        Task {
            let semantic = await vault.hybridSearch(query: query, limit: 15)
            results = semantic
        }
    }

    private func runSearch() {
        Task {
            isSearching = true
            results = await vault.hybridSearch(query: query, limit: 15)
            isSearching = false
        }
    }

    private func createNote() {
        let title   = newNoteTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = newNoteContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        Task {
            do {
                try await vault.createNote(title: title, content: content)
                showNewNoteSheet = false
                newNoteTitle   = ""
                newNoteContent = ""
                // Refresh list and select the new note
                results = vault.recentNotes(limit: 20)
                selectedNote = vault.findNote(matching: title)
                statusMessage = "Created \"\(title)\""
                try? await Task.sleep(for: .seconds(3))
                statusMessage = nil
            } catch {
                statusMessage = "Error: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Simple flow layout for wikilinks

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 200
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowH: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                y += rowH + spacing
                x = 0; rowH = 0
            }
            rowH = max(rowH, size.height)
            x += size.width + spacing
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowH: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                y += rowH + spacing
                x = bounds.minX; rowH = 0
            }
            sv.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            rowH = max(rowH, size.height)
            x += size.width + spacing
        }
    }
}
