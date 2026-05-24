import SwiftUI

/// Shows commands Jarvis didn't understand so the user can teach it.
struct UnmatchedCommandsView: View {
    let controller: JarvisController
    @State private var showingTeachSheet = false
    @State private var selectedEntry: UnmatchedCommandEntry?

    private var store: UnmatchedCommandStore { controller.unmatched }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.entries.isEmpty {
                ContentUnavailableView(
                    "No Unmatched Commands",
                    systemImage: "checkmark.circle.fill",
                    description: Text("Jarvis understood all your recent commands.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.entries) { entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.rawText)
                                    .font(.subheadline)
                                if let resolved = entry.llmResolvedIntent {
                                    Text("AI resolved: \(resolved)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                HStack(spacing: 6) {
                                    if let action = entry.action {
                                        Text(action)
                                            .font(.caption2)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 2)
                                            .background(Color.orange.opacity(0.15))
                                            .cornerRadius(4)
                                    }
                                    Text(entry.timestamp, style: .relative)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if entry.frequency > 1 {
                                Text("\u{d7}\(entry.frequency)")
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.2))
                                    .foregroundStyle(.orange)
                                    .cornerRadius(8)
                            }
                            Button("Teach") {
                                selectedEntry = entry
                                showingTeachSheet = true
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .onDelete { indices in
                        store.remove(atOffsets: indices)
                    }
                }

                HStack {
                    Text("\(store.entries.count) unmatched command\(store.entries.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear All") {
                        store.clear()
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .font(.caption)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .sheet(isPresented: $showingTeachSheet) {
            if let entry = selectedEntry {
                TeachCommandSheet(entry: entry, isPresented: $showingTeachSheet, controller: controller)
            }
        }
    }
}

struct TeachCommandSheet: View {
    let entry: UnmatchedCommandEntry
    @Binding var isPresented: Bool
    let controller: JarvisController
    @State private var selectedCommandId: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Phrase Jarvis didn't understand") {
                    Text(entry.rawText)
                        .font(.headline)
                    if entry.normalizedText != entry.rawText {
                        Text("Normalized: \(entry.normalizedText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Map to command") {
                    Picker("Command", selection: $selectedCommandId) {
                        Text("Select a command").tag("")
                        ForEach(controller.phraseStore.definitions) { def in
                            Text(def.displayName).tag(def.id)
                        }
                    }
                }
            }
            .navigationTitle("Teach Jarvis")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if !selectedCommandId.isEmpty {
                            _ = controller.phraseStore.addPhrase(entry.rawText, to: selectedCommandId)
                        }
                        isPresented = false
                    }
                    .disabled(selectedCommandId.isEmpty)
                }
            }
        }
        .frame(minWidth: 360, minHeight: 320)
    }
}
