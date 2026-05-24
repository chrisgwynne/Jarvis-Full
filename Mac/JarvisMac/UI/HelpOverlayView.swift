import SwiftUI

/// Living-documentation help overlay.  Reads from
/// `LivingDocumentationEngine.shared` so sections reflect the *actual*
/// state of the app at the moment the overlay is opened — disabled
/// providers vanish, configured-but-offline integrations get a status
/// pill, troubleshooting items detected right now are highlighted.
///
/// **Layout:** HSplitView (Obsidian-overlay style).
/// * Left sidebar: search field + category list + section list per category.
/// * Right detail pane: section body, examples, troubleshooting, related settings.
///
/// **Interaction:** tap an example phrase to copy it to the clipboard
/// (matches the brief's "clickable examples" requirement); the right pane
/// updates on selection.  Search filters across title, body, examples,
/// tags, and troubleshooting symptoms.
struct HelpOverlayView: View {

    @State private var query: String = ""
    @State private var selectedSectionId: String? = nil
    @State private var copiedPhrase: String? = nil

    private var engine: LivingDocumentationEngine { .shared }

    /// All sections fresh on every render so toggling a setting and
    /// switching apps back is enough to see the docs update.
    private var allSections: [DocumentationSection] {
        engine.allSections()
    }

    private var filteredSections: [DocumentationSection] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return allSections }
        return DocumentationSearchIndex
            .search(query: q, sections: allSections, limit: 50)
            .map { $0.section }
    }

    /// Section selected for the detail pane — explicit selection wins;
    /// otherwise default to the first visible section.
    private var detailSection: DocumentationSection? {
        if let id = selectedSectionId,
           let match = filteredSections.first(where: { $0.id == id }) {
            return match
        }
        return filteredSections.first
    }

    // MARK: - Body

    var body: some View {
        HSplitView {
            sidebar
            detail
        }
        .frame(minWidth: 720, minHeight: 540)
        .onAppear {
            if selectedSectionId == nil {
                selectedSectionId = allSections.first?.id
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            sidebarList
        }
        .frame(minWidth: 230, idealWidth: 260, maxWidth: 320)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("Search help…", text: $query)
                .textFieldStyle(.plain)
                .font(.callout)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var sidebarList: some View {
        // Group filtered sections by category, preserving category order.
        let grouped = Dictionary(grouping: filteredSections) { $0.category }
        let categoriesInUse = DocumentationCategory.allCases
            .filter { grouped[$0] != nil }

        return List(selection: $selectedSectionId) {
            ForEach(categoriesInUse, id: \.self) { cat in
                Section {
                    ForEach(grouped[cat] ?? []) { s in
                        HStack(spacing: 6) {
                            Text(s.title)
                                .lineLimit(1)
                                .font(.system(size: 12))
                            Spacer()
                            statusPill(s.status)
                        }
                        .tag(s.id)
                    }
                } header: {
                    HStack(spacing: 5) {
                        Image(systemName: cat.systemImage)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(cat.displayTitle.uppercased())
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func statusPill(_ status: DocumentationStatus) -> some View {
        Group {
            switch status {
            case .enabled:
                pill(text: "on", colour: .green)
            case .disabled:
                pill(text: "off", colour: .secondary)
            case .degraded:
                pill(text: "limited", colour: .orange)
            case .notConfigured:
                pill(text: "setup", colour: .yellow)
            case .informational:
                EmptyView()
            }
        }
    }

    private func pill(text: String, colour: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(colour.opacity(0.18))
            .foregroundStyle(colour)
            .clipShape(Capsule())
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let s = detailSection {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    detailHeader(s)
                    if let sub = s.subtitle, !sub.isEmpty {
                        Text(sub)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    bodyText(s)
                    examplesBlock(s)
                    troubleshootingBlock(s)
                    settingsBlock(s)
                    integrationsBlock(s)
                    limitationsBlock(s)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "questionmark.circle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Select a help topic.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detailHeader(_ s: DocumentationSection) -> some View {
        HStack(spacing: 8) {
            Image(systemName: s.category.systemImage)
                .foregroundStyle(.cyan)
            Text(s.title).font(.title3.bold())
            Spacer()
            statusPill(s.status)
        }
    }

    private func bodyText(_ s: DocumentationSection) -> some View {
        // Plain text rather than full markdown rendering — keeps the
        // overlay lightweight and avoids pulling in extra dependencies.
        // Newlines preserved.
        Text(s.bodyMarkdown)
            .font(.body)
            .textSelection(.enabled)
            .lineSpacing(2)
    }

    @ViewBuilder
    private func examplesBlock(_ s: DocumentationSection) -> some View {
        if !s.examples.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader("Examples")
                ForEach(s.examples) { ex in
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ex.phrase, forType: .string)
                        copiedPhrase = ex.phrase
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            if copiedPhrase == ex.phrase { copiedPhrase = nil }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: ex.kind == .commandPhrase
                                  ? "quote.opening" : "arrow.turn.up.right")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                            Text("\"\(ex.phrase)\"")
                                .font(.system(size: 12, design: .rounded))
                                .foregroundStyle(.primary)
                            if let f = ex.followUp, !f.isEmpty {
                                Text("— \(f)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if copiedPhrase == ex.phrase {
                                Text("copied").font(.system(size: 9))
                                    .foregroundStyle(.green)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.secondary.opacity(0.07))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func troubleshootingBlock(_ s: DocumentationSection) -> some View {
        if !s.troubleshooting.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader("Troubleshooting")
                ForEach(s.troubleshooting) { t in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: t.isActive
                              ? "exclamationmark.triangle.fill"
                              : "wrench.and.screwdriver")
                            .foregroundStyle(t.isActive ? .orange : .secondary)
                            .font(.caption)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.symptom).font(.system(size: 12, weight: .semibold))
                            if let c = t.cause, !c.isEmpty {
                                Text(c).font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Text(t.fix).font(.system(size: 11))
                                .foregroundStyle(.primary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill((t.isActive ? Color.orange : Color.secondary)
                                .opacity(0.08))
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func settingsBlock(_ s: DocumentationSection) -> some View {
        if !s.relatedSettings.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                sectionHeader("Related settings")
                ForEach(s.relatedSettings, id: \.self) { setting in
                    HStack(spacing: 6) {
                        Image(systemName: "gearshape").font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Text(setting).font(.system(size: 11))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func integrationsBlock(_ s: DocumentationSection) -> some View {
        if !s.requiredIntegrations.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                sectionHeader("Requires")
                ForEach(s.requiredIntegrations, id: \.self) { item in
                    HStack(spacing: 6) {
                        Image(systemName: "link").font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Text(item).font(.system(size: 11))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func limitationsBlock(_ s: DocumentationSection) -> some View {
        if !s.limitations.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                sectionHeader("Known limitations")
                ForEach(s.limitations, id: \.self) { item in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "info.circle").font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Text(item).font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func sectionHeader(_ s: String) -> some View {
        Text(s.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }
}
