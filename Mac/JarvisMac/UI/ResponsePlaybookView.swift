import SwiftUI
import UniformTypeIdentifiers

// MARK: - ResponsePlaybookView

/// Settings panel for editing Jarvis response phrases.
/// Lists all response keys; selecting one opens an edit panel on the right.
struct ResponsePlaybookView: View {
    let controller: JarvisController

    @State private var searchText = ""
    @State private var selectedKey: String? = nil
    @State private var showingImport = false
    @State private var showingExport = false
    @State private var exportData: Data? = nil
    @State private var showingError = false
    @State private var errorMessage = ""

    private var store: ResponseTemplateStore { controller.playbook }

    private var filteredKeys: [String] {
        guard !searchText.isEmpty else { return store.allKeys }
        return store.allKeys.filter { key in
            key.localizedCaseInsensitiveContains(searchText) ||
            store.phrases(for: key).joined(separator: " ")
                .localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        HSplitView {
            sidebar
            detail
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            stylePicker
            Divider()
            searchBar
            Divider()
            keyList
            Divider()
            sidebarFooter
        }
        .frame(minWidth: 210, idealWidth: 230, maxWidth: 250)
        .fileImporter(
            isPresented: $showingImport,
            allowedContentTypes: [.json]
        ) { result in
            switch result {
            case .success(let url):
                do {
                    let data = try Data(contentsOf: url)
                    try store.importData(data)
                } catch {
                    errorMessage = error.localizedDescription
                    showingError = true
                }
            case .failure(let error):
                errorMessage = error.localizedDescription
                showingError = true
            }
        }
        .fileExporter(
            isPresented: $showingExport,
            document: PlaybookDocument(data: exportData ?? Data()),
            contentType: .json,
            defaultFilename: "response_playbook"
        ) { _ in }
        .alert("Import Error", isPresented: $showingError) {
            Button("OK") {}
        } message: {
            Text(errorMessage)
        }
    }

    private var stylePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Response Style")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)

            Picker("", selection: styleBinding) {
                ForEach(ResponseStyle.allCases) { s in
                    Text(s.displayName).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            Text(store.style.description)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("Filter…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.callout)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var keyList: some View {
        List(filteredKeys, id: \.self, selection: $selectedKey) { key in
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(key)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(store.phrases(for: key).first ?? "")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if store.isCustomised(key) {
                    Circle()
                        .fill(Color.cyan)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.vertical, 1)
        }
        .listStyle(.sidebar)
    }

    private var sidebarFooter: some View {
        HStack(spacing: 8) {
            Button("Import…") { showingImport = true }
                .buttonStyle(.bordered).controlSize(.small)
            Button("Export…") {
                exportData = store.exportData()
                showingExport = true
            }
            .buttonStyle(.bordered).controlSize(.small)
            Spacer()
            Button("Reset All") { store.resetAll() }
                .buttonStyle(.bordered).controlSize(.small)
                .foregroundStyle(.red)
        }
        .padding(8)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let key = selectedKey {
            EditPhraseView(key: key, controller: controller)
        } else {
            emptyDetail
        }
    }

    private var emptyDetail: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.bubble")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Select a response key to edit")
                .foregroundStyle(.secondary)
            Text("\(store.allKeys.count) keys · \(store.allKeys.filter { store.isCustomised($0) }.count) customised")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Bindings

    private var styleBinding: Binding<ResponseStyle> {
        Binding(
            get: { store.style },
            set: { store.setStyle($0) }
        )
    }
}

// MARK: - EditPhraseView

struct EditPhraseView: View {
    let key: String
    let controller: JarvisController

    @State private var phrases: [String] = []
    @State private var newPhrase = ""
    @FocusState private var newPhraseFocused: Bool

    private var store: ResponseTemplateStore { controller.playbook }
    private var renderer: ResponseRenderer { ResponseRenderer(store: store) }

    private var previewText: String {
        renderer.render(key, ResponsePlaybook.sampleVars)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            keyHeader
            Divider()
            phraseList
            Divider()
            previewPanel
        }
        .onAppear { phrases = store.phrases(for: key) }
        .onChange(of: key) { _, newKey in phrases = store.phrases(for: newKey) }
        // Auto-save whenever any phrase TextField loses focus (click-away).
        // `onSubmit` only fires on Return; this catches every other edit path.
        .onChange(of: phrases) { _, _ in commitPhrases() }
    }

    // MARK: Subviews

    private var header: some View {
        HStack {
            Text("Edit Phrases")
                .font(.headline)
            Spacer()
            if store.isCustomised(key) {
                Button("Reset to Default") {
                    store.reset(key: key)
                    phrases = store.phrases(for: key)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .foregroundStyle(.orange)
            }
        }
        .padding(12)
    }

    private var keyHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(key)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.top, 10)

            Text("Placeholders: {app} {query} {count} {count_label} {snippet} {entity} {name} {state} {context} {text} {device} {error} {time}")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)

            Text("★ First phrase = default. Consistent style always uses this.")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
        }
    }

    private var phraseList: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(phrases.indices, id: \.self) { idx in
                    HStack(spacing: 8) {
                        Group {
                            if idx == 0 {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.yellow)
                            } else {
                                Text("\(idx + 1)")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .frame(width: 16)

                        TextField("Phrase…", text: $phrases[idx])
                            .textFieldStyle(.roundedBorder)
                            .font(.callout)
                            .onSubmit { commitPhrases() }

                        Button {
                            phrases.remove(at: idx)
                            commitPhrases()
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Add new phrase row
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.green.opacity(0.8))
                        .frame(width: 16)

                    TextField("Add phrase…", text: $newPhrase)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout)
                        .focused($newPhraseFocused)
                        .onSubmit { addPhrase() }

                    Button { addPhrase() } label: {
                        Image(systemName: "return.left")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(newPhrase.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(12)
        }
    }

    private var previewPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PREVIEW  (sample variables)")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(previewText.isEmpty ? "(empty)" : previewText)
                .font(.callout)
                .foregroundStyle(.primary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.08))
                )

            HStack {
                Spacer()
                Button("Test Speak") {
                    guard !previewText.isEmpty else { return }
                    controller.speak(previewText)
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .disabled(previewText.isEmpty)
            }
        }
        .padding(12)
    }

    // MARK: Helpers

    private func commitPhrases() {
        store.update(key: key, phrases: phrases)
        // Note: do NOT reload `phrases` here — that would re-trigger
        // .onChange(of: phrases) → infinite commit loop.
        // Reloads happen only via .onAppear and .onChange(of: key).
    }

    private func addPhrase() {
        let trimmed = newPhrase.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        phrases.append(trimmed)
        newPhrase = ""
        commitPhrases()
    }
}

// MARK: - FileDocument for export

struct PlaybookDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
