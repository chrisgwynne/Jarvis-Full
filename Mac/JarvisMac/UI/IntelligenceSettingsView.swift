import SwiftUI

struct IntelligenceSettingsView: View {
    let controller: JarvisController

    @State private var isReindexing = false
    @State private var reindexStatusMessage: String? = nil

    private var prefs: Preferences { controller.prefs.current }
    private var graph: ProjectKnowledgeGraph { .shared }
    private var indexer: CodebaseIndexer { .shared }

    var body: some View {
        Form {
            selfKnowledgeSection
            codebaseIndexSection
            silentActionsSection
            proactiveDeliverySection
            knowledgeGraphSection
        }
        .formStyle(.grouped)
    }

    // MARK: - Self-knowledge

    private var selfKnowledgeSection: some View {
        Section {
            Toggle("Enable self-knowledge", isOn: Binding(
                get: { prefs.selfKnowledgeEnabled },
                set: { v in controller.prefs.update { $0.selfKnowledgeEnabled = v } }
            ))
            Text("Jarvis uses the codebase index and feature graph to answer questions about itself — what it can do, how it works, and what's implemented — without hallucinating.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Codebase Intelligence")
        }
    }

    // MARK: - Codebase index

    private var codebaseIndexSection: some View {
        Section {
            Toggle("Index codebase", isOn: Binding(
                get: { prefs.codebaseIndexEnabled },
                set: { v in controller.prefs.update { $0.codebaseIndexEnabled = v } }
            ))

            // Project folder row — always visible so users can set the root
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Project folder")
                        .font(.subheadline)
                    if let path = prefs.projectDocsPath {
                        Text(path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else if let auto = ProjectKnowledgeGraph.findProjectRoot()?.path {
                        Text(auto + " (auto-detected)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("Not set — click Browse to choose your repo folder")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                Button("Browse…") { pickProjectFolder() }
                    .buttonStyle(.borderless)
                if prefs.projectDocsPath != nil {
                    Button("Clear") {
                        controller.prefs.update { $0.projectDocsPath = nil }
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
            }

            if prefs.codebaseIndexEnabled {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Indexed files")
                            .font(.subheadline)
                        Text("\(indexer.indexedFileCount) files · \(indexer.chunks.count) chunks")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Last indexed")
                            .font(.subheadline)
                        if let date = indexer.lastIndexedAt {
                            Text(date, style: .relative)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Never")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Button {
                    triggerReindex()
                } label: {
                    HStack(spacing: 6) {
                        if isReindexing {
                            ProgressView().controlSize(.small)
                        }
                        Text(isReindexing ? "Indexing…" : "Re-index Now")
                    }
                }
                .disabled(isReindexing)

                if let msg = reindexStatusMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(msg.hasPrefix("Error") || msg.hasPrefix("Set") ? .orange : .secondary)
                }
            }
        } header: {
            Text("Codebase Index")
        }
    }

    // MARK: - Silent actions

    private var silentActionsSection: some View {
        Section {
            Toggle("Silent action execution", isOn: Binding(
                get: { prefs.silentActionsEnabled },
                set: { v in controller.prefs.update { $0.silentActionsEnabled = v } }
            ))
            Text("When Jarvis detects a command inside a conversational message, it executes the command without announcing it. The conversation continues naturally as the side-effect.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Silent Actions")
        }
    }

    // MARK: - Proactive delivery settings

    private var proactiveDeliverySection: some View {
        let orch = controller.orchestrator
        return Section {
            // Delivery cycle
            HStack {
                Text("Delivery cycle")
                Spacer()
                Stepper(
                    "\(Int(orch.deliveryCycleSeconds))s",
                    value: Binding(
                        get: { orch.deliveryCycleSeconds },
                        set: { orch.deliveryCycleSeconds = $0; orch.start() }
                    ),
                    in: 10...120, step: 5
                )
            }

            // Escalation threshold
            HStack {
                Text("Escalation after")
                Spacer()
                Stepper(
                    "\(Int(orch.escalationThresholdSeconds / 60))min",
                    value: Binding(
                        get: { orch.escalationThresholdSeconds / 60 },
                        set: { orch.escalationThresholdSeconds = $0 * 60 }
                    ),
                    in: 1...30, step: 1
                )
            }

            // Bundle window
            HStack {
                Text("Bundle window")
                Spacer()
                Stepper(
                    "\(orch.bundleWindow) events",
                    value: Binding(
                        get: { orch.bundleWindow },
                        set: { orch.bundleWindow = $0 }
                    ),
                    in: 1...6, step: 1
                )
            }

            // Minimum interruption gap
            HStack {
                Text("Min gap between alerts")
                Spacer()
                Stepper(
                    "\(Int(orch.attentionPolicy.minInterruptionGapSeconds))s",
                    value: Binding(
                        get: { orch.attentionPolicy.minInterruptionGapSeconds },
                        set: { orch.attentionPolicy.minInterruptionGapSeconds = $0 }
                    ),
                    in: 5...120, step: 5
                )
            }

            // Max interruptions per 10 min
            HStack {
                Text("Max alerts per 10 min")
                Spacer()
                Stepper(
                    "\(orch.attentionPolicy.maxInterruptionsPerTenMinutes)",
                    value: Binding(
                        get: { orch.attentionPolicy.maxInterruptionsPerTenMinutes },
                        set: { orch.attentionPolicy.maxInterruptionsPerTenMinutes = $0 }
                    ),
                    in: 1...20, step: 1
                )
            }

            Text("Delivery cycle: how often the orchestrator checks the event queue. Escalation: how long a deferred event waits before being forced through. Bundle window: maximum events merged into one announcement.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Proactive Delivery")
        }
    }

    // MARK: - Knowledge graph browser

    private var knowledgeGraphSection: some View {
        Section {
            HStack {
                Text("Known features")
                Spacer()
                Text("\(graph.features.count)")
                    .foregroundStyle(.secondary)
            }

            if !graph.features.isEmpty {
                DisclosureGroup("Feature status overview") {
                    ForEach(ImplementationStatus.allCases, id: \.rawValue) { status in
                        let count = graph.features.filter { $0.status == status }.count
                        if count > 0 {
                            HStack {
                                Circle()
                                    .fill(statusColor(status))
                                    .frame(width: 8, height: 8)
                                Text(status.humanLabel.capitalized)
                                    .font(.caption)
                                Spacer()
                                Text("\(count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Button("Reset to seed defaults") {
                let root = resolvedProjectRoot()
                graph.resetToSeed(projectRoot: root)
            }
            .foregroundStyle(.secondary)
            .font(.caption)
        } header: {
            Text("Feature Graph")
        }
    }

    // MARK: - Helpers

    /// Returns the best available project root URL: explicit pref → auto-detected.
    private func resolvedProjectRoot() -> URL {
        if let explicit = prefs.projectDocsPath {
            return URL(fileURLWithPath: explicit)
        }
        return ProjectKnowledgeGraph.findProjectRoot() ?? URL(fileURLWithPath: "/")
    }

    private func triggerReindex() {
        let root = resolvedProjectRoot()
        guard root.path != "/" else {
            reindexStatusMessage = "Set a project folder above before indexing."
            return
        }
        isReindexing = true
        reindexStatusMessage = nil
        indexer.onIndexingComplete = { chunks in
            isReindexing = false
            let fileCount = Set(chunks.map { $0.filePath }).count
            reindexStatusMessage = fileCount > 0
                ? "Indexed \(chunks.count) chunks from \(fileCount) files."
                : "No files found — check that the project folder is correct."
        }
        indexer.reindex(projectRoot: root)
    }

    private func pickProjectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Project"
        panel.message = "Choose the root folder of your JarvisMac Xcode project"
        if panel.runModal() == .OK, let url = panel.url {
            controller.prefs.update { $0.projectDocsPath = url.path }
        }
    }

    private func statusColor(_ status: ImplementationStatus) -> Color {
        switch status {
        case .implemented: return .green
        case .partial:     return .yellow
        case .stubbed:     return .orange
        case .broken:      return .red
        case .planned:     return .blue
        case .unknown:     return .gray
        }
    }
}
