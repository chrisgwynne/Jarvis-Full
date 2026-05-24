import SwiftUI
import UniformTypeIdentifiers

// MARK: - Top-level view

struct CommandPhrasesView: View {

    @Environment(\.colorScheme) private var colorScheme
    let store: CommandPhraseStore

    @State private var selectedCategory: CommandCategory? = .news
    @State private var selectedCommandId: String? = nil
    @State private var testInput: String = ""
    @State private var testResult: TestResult? = nil
    @State private var showResetAllAlert = false
    @State private var showImportPicker = false
    @State private var showExportPanel = false
    @State private var importErrorMessage: String? = nil

    private let matcher = CommandPhraseMatcher()

    // MARK: Body

    var body: some View {
        NavigationSplitView {
            categorySidebar
                .navigationSplitViewColumnWidth(min: 160, ideal: 175, max: 210)
        } content: {
            commandList
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
        } detail: {
            detailPane
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button("Export") { exportJSON() }
                    .help("Export all phrase definitions to JSON")
                Button("Import") { showImportPicker = true }
                    .help("Import phrase definitions from JSON")
                Spacer()
                Button(role: .destructive) { showResetAllAlert = true } label: {
                    Label("Reset All", systemImage: "arrow.counterclockwise")
                }
                .help("Restore all commands to factory defaults")
            }
        }
        .alert("Reset all commands to factory defaults?",
               isPresented: $showResetAllAlert) {
            Button("Reset All", role: .destructive) { store.resetAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently discard all custom phrases for every command. User-edited phrases cannot be recovered.")
        }
        .alert("Import failed", isPresented: Binding(
            get: { importErrorMessage != nil },
            set: { if !$0 { importErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importErrorMessage ?? "Unknown error")
        }
        .fileImporter(isPresented: $showImportPicker,
                      allowedContentTypes: [.json],
                      allowsMultipleSelection: false) { result in
            handleImport(result)
        }
    }

    // MARK: - Category sidebar

    private var categorySidebar: some View {
        List(CommandCategory.allCases, id: \.self, selection: $selectedCategory) { cat in
            Label {
                HStack {
                    Text(cat.displayName)
                        .font(.system(size: 12))
                    Spacer()
                    let count = store.definitions(in: cat).count
                    Text("\(count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            } icon: {
                Image(systemName: cat.systemImage)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .listStyle(.sidebar)
        .navigationTitle("Categories")
        .onChange(of: selectedCategory) { _, _ in
            selectedCommandId = nil
            testResult = nil
        }
    }

    // MARK: - Command list

    private var commandList: some View {
        let cmds = selectedCategory.map { store.definitions(in: $0) } ?? store.definitions
        let title = selectedCategory?.displayName ?? "All Commands"

        return List(cmds, id: \.id, selection: $selectedCommandId) { def in
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(def.displayName)
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    if !def.enabled {
                        Text("off")
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2))
                            .foregroundStyle(Color.orange)
                            .clipShape(Capsule())
                    }
                }
                let activeCount = def.phrases.filter(\.enabled).count
                Text("\(activeCount) phrase\(activeCount == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .tag(def.id as String?)
        }
        .listStyle(.sidebar)
        .navigationTitle(title)
        .onChange(of: selectedCommandId) { _, _ in testResult = nil }
    }

    // MARK: - Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if let cmdId = selectedCommandId,
           let def = store.definition(for: cmdId) {
            CommandDetailView(
                definition: def,
                store: store,
                testInput: $testInput,
                testResult: $testResult,
                matcher: matcher
            )
        } else {
            emptyDetail
        }
    }

    private var emptyDetail: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.word.spacing")
                .font(.system(size: 36))
                .foregroundStyle(.quaternary)
            Text("Select a command to edit its phrases")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Import / Export

    private func exportJSON() {
        guard let data = store.exportData(),
              let json = String(data: data, encoding: .utf8) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "jarvis-commands.json"
        if panel.runModal() == .OK, let url = panel.url {
            try? json.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let data = try Data(contentsOf: url)
                try store.importData(data)
            } catch {
                importErrorMessage = error.localizedDescription
            }
        case .failure(let error):
            importErrorMessage = error.localizedDescription
        }
    }
}

// MARK: - Command detail view

private struct CommandDetailView: View {

    let definition: CommandDefinition
    let store: CommandPhraseStore
    @Binding var testInput: String
    @Binding var testResult: TestResult?
    let matcher: CommandPhraseMatcher

    @State private var newPhraseText: String = ""
    @State private var newPhraseMatchType: PhraseMatchType = .exact
    @State private var editingPhrase: CommandPhrase? = nil
    @State private var showResetAlert = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerRow
                Divider()
                phrasesSection
                Divider()
                addPhraseRow
                Divider()
                testSection
            }
            .padding(20)
        }
    }

    // MARK: Header

    private var headerRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(definition.displayName)
                    .font(.system(size: 16, weight: .semibold))
                Text(definition.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Label(definition.category.displayName,
                          systemImage: definition.category.systemImage)
                    Text("·")
                    Label(definition.safetyLevel.displayName,
                          systemImage: safetyIcon)
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                Toggle("Enabled", isOn: Binding(
                    get: { definition.enabled },
                    set: { store.setEnabled($0, for: definition.id) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)

                Button("Reset to defaults") { showResetAlert = true }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
        .alert("Reset \"\(definition.displayName)\" to defaults?",
               isPresented: $showResetAlert) {
            Button("Reset", role: .destructive) {
                store.reset(commandId: definition.id)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var safetyIcon: String {
        switch definition.safetyLevel {
        case .low:    return "checkmark.shield"
        case .medium: return "exclamationmark.shield"
        case .high:   return "exclamationmark.shield.fill"
        }
    }

    // MARK: Phrases list

    private var phrasesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Trigger Phrases")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            if definition.phrases.isEmpty {
                Text("No phrases yet. Add one below.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 6)
            } else {
                ForEach(definition.phrases) { phrase in
                    PhraseRow(
                        phrase: phrase,
                        commandId: definition.id,
                        store: store,
                        editing: $editingPhrase
                    )
                }
            }
        }
    }

    // MARK: Add phrase

    private var addPhraseRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add Phrase")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("e.g. show me the news", text: $newPhraseText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { commitAdd() }

                Picker("", selection: $newPhraseMatchType) {
                    ForEach(PhraseMatchType.allCases) { mt in
                        Text(mt.displayName).tag(mt)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 110)
                .controlSize(.small)

                Button("Add") { commitAdd() }
                    .disabled(newPhraseText.trimmingCharacters(in: .whitespaces).isEmpty)
                    .controlSize(.small)
            }

            Text(newPhraseMatchType.helpText)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func commitAdd() {
        let trimmed = newPhraseText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        store.addPhrase(trimmed, to: definition.id, matchType: newPhraseMatchType)
        newPhraseText = ""
        newPhraseMatchType = .exact
    }

    // MARK: Test section

    private var testSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Test Matching")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("Type a phrase to test…", text: $testInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { runTest() }

                Button("Test") { runTest() }
                    .disabled(testInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    .controlSize(.small)
            }

            if let result = testResult {
                TestResultView(result: result)
            }
        }
    }

    private func runTest() {
        let normalized = TranscriptNormalizer.normalize(testInput)
        // Test against the entire store so we can show what WOULD match globally
        let allDefs = store.definitions
        if let match = matcher.match(normalizedInput: normalized,
                                     definitions: allDefs) {
            testResult = TestResult(
                matched: true,
                commandId: match.commandId,
                displayName: match.displayName,
                matchedPhrase: match.matchedPhrase,
                matchType: match.matchType,
                confidence: match.confidence,
                reason: match.reason,
                normalizedInput: normalized,
                nearMisses: []
            )
        } else {
            let misses = matcher.nearMisses(normalizedInput: normalized,
                                            definitions: allDefs)
            testResult = TestResult(
                matched: false,
                commandId: nil,
                displayName: nil,
                matchedPhrase: nil,
                matchType: nil,
                confidence: nil,
                reason: "No match",
                normalizedInput: normalized,
                nearMisses: misses
            )
        }
    }
}

// MARK: - Phrase row

private struct PhraseRow: View {

    let phrase: CommandPhrase
    let commandId: String
    let store: CommandPhraseStore
    @Binding var editing: CommandPhrase?

    @State private var isHovering = false
    @State private var editText: String = ""
    @State private var editMatchType: PhraseMatchType = .exact
    @State private var editPriority: Int = 0

    var body: some View {
        if editing?.id == phrase.id {
            inlineEditor
        } else {
            displayRow
        }
    }

    // MARK: Display

    private var displayRow: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { phrase.enabled },
                set: { newVal in
                    var updated = phrase
                    updated.enabled = newVal
                    store.updatePhrase(updated, in: commandId)
                }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .controlSize(.small)

            VStack(alignment: .leading, spacing: 1) {
                Text(phrase.phrase)
                    .font(.system(size: 12))
                    .strikethrough(!phrase.enabled, color: .secondary)
                    .foregroundStyle(phrase.enabled ? .primary : .secondary)

                HStack(spacing: 4) {
                    Text(phrase.matchType.displayName)
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(matchTypeColor.opacity(0.18))
                        .foregroundStyle(matchTypeColor)
                        .clipShape(Capsule())

                    if phrase.priority != 0 {
                        Text("p:\(phrase.priority)")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            if isHovering {
                HStack(spacing: 4) {
                    Button {
                        editText = phrase.phrase
                        editMatchType = phrase.matchType
                        editPriority = phrase.priority
                        editing = phrase
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))

                    Button {
                        store.removePhrase(id: phrase.id, from: commandId)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(Color.red.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? Color.secondary.opacity(0.06) : Color.clear)
        )
        .onHover { isHovering = $0 }
    }

    private var matchTypeColor: Color {
        switch phrase.matchType {
        case .exact:      return .blue
        case .contains:   return .purple
        case .startsWith: return .teal
        case .regex:      return .orange
        case .fuzzy:      return .indigo
        }
    }

    // MARK: Inline editor

    private var inlineEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Phrase", text: $editText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .onSubmit { commitEdit() }

            HStack(spacing: 8) {
                Picker("Match", selection: $editMatchType) {
                    ForEach(PhraseMatchType.allCases) { mt in
                        Text(mt.displayName).tag(mt)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 110)
                .controlSize(.small)

                Text("Priority:")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("0", value: $editPriority, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 40)
                    .font(.system(size: 11))

                Spacer()
                Button("Save") { commitEdit() }
                    .controlSize(.small)
                Button("Cancel") {
                    // Revert local edit state to the source phrase so the
                    // subsequent .onDisappear autosave is a no-op.
                    editText      = phrase.phrase
                    editMatchType = phrase.matchType
                    editPriority  = phrase.priority
                    editing = nil
                }
                .controlSize(.small)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 1)
                )
        )
        // Click-away autosave.  When the editor view leaves the tree (user
        // picks another row, switches command, closes the panel, etc.) any
        // outstanding edits are persisted.  Cancel reverts the local state
        // first so this no-ops on intentional cancel.  Mirrors the equivalent
        // fix in ResponsePlaybookView so the two phrase editors behave
        // consistently.  No risk of save loops — `.onDisappear` fires once
        // per view-instance teardown, not on value changes.
        .onDisappear { autoSaveIfDirty() }
    }

    /// True when the local edit fields differ from the source phrase and the
    /// text is non-empty.  Used to gate the autosave.
    private var hasUnsavedChanges: Bool {
        let trimmed = editText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return trimmed       != phrase.phrase
            || editMatchType != phrase.matchType
            || editPriority  != phrase.priority
    }

    /// Persists current edits to the store if anything changed.
    private func autoSaveIfDirty() {
        guard hasUnsavedChanges else { return }
        let trimmed = editText.trimmingCharacters(in: .whitespaces)
        var updated = phrase
        updated.phrase    = trimmed
        updated.matchType = editMatchType
        updated.priority  = editPriority
        updated.refreshNormalization()
        store.updatePhrase(updated, in: commandId)
    }

    private func commitEdit() {
        autoSaveIfDirty()
        editing = nil
    }
}

// MARK: - Test result view

private struct TestResultView: View {

    let result: TestResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: result.matched
                      ? "checkmark.circle.fill"
                      : "xmark.circle.fill")
                    .foregroundStyle(result.matched ? .green : .red)
                    .font(.system(size: 14))

                if result.matched {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.displayName ?? result.commandId ?? "Unknown")
                            .font(.system(size: 12, weight: .semibold))
                        Text(result.reason)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let conf = result.confidence {
                        Text("\(Int(conf * 100))%")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(confidenceColor(conf))
                    }
                } else {
                    Text("No match found")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            if let normalized = result.normalizedInput {
                HStack(spacing: 4) {
                    Text("Normalized:")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text("\"\(normalized)\"")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            if !result.nearMisses.isEmpty {
                Divider()
                Text("Near misses:")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(result.nearMisses.prefix(3).enumerated()),
                        id: \.offset) { _, miss in
                    HStack(spacing: 6) {
                        Text(miss.displayName)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text("—")
                            .foregroundStyle(.quaternary)
                        Text("\"\(miss.matchedPhrase)\"")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Text("\(Int(miss.confidence * 100))%")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.quaternary)
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(result.matched
                      ? Color.green.opacity(0.06)
                      : Color.red.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            result.matched
                                ? Color.green.opacity(0.2)
                                : Color.red.opacity(0.2),
                            lineWidth: 1)
                )
        )
    }

    private func confidenceColor(_ c: Double) -> Color {
        c >= 0.95 ? .green : c >= 0.80 ? .yellow : .orange
    }
}

// MARK: - Supporting types

struct TestResult {
    let matched: Bool
    let commandId: String?
    let displayName: String?
    let matchedPhrase: String?
    let matchType: PhraseMatchType?
    let confidence: Double?
    let reason: String
    let normalizedInput: String?
    let nearMisses: [MatchedCommand]
}
