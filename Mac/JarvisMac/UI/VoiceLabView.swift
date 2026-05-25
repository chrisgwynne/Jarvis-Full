import SwiftUI

// MARK: - VoiceLabView

/// Voice Lab — select, test, and benchmark TTS backends side-by-side.
/// Triggered by voice command "voice lab" or via Settings → Voice.
struct VoiceLabView: View {

    let router: TTSBackendRouter
    let onSetActive: (String) -> Void

    @State private var selectedId: String = "piper_onnx"
    @State private var testPhrase: String = "The quick brown fox jumps over the lazy dog."
    @State private var records: [TTSBenchmarkRecord] = []
    @State private var isTesting = false

    private let refreshTimer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Color.purple.opacity(0.4))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    backendPickerSection
                    testSection
                    Divider().overlay(Color.white.opacity(0.1))
                    benchmarkSection
                    Divider().overlay(Color.white.opacity(0.1))
                    averagesSection
                }
                .padding(14)
            }
        }
        .background(Color.black.opacity(0.92))
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.white.opacity(0.9))
        .onReceive(refreshTimer) { _ in reload() }
        .onAppear {
            selectedId = router.preferredBackendId
            reload()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Image(systemName: "waveform.badge.mic")
                .foregroundStyle(.purple)
            Text("VOICE LAB")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.purple)
            Spacer()
            Text("\(records.count) samples")
                .foregroundStyle(.white.opacity(0.4))
                .font(.system(size: 10, design: .monospaced))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: Backend picker

    private var backendPickerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("BACKENDS")
            ForEach(router.allBackends, id: \.id) { backend in
                backendRow(backend)
            }
        }
    }

    private func backendRow(_ backend: any TTSBackend) -> some View {
        let isSelected  = backend.id == selectedId
        let isActive    = backend.id == router.resolvedBackend.id
        let isAvailable = backend.isAvailable
        return HStack(spacing: 8) {
            Circle()
                .fill(isAvailable ? Color.green : Color.red)
                .frame(width: 6, height: 6)
            Text(backend.displayName)
                .font(.system(size: 11, weight: isSelected ? .bold : .regular, design: .monospaced))
                .foregroundStyle(isSelected ? .purple : .white.opacity(0.8))
            if isActive {
                Text("active")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.green.opacity(0.8))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.green.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            Spacer()
            if isSelected && isAvailable && selectedId != router.preferredBackendId {
                Button("Set Active") {
                    onSetActive(selectedId)
                }
                .buttonStyle(LabButtonStyle(color: .purple))
            }
        }
        .padding(6)
        .background(isSelected ? Color.purple.opacity(0.12) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { selectedId = backend.id }
    }

    // MARK: Test phrase

    private var testSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("TEST PHRASE")
            HStack(spacing: 8) {
                TextField("Test phrase…", text: $testPhrase)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .frame(maxWidth: .infinity)
                Button {
                    runTest()
                } label: {
                    HStack(spacing: 4) {
                        if isTesting {
                            ProgressView().scaleEffect(0.6).frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "play.fill").font(.system(size: 9))
                        }
                        Text(isTesting ? "Testing…" : "Run Test")
                    }
                }
                .buttonStyle(LabButtonStyle(color: isTesting ? .gray : .purple))
                .disabled(isTesting || testPhrase.isEmpty)
            }
            if let sel = router.allBackends.first(where: { $0.id == selectedId }) {
                let diag = sel.diagnostics
                if let reason = diag.unavailableReason {
                    Text("⚠ \(reason)")
                        .foregroundStyle(.orange.opacity(0.8))
                        .font(.system(size: 10))
                        .lineLimit(2)
                }
            }
        }
    }

    private func runTest() {
        guard let backend = router.allBackends.first(where: { $0.id == selectedId }),
              backend.isAvailable else { return }
        isTesting = true
        backend.speak(testPhrase)
        // Reset flag after 3s max (stream events handled by router benchmark logic)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            isTesting = false
            reload()
        }
    }

    // MARK: Recent results

    private var benchmarkSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("RECENT RESULTS")
            if records.isEmpty {
                Text("No results yet — run a test above.")
                    .foregroundStyle(.white.opacity(0.3))
                    .font(.system(size: 10))
            } else {
                resultHeader
                ForEach(records.prefix(12)) { record in
                    resultRow(record)
                }
                if records.count > 12 {
                    Button("Clear") { TTSBenchmarkStore.shared.clear(); reload() }
                        .buttonStyle(LabButtonStyle(color: .gray))
                }
            }
        }
    }

    private var resultHeader: some View {
        HStack(spacing: 0) {
            cell("Backend",    width: 140, align: .leading)
            cell("1st audio",  width: 70, align: .trailing)
            cell("Total",      width: 70, align: .trailing)
            cell("Status",     width: 50, align: .center)
        }
        .foregroundStyle(.white.opacity(0.4))
        .font(.system(size: 9))
    }

    private func resultRow(_ r: TTSBenchmarkRecord) -> some View {
        HStack(spacing: 0) {
            cell(shortName(r.backendName), width: 140, align: .leading)
            cell(msLabel(r.firstAudioMs),  width: 70,  align: .trailing)
            cell(msLabel(r.totalPlaybackMs), width: 70, align: .trailing)
            cell(r.succeeded ? "✓" : "✗",  width: 50,  align: .center)
                .foregroundStyle(r.succeeded ? .green : .red)
        }
        .font(.system(size: 10))
    }

    // MARK: Averages

    private var averagesSection: some View {
        let store = TTSBenchmarkStore.shared
        return VStack(alignment: .leading, spacing: 6) {
            sectionLabel("AVERAGES (p50 first-audio)")
            HStack(spacing: 16) {
                ForEach(router.allBackends, id: \.id) { backend in
                    let p50 = store.p50(for: backend.id)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(shortName(backend.displayName))
                            .foregroundStyle(.white.opacity(0.5))
                            .font(.system(size: 9))
                        if let ms = p50 {
                            Text(msLabel(ms))
                                .foregroundStyle(latencyColor(ms))
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                        } else {
                            Text("—")
                                .foregroundStyle(.white.opacity(0.25))
                                .font(.system(size: 13, design: .monospaced))
                        }
                    }
                }
            }
        }
    }

    // MARK: Helpers

    private func reload() {
        records = TTSBenchmarkStore.shared.all()
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.35))
    }

    private func cell(_ text: String, width: CGFloat, align: Alignment) -> some View {
        Text(text)
            .frame(width: width, alignment: align)
            .lineLimit(1)
    }

    private func msLabel(_ ms: Int) -> String { "\(ms)ms" }

    private func shortName(_ name: String) -> String {
        // "Jarvis ONNX (Piper)" → "Jarvis ONNX"
        name.components(separatedBy: " (").first ?? name
    }

    private func latencyColor(_ ms: Int) -> Color {
        switch ms {
        case ..<200:  return .green
        case ..<500:  return .yellow
        default:      return .orange
        }
    }
}

// MARK: - LabButtonStyle

private struct LabButtonStyle: ButtonStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(configuration.isPressed ? 0.5 : 0.25))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(color)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
    }
}
