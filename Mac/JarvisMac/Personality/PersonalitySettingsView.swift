import SwiftUI

// MARK: - PersonalitySettingsView

/// Settings panel for editing Jarvis personality markdown files.
/// Sidebar lists all files; selecting one opens a full markdown editor on the right.
struct PersonalitySettingsView: View {
    let controller: JarvisController

    @State private var selectedID: String? = PersonalityPack.files.first?.id
    @State private var showingResetConfirm = false

    private var store: PersonalityFileStore { controller.personality }

    var body: some View {
        HSplitView {
            sidebar
            if let id = selectedID,
               let file = PersonalityPack.files.first(where: { $0.id == id }) {
                FileEditorView(file: file, controller: controller)
            } else {
                emptyDetail
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(PersonalityPack.files, selection: $selectedID) { file in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(file.displayName)
                            .font(.callout.weight(.medium))
                        Spacer()
                        if store.loadErrors[file.id] != nil {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.caption2)
                        }
                    }
                    Text(file.description)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.vertical, 2)
            }
            .listStyle(.sidebar)

            Divider()
            sidebarFooter
        }
        .frame(minWidth: 180, idealWidth: 200, maxWidth: 220)
    }

    private var sidebarFooter: some View {
        VStack(spacing: 6) {
            Button {
                store.reload()
                controller.syncPersonality()
            } label: {
                Label("Reload All", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                store.openFolder()
            } label: {
                Label("Open in Finder", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                showingResetConfirm = true
            } label: {
                Label("Reset All", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .foregroundStyle(.red)
        }
        .padding(8)
        .confirmationDialog(
            "Reset all personality files to defaults?",
            isPresented: $showingResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset All", role: .destructive) {
                store.resetAll()
                controller.syncPersonality()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Detail

    private var emptyDetail: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.text.rectangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Select a file to edit")
                .foregroundStyle(.secondary)
            Text("\(PersonalityPack.files.count) personality files")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - FileEditorView

private struct FileEditorView: View {
    let file: PersonalityFile
    let controller: JarvisController

    @State private var editText = ""
    @State private var isDirty = false
    @State private var showingResetConfirm = false

    private var store: PersonalityFileStore { controller.personality }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            Divider()
            editor
            Divider()
            statusBar
        }
        .onAppear { load() }
        .onChange(of: file.id) { _, _ in load() }
    }

    // MARK: Subviews

    private var toolbar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.displayName)
                    .font(.headline)
                Text(file.filename)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()

            if isDirty {
                Button("Save") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .keyboardShortcut("s", modifiers: .command)
            }

            Button {
                showingResetConfirm = true
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
            .help("Reset to default")
        }
        .padding(12)
        .confirmationDialog(
            "Reset \(file.displayName) to default?",
            isPresented: $showingResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                store.reset(file: file)
                controller.syncPersonality()
                load()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var editor: some View {
        TextEditor(text: $editText)
            .font(.system(.callout, design: .monospaced))
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .padding(10)
            .onChange(of: editText) { _, _ in isDirty = true }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if let err = store.loadErrors[file.id] {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption2)
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(file.description)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text("\(editText.components(separatedBy: .newlines).count) lines")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: Helpers

    private func load() {
        editText = store.content(for: file)
        isDirty = false
    }

    private func save() {
        store.save(file: file, content: editText)
        controller.syncPersonality()
        isDirty = false
    }
}
