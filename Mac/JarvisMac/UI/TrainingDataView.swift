import SwiftUI

struct TrainingDataView: View {
    let engine: LocalLearningEngine

    @State private var selectedTab: TrainingTab = .examples
    @State private var searchText: String = ""
    @State private var validationIssues: [String] = []
    @State private var showValidation = false
    @State private var exportStatus: String? = nil
    @State private var editingNotes: UUID? = nil
    @State private var notesText: String = ""

    enum TrainingTab: String, CaseIterable {
        case examples = "Examples"
        case aliases  = "Aliases"
        case failed   = "Failed"
        case diagnostics = "Diagnostics"
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Tab", selection: $selectedTab) {
                ForEach(TrainingTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding()

            switch selectedTab {
            case .examples:    examplesTab
            case .aliases:     aliasesTab
            case .failed:      failedTab
            case .diagnostics: diagnosticsTab
            }
        }
    }

    // MARK: - Examples Tab

    private var examplesTab: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                Spacer()
                Button("Validate") {
                    validationIssues = engine.trainingExampleStore.validate()
                    showValidation = true
                }
                Button("Export") { Task { await exportAll() } }
                    .buttonStyle(.borderedProminent)
                Button("Clear Rejected") {
                    engine.trainingExampleStore.clearFailed()
                }
                .foregroundStyle(.red)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)

            if let status = exportStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.bottom, 4)
            }

            Divider()

            List(filteredExamples) { example in
                ExampleRow(
                    example: example,
                    onApprove: { engine.trainingExampleStore.approve(id: example.id) },
                    onReject:  { engine.trainingExampleStore.reject(id: example.id) },
                    onDelete:  { engine.trainingExampleStore.remove(id: example.id) },
                    onEditNotes: {
                        editingNotes = example.id
                        notesText = example.notes ?? ""
                    }
                )
            }
        }
        .sheet(isPresented: $showValidation) {
            ValidationSheet(issues: validationIssues)
        }
        .sheet(item: $editingNotes) { id in
            NotesSheet(text: $notesText) {
                engine.trainingExampleStore.update(id: id, notes: notesText)
                editingNotes = nil
            }
        }
    }

    private var filteredExamples: [TrainingExample] {
        let all = engine.trainingExampleStore.examples
        if searchText.isEmpty { return all }
        let q = searchText.lowercased()
        return all.filter {
            $0.transcript.lowercased().contains(q) ||
            $0.intent.lowercased().contains(q)
        }
    }

    // MARK: - Aliases Tab

    private var aliasesTab: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(engine.aliasStore.aliases.count) learned aliases")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
            Divider()
            List(engine.aliasStore.aliases) { alias in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\"\(alias.phrase)\"").font(.body)
                        Text("→ \(alias.intent)\(alias.target.map { " · \($0)" } ?? "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("×\(alias.usageCount)").font(.caption2).foregroundStyle(.tertiary)
                    approvalBadge(alias.approvalState)
                    Button("Approve") { engine.aliasStore.approve(id: alias.id) }
                        .buttonStyle(.bordered).controlSize(.mini)
                    Button("Reject")  { engine.aliasStore.reject(id: alias.id) }
                        .buttonStyle(.bordered).controlSize(.mini)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: - Failed Tab

    private var failedTab: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(engine.failedStore.top(limit: 200).count) unresolved failures")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear All") { engine.failedStore.clear() }
                    .foregroundStyle(.red)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
            Divider()
            List(engine.failedStore.top(limit: 200)) { failure in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(failure.transcript).font(.body)
                        if let intent = failure.detectedIntent {
                            Text("Detected: \(intent)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text("×\(failure.attemptCount)")
                        .font(.caption2).foregroundStyle(.orange)
                    Button("Resolved") { engine.failedStore.markResolved(id: failure.id) }
                        .buttonStyle(.bordered).controlSize(.mini)
                }
            }
        }
    }

    // MARK: - Diagnostics Tab

    private var diagnosticsTab: some View {
        let d = engine.diagnostics
        return Form {
            Section("Endpoint") {
                LabeledContent("Reachable") {
                    Image(systemName: d.endpointReachable ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(d.endpointReachable ? .green : .red)
                }
                LabeledContent("Last latency", value: d.lastLatencyMs > 0 ? "\(Int(d.lastLatencyMs)) ms" : "—")
            }
            Section("Routing") {
                LabeledContent("Local LLM calls",   value: "\(d.totalLocalLLMCalls)")
                LabeledContent("Alias hits",         value: "\(d.totalAliasHits)")
                LabeledContent("Route cache hits",   value: "\(d.totalRouteHits)")
                LabeledContent("Correction hits",    value: "\(d.totalCorrectionHits)")
            }
            Section("Stores") {
                LabeledContent("Learned aliases",     value: "\(d.aliasCount)")
                LabeledContent("User corrections",    value: "\(d.correctionCount)")
                LabeledContent("Failed utterances",   value: "\(d.failedUtteranceCount)")
                LabeledContent("Training examples",   value: "\(d.trainingExampleCount)")
                LabeledContent("Total interactions",  value: "\(engine.interactionRecorder.records.count)")
                LabeledContent("Success rate",        value: String(format: "%.1f%%", engine.interactionRecorder.successRate * 100))
            }
            Section("LoRA") {
                Button("Export for LoRA Training") { engine.exportForLoRATraining() }
                Button("Import LoRA Adapter Path…") { /* file picker stub */ }
            }
            Section {
                Button("Check Endpoint Health") {
                    Task { await engine.checkEndpointHealth() }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Helpers

    private func approvalBadge(_ state: ApprovalState) -> some View {
        let (label, color): (String, Color) = switch state {
        case .pending:  ("pending",  .orange)
        case .approved: ("approved", .green)
        case .rejected: ("rejected", .red)
        }
        return Text(label).font(.caption2).foregroundStyle(color)
    }

    private func exportAll() async {
        await engine.exportTrainingData()
        exportStatus = "Exported to ~/JarvisTrainingData/ at \(shortTime())"
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        exportStatus = nil
    }

    private func shortTime() -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        return f.string(from: Date())
    }
}

// MARK: - Supporting views

private struct ExampleRow: View {
    let example: TrainingExample
    let onApprove: () -> Void
    let onReject: () -> Void
    let onDelete: () -> Void
    let onEditNotes: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(example.transcript).font(.body)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(example.intent).font(.caption).foregroundStyle(.secondary)
                    if let t = example.target { Text("· \(t)").font(.caption).foregroundStyle(.tertiary) }
                    Text(example.routingSource.rawValue).font(.caption2).foregroundStyle(.tertiary)
                }
                if let notes = example.notes {
                    Text(notes).font(.caption).foregroundStyle(.blue).lineLimit(1)
                }
            }
            Spacer()
            stateIndicator(example.approvalState)
            Button("✓") { onApprove() }.buttonStyle(.bordered).controlSize(.mini)
            Button("✗") { onReject()  }.buttonStyle(.bordered).controlSize(.mini)
                .foregroundStyle(.red)
            Button("…") { onEditNotes() }.buttonStyle(.bordered).controlSize(.mini)
        }
    }

    private func stateIndicator(_ state: ApprovalState) -> some View {
        let color: Color = switch state {
        case .pending:  .orange
        case .approved: .green
        case .rejected: .red
        }
        return Circle().fill(color).frame(width: 8, height: 8)
    }
}

private struct ValidationSheet: View {
    let issues: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Validation Results").font(.headline)
            if issues.isEmpty {
                Label("All examples valid", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(issues, id: \.self) {
                            Text($0).font(.caption).foregroundStyle(.red)
                        }
                    }
                }
            }
            Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(minWidth: 400, minHeight: 200)
    }
}

private struct NotesSheet: View {
    @Binding var text: String
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text("Edit Notes").font(.headline)
            TextEditor(text: $text).frame(height: 100)
                .border(.separator)
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") { onSave() }.buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 360)
    }
}

// UUID acts as Identifiable for the notes sheet
extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}
