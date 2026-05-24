import SwiftUI
import AVFoundation

// MARK: - VoiceSettingsView

/// Settings panel for the "Voice" tab.
/// Clearly separates Speech Recognition (how Jarvis listens) from
/// Jarvis Voice (how Jarvis speaks).
struct VoiceSettingsView: View {

    let state: AppState
    let controller: JarvisController

    // TTS test state
    @State private var isTesting = false

    // Piper validation state
    @State private var piperValidating = false
    @State private var piperValidationResult: PiperTTS.ValidationResult? = nil

    // Piper path drafts — local edit buffers so TextFields don't revert mid-type.
    // These are the source-of-truth WHILE the user is editing; committed to prefs on Return.
    // Synced from prefs on .onAppear and whenever the TTS engine switches to .piper.
    @State private var piperExecDraft   = ""
    @State private var piperModelDraft  = ""
    @State private var piperConfigDraft = ""
    @FocusState private var piperExecFocused:   Bool
    @FocusState private var piperModelFocused:  Bool
    @FocusState private var piperConfigFocused: Bool

    // Pronunciation sheet state
    @State private var showAddPronunciation = false
    @State private var editingEntry: PronunciationEntry? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Form {
                    // ── Speech Recognition ───────────────────────────────────
                    Section {
                        Picker("Engine", selection: sttEngineBinding) {
                            ForEach(SpeechEngine.allCases) { e in
                                Text(e.displayName).tag(e)
                            }
                        }
                        .pickerStyle(.segmented)

                        Picker("Microphone", selection: micBinding) {
                            Text("System default").tag(String?.none)
                            ForEach(state.availableMicrophones) { d in
                                Text(d.name + (d.isWebcamMic ? " (webcam)" : ""))
                                    .tag(Optional(d.id))
                            }
                        }
                    } header: {
                        Label("Speech Recognition", systemImage: "mic.fill")
                    } footer: {
                        Text("Controls how Jarvis understands your voice. Apple Speech works out-of-the-box. Whisper requires a local model file (see below).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // ── Whisper (conditional) ────────────────────────────────
                    if controller.prefs.current.speechEngine == .whisper {
                        whisperSection
                    }

                    // ── Jarvis Voice ─────────────────────────────────────────
                    Section {
                        Picker("Voice Engine", selection: ttsEngineBinding) {
                            ForEach(TTSEngine.allCases) { e in
                                Text(e.displayName).tag(e)
                            }
                        }
                        .pickerStyle(.segmented)
                    } header: {
                        Label("Jarvis Voice", systemImage: "speaker.wave.2.fill")
                    } footer: {
                        Text("Controls how Jarvis speaks back. Completely separate from Speech Recognition.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // ── Apple Voice picker ────────────────────────────────────
                    if controller.prefs.current.ttsEngine == .appleSystem {
                        appleVoiceSection
                    }

                    // ── Piper section ─────────────────────────────────────────
                    if controller.prefs.current.ttsEngine == .piper {
                        piperSection
                    }

                    // ── Pronunciations ────────────────────────────────────────
                    pronunciationsSection

                    // ── Preprocessor Diagnostics ──────────────────────────────
                    preprocessorDiagnosticsSection

                    // ── TTS Diagnostics ───────────────────────────────────────
                    ttsDiagnosticsSection
                }
                .formStyle(.grouped)
            }
        }
    }

    // MARK: - STT sections

    private var whisperSection: some View {
        Section {
            TextField("Model file path (.bin / .gguf)",
                      text: whisperPathBinding)
                .font(.system(size: 11, design: .monospaced))

            HStack(spacing: 8) {
                let path = controller.prefs.current.whisperModelPath ?? ""
                let exists = !path.isEmpty && FileManager.default.fileExists(atPath: path)
                Image(systemName: exists ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(exists ? .green : .orange)
                Text(path.isEmpty ? "No model configured"
                     : exists     ? "Model found"
                                  : "Model file not found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Download a GGML model from github.com/ggerganov/whisper.cpp/releases\n"
               + "Recommended: ggml-base.en.bin (~142 MB) for good quality.\n"
               + "The whisper.cpp Swift package must also be added to the project.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } header: {
            Text("Whisper Local Model")
        }
    }

    // MARK: - Apple Voice section

    @State private var availableVoices: [VoiceInfo] = []

    private var appleVoiceSection: some View {
        Group {
            Section {
                voicePicker
                rateRow
                pitchRow
                volumeRow
            } header: {
                Text("Apple Voice Configuration")
            }

            Section {
                Button(isTesting ? "Speaking…" : "Test Voice") {
                    isTesting = true
                    controller.tts.testVoice()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                        isTesting = false
                    }
                }
                .disabled(isTesting)

                LabeledContent("Current voice") {
                    Text(state.ttsVoiceName.isEmpty ? "Auto (best male English)" : state.ttsVoiceName)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                LabeledContent("Language") {
                    Text(state.ttsVoiceLanguage.isEmpty ? "—" : state.ttsVoiceLanguage)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            } header: {
                Text("Test")
            }
        }
        .onAppear {
            if availableVoices.isEmpty {
                availableVoices = VoiceProvider.allEnglishVoices()
            }
        }
    }

    private var voicePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Voice", selection: voiceIdentifierBinding) {
                Text("Auto (best male English)").tag(String?.none)
                ForEach(availableVoices) { v in
                    HStack {
                        Text(v.name)
                        if !v.genderLabel.isEmpty {
                            Text("· \(v.genderLabel)")
                                .foregroundStyle(.secondary)
                        }
                        Text("· \(v.qualityLabel)")
                            .foregroundStyle(.tertiary)
                    }
                    .tag(Optional(v.id))
                }
            }
        }
    }

    private var rateRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Speaking rate")
                Spacer()
                Text(String(format: "%.2f", controller.prefs.current.ttsRate))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: rateBinding, in: 0.1...0.9, step: 0.01)
        }
    }

    private var pitchRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Pitch")
                Spacer()
                Text(String(format: "%.2f", controller.prefs.current.ttsPitch))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: pitchBinding, in: 0.5...2.0, step: 0.05)
        }
    }

    private var volumeRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Volume")
                Spacer()
                Text(String(format: "%.0f%%", controller.prefs.current.ttsVolume * 100))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: volumeBinding, in: 0.1...1.0, step: 0.05)
        }
    }

    // MARK: - Piper section

    @ViewBuilder
    private var piperSection: some View {
        // Resolve paths from DRAFT strings (not prefs) so validation icons update live
        // while the user types without triggering a prefs write on every keystroke.
        // Prefs are only updated when the user presses Return or moves focus away.
        let execRes   = PiperPathResolver.resolveExecutable(piperExecDraft)
        let modelRes  = PiperPathResolver.resolveModel(piperModelDraft)
        let configRes = PiperPathResolver.resolveConfig(piperConfigDraft)

        // ── Path configuration ────────────────────────────────────────────
        Section {
                piperResolvedPathRow(
                    label:       "Piper executable",
                    draft:       $piperExecDraft,
                    focused:     $piperExecFocused,
                    placeholder: "~/Applications/piper/piper/piper  or  /usr/local/bin/piper",
                    resolution:  execRes,
                    onCommit:    { controller.setPiperExecutablePath(piperExecDraft.nilIfEmpty) }
                )

                piperResolvedPathRow(
                    label:       "Model (.onnx)",
                    draft:       $piperModelDraft,
                    focused:     $piperModelFocused,
                    placeholder: "/path/to/voice.onnx",
                    resolution:  modelRes,
                    onCommit:    { controller.setPiperModelPath(piperModelDraft.nilIfEmpty) }
                )

                piperResolvedPathRow(
                    label:       "Config (.onnx.json)",
                    draft:       $piperConfigDraft,
                    focused:     $piperConfigFocused,
                    placeholder: "/path/to/voice.onnx.json",
                    resolution:  configRes,
                    onCommit:    { controller.setPiperConfigPath(piperConfigDraft.nilIfEmpty) }
                )

                HStack {
                    Text("Speaker ID (multi-speaker)")
                    Spacer()
                    TextField("default", value: piperSpeakerBinding, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .font(.system(size: 11))
                }

                Toggle("Fall back to Apple voice on failure",
                       isOn: Binding(
                        get: { controller.prefs.current.piperFallbackToApple },
                        set: { v in controller.prefs.update { $0.piperFallbackToApple = v } }
                       ))
            } header: {
                Text("Piper Configuration")
            } footer: {
                Text("Install: brew install piper-tts  or  github.com/rhasspy/piper/releases\n"
                   + "Voices: huggingface.co/rhasspy/piper-voices\n"
                   + "Tip: if piper installs as ~/Applications/piper/piper/piper, paste any parent folder — the resolver will find the executable.\n"
                   + "Press Return or Tab to save a path after typing.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            // Sync draft strings from prefs when the Piper section first appears
            // (e.g., the user switches TTS engine to Piper).
            .onAppear {
                piperExecDraft   = controller.prefs.current.piperExecutablePath ?? ""
                piperModelDraft  = controller.prefs.current.piperModelPath      ?? ""
                piperConfigDraft = controller.prefs.current.piperConfigPath     ?? ""
            }
            // Commit drafts to prefs when focus leaves any Piper field.
            .onChange(of: piperExecFocused)   { _, focused in if !focused { controller.setPiperExecutablePath(piperExecDraft.nilIfEmpty) } }
            .onChange(of: piperModelFocused)  { _, focused in if !focused { controller.setPiperModelPath(piperModelDraft.nilIfEmpty) } }
            .onChange(of: piperConfigFocused) { _, focused in if !focused { controller.setPiperConfigPath(piperConfigDraft.nilIfEmpty) } }

        // ── Validate + test ───────────────────────────────────────────────
        Section {
                Button(piperValidating ? "Validating…" : "Validate Runtime") {
                    piperValidating = true
                    piperValidationResult = nil
                    // validate() launches a subprocess — must NOT run on MainActor
                    Task.detached(priority: .userInitiated) {
                        let result = controller.piperTTS.validate()
                        await MainActor.run {
                            piperValidationResult = result
                            piperValidating = false
                        }
                    }
                }
                .disabled(piperValidating || !execRes.isValid || !modelRes.isValid)

                Button(isTesting ? "Speaking…" : "Test Piper Voice") {
                    isTesting = true
                    controller.piperTTS.testVoice()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { isTesting = false }
                }
                .disabled(isTesting || !execRes.isValid || !modelRes.isValid)

                if let r = piperValidationResult {
                    piperValidationResultView(r)
                }
            } header: {
                Text("Piper Test")
            }

        // ── Diagnostics ───────────────────────────────────────────────────
        Section("Piper Diagnostics") {
                // Path resolution status
                piperDiagRow("Executable", resolution: execRes)
                piperDiagRow("Model",      resolution: modelRes)
                piperDiagRow("Config",     resolution: configRes)

                // Last runtime result
                if controller.piperTTS.lastExitCode != 0 || !controller.piperTTS.lastError.isNilOrEmpty {
                    Divider()
                    LabeledContent("Last exit code") {
                        Text("\(controller.piperTTS.lastExitCode)")
                            .monospacedDigit()
                            .foregroundStyle(controller.piperTTS.lastExitCode == 0 ? Color.secondary : Color.red)
                    }
                    if let err = controller.piperTTS.lastError {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Last error:").font(.caption).foregroundStyle(.secondary)
                            Text(err)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.red)
                        }
                    }
                    if !controller.piperTTS.lastStderr.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Stderr:").font(.caption).foregroundStyle(.secondary)
                            ScrollView {
                                Text(controller.piperTTS.lastStderr)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 60)
                        }
                    }
                    if controller.piperTTS.lastOutputSizeBytes > 0 {
                        LabeledContent("Last WAV") {
                            Text("\(controller.piperTTS.lastOutputSizeBytes / 1024) KB")
                                .monospacedDigit()
                        }
                    }
                    LabeledContent("Config flag") {
                        Text(controller.piperTTS.lastUsedConfigFlag ? "used --config" : "skipped --config")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                // Validation results (when available)
                if let r = piperValidationResult {
                    Divider()
                    if let sr = r.configSampleRate {
                        LabeledContent("Sample rate") { Text("\(sr) Hz").monospacedDigit() }
                    }
                    if let ns = r.configSpeakers {
                        LabeledContent("Speakers") { Text("\(ns)").monospacedDigit() }
                    }
                    if r.wavSize > 0 {
                        LabeledContent("Test WAV") { Text("\(r.wavSize / 1024) KB").monospacedDigit() }
                    }
                }

                // Copy debug command button
                if execRes.isValid, modelRes.isValid {
                    Button {
                        let cmd = PiperPathResolver.debugCommand(
                            executablePath: execRes.resolvedPath ?? "",
                            modelPath:      modelRes.resolvedPath ?? "",
                            configPath:     configRes.resolvedPath ?? ""
                        )
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(cmd, forType: .string)
                    } label: {
                        Label("Copy Debug Command", systemImage: "doc.on.doc")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                }
        }
    }

    /// A path row that shows the resolution status icon and, when the
    /// resolved path differs from the raw input, displays both.
    ///
    /// `draft` is a `@State` binding owned by the parent — SwiftUI tracks it
    /// across renders so the TextField never reverts while the user is typing.
    /// `onCommit` is called on Return and on focus loss to persist the value.
    private func piperResolvedPathRow(
        label:       String,
        draft:       Binding<String>,
        focused:     FocusState<Bool>.Binding,
        placeholder: String,
        resolution:  PiperPathResolution,
        onCommit:    @escaping () -> Void
    ) -> some View {
        let resolvedDiffers = resolution.resolvedPath != nil &&
                              resolution.resolvedPath != PiperPathResolver.normalise(draft.wrappedValue)

        return HStack(spacing: 6) {
            // Status icon — green only when the resolver confirms a valid usable path
            Group {
                switch resolution.status {
                case .empty:
                    Image(systemName: "circle.dotted").foregroundStyle(.secondary)
                case .resolved:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .notExecutable:
                    Image(systemName: "lock.circle.fill").foregroundStyle(.orange)
                case .directory:
                    Image(systemName: "folder.badge.questionmark").foregroundStyle(.orange)
                case .notFound:
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.orange)
                case .wrongExtension:
                    Image(systemName: "doc.badge.ellipsis").foregroundStyle(.orange)
                }
            }
            .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 11))

                // Bound to a @State draft — stable across re-renders, so macOS
                // NSTextField never sees its content replaced while the user is typing.
                TextField(placeholder, text: draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10, design: .monospaced))
                    .focused(focused)
                    .onSubmit(onCommit)   // commit on Return

                // Show resolved path when it differs (e.g. ~ expanded, or directory→exec found)
                if resolvedDiffers, let rp = resolution.resolvedPath {
                    Text("Resolved: \(rp)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.green)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                // Show error hint inline
                if let err = resolution.errorDescription {
                    Text(err)
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }
        }
    }

    /// One-line diagnostic row showing resolution status for a path.
    @ViewBuilder
    private func piperDiagRow(_ label: String, resolution: PiperPathResolution) -> some View {
        LabeledContent(label) {
            VStack(alignment: .trailing, spacing: 1) {
                if resolution.isValid, let rp = resolution.resolvedPath {
                    Text(URL(fileURLWithPath: rp).lastPathComponent)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    Text(resolution.errorDescription ?? "—")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }

    @ViewBuilder
    private func piperValidationResultView(_ r: PiperTTS.ValidationResult) -> some View {
        if r.errors.isEmpty && r.synthesisSuc {
            Label("Validation passed — Piper is ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        } else if r.errors.isEmpty && r.executableOk && r.modelExists {
            Label("Paths valid — synthesis test pending", systemImage: "clock.circle")
                .foregroundStyle(.secondary)
                .font(.caption)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(r.errors, id: \.self) { err in
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Pronunciations section

    private var pronunciationsSection: some View {
        Section {
            ForEach(controller.pronunciationDictionary.entries) { entry in
                HStack(spacing: 8) {
                    // Enabled toggle
                    Toggle("", isOn: Binding(
                        get: { entry.enabled },
                        set: { newVal in
                            var updated = entry
                            updated.enabled = newVal
                            controller.pronunciationDictionary.update(updated)
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .frame(width: 20)

                    // Input → Output
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(entry.input)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(entry.enabled ? .primary : .secondary)
                            Image(systemName: "arrow.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(entry.output)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(entry.enabled ? .primary : .secondary)
                        }
                        if entry.isBuiltIn {
                            Text("built-in")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Spacer()

                    // Test button
                    Button {
                        controller.tts.speak(entry.output)
                    } label: {
                        Image(systemName: "speaker.wave.2")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                    // Edit button (user entries only)
                    if !entry.isBuiltIn {
                        Button {
                            editingEntry = entry
                        } label: {
                            Image(systemName: "pencil")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)

                        Button(role: .destructive) {
                            controller.pronunciationDictionary.delete(entry)
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red.opacity(0.7))
                    }
                }
                .padding(.vertical, 1)
            }

            HStack {
                Button {
                    showAddPronunciation = true
                } label: {
                    Label("Add Override", systemImage: "plus.circle")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)

                Spacer()

                Button("Reset to Defaults") {
                    controller.pronunciationDictionary.resetToDefaults()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
            }
            .padding(.top, 2)
        } header: {
            Label("Pronunciation Overrides", systemImage: "mouth.fill")
        } footer: {
            Text("Words listed here are spoken exactly as shown on the right. Built-in entries cover common acronyms and brand names. Toggle to disable without deleting.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showAddPronunciation) {
            PronunciationEditSheet(
                entry: nil,
                onSave: { input, output, cs in
                    controller.pronunciationDictionary.add(
                        input: input, output: output, caseSensitive: cs)
                }
            )
        }
        .sheet(item: $editingEntry) { entry in
            PronunciationEditSheet(
                entry: entry,
                onSave: { input, output, cs in
                    var updated = entry
                    updated.input         = input
                    updated.output        = output
                    updated.caseSensitive = cs
                    controller.pronunciationDictionary.update(updated)
                    editingEntry = nil
                }
            )
        }
    }

    // MARK: - Preprocessor diagnostics section

    private var preprocessorDiagnosticsSection: some View {
        Section("Speech Preprocessing") {
            if let diag = controller.speechPreprocessor.lastDiagnostic {
                LabeledContent("Last input") {
                    Text(diag.rawInput.isEmpty ? "—" : String(diag.rawInput.prefix(80)))
                        .foregroundStyle(.secondary)
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(2)
                }
                LabeledContent("Last output") {
                    Text(diag.finalOutput.isEmpty ? "—" : String(diag.finalOutput.prefix(80)))
                        .foregroundStyle(.secondary)
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(2)
                }
                LabeledContent("Changes") {
                    Text(diag.summary)
                        .foregroundStyle(diag.changed ? .orange : .secondary)
                        .font(.caption)
                }
                if !diag.replacements.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Replacements:").font(.caption).foregroundStyle(.secondary)
                        ForEach(diag.replacements.prefix(6), id: \.from) { r in
                            Text("\"\(r.from)\" → \"\(r.to)\"")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if !diag.acronymExpansions.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Acronyms expanded:").font(.caption).foregroundStyle(.secondary)
                        ForEach(diag.acronymExpansions.prefix(6), id: \.token) { e in
                            Text("\(e.token) → \(e.expanded)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text("No speech processed yet in this session.")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
            }
        }
    }

    // MARK: - TTS diagnostics section

    private var ttsDiagnosticsSection: some View {
        Section("Voice Diagnostics") {
            LabeledContent("Active TTS engine") {
                Text(state.ttsEngine.displayName).foregroundStyle(.secondary)
            }
            LabeledContent("Voice name") {
                Text(state.ttsVoiceName.isEmpty ? "—" : state.ttsVoiceName)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Voice identifier") {
                Text(state.ttsVoiceIdentifier.isEmpty ? "—" : state.ttsVoiceIdentifier)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let err = state.ttsLastError {
                LabeledContent("Last TTS error") {
                    Text(err).foregroundStyle(.red).font(.caption)
                }
            }
        }
    }

    // MARK: - Bindings

    private var sttEngineBinding: Binding<SpeechEngine> {
        Binding(
            get: { controller.prefs.current.speechEngine },
            set: { controller.setSpeechEngine($0) }
        )
    }

    private var ttsEngineBinding: Binding<TTSEngine> {
        Binding(
            get: { controller.prefs.current.ttsEngine },
            set: { controller.setTTSEngine($0) }
        )
    }

    private var voiceIdentifierBinding: Binding<String?> {
        Binding(
            get: { controller.prefs.current.ttsVoiceIdentifier },
            set: { controller.setTTSVoice($0) }
        )
    }

    private var rateBinding: Binding<Double> {
        Binding(
            get: { Double(controller.prefs.current.ttsRate) },
            set: { controller.setTTSRate(Float($0)) }
        )
    }

    private var pitchBinding: Binding<Double> {
        Binding(
            get: { Double(controller.prefs.current.ttsPitch) },
            set: { controller.setTTSPitch(Float($0)) }
        )
    }

    private var volumeBinding: Binding<Double> {
        Binding(
            get: { Double(controller.prefs.current.ttsVolume) },
            set: { controller.setTTSVolume(Float($0)) }
        )
    }

    private var micBinding: Binding<String?> {
        Binding(
            get: { controller.prefs.current.preferredMicrophoneUID },
            set: { newValue in
                if let id = newValue,
                   let match = state.availableMicrophones.first(where: { $0.id == id }) {
                    controller.audioDevices.setPreferred(match)
                    state.preferredMicrophoneUID = id
                    state.activeMicrophoneName   = match.name
                } else {
                    controller.audioDevices.setPreferred(nil)
                    state.preferredMicrophoneUID = nil
                }
            }
        )
    }

    private var whisperPathBinding: Binding<String> {
        Binding(
            get: { controller.prefs.current.whisperModelPath ?? "" },
            set: { controller.setWhisperModelPath($0.isEmpty ? nil : $0) }
        )
    }

    private var piperSpeakerBinding: Binding<Int?> {
        Binding(
            get: { controller.prefs.current.piperSpeakerId },
            set: { controller.setPiperSpeakerId($0) }
        )
    }
}

// MARK: - PronunciationEditSheet

/// Sheet for adding or editing a pronunciation override.
private struct PronunciationEditSheet: View {

    let entry: PronunciationEntry?
    let onSave: (String, String, Bool) -> Void

    @State private var input:         String = ""
    @State private var output:        String = ""
    @State private var caseSensitive: Bool   = true
    @State private var isTesting      = false

    @Environment(\.dismiss) private var dismiss

    init(entry: PronunciationEntry?, onSave: @escaping (String, String, Bool) -> Void) {
        self.entry  = entry
        self.onSave = onSave
        _input         = State(initialValue: entry?.input         ?? "")
        _output        = State(initialValue: entry?.output        ?? "")
        _caseSensitive = State(initialValue: entry?.caseSensitive ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(entry == nil ? "Add Pronunciation Override" : "Edit Pronunciation")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Input (what appears in the response)")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("e.g. AI", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Output (what Jarvis says)")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("e.g. A.I.", text: $output)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }

            Toggle("Case sensitive", isOn: $caseSensitive)
                .toggleStyle(.checkbox)

            HStack(spacing: 8) {
                Button(isTesting ? "Speaking…" : "Test") {
                    guard !output.isEmpty else { return }
                    isTesting = true
                    // AVSpeechSynthesizer directly — no controller available in sheet
                    let utt = AVSpeechUtterance(string: output)
                    AVSpeechSynthesizer().speak(utt)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        isTesting = false
                    }
                }
                .disabled(output.isEmpty || isTesting)

                Spacer()

                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("Save") {
                    let trimInput  = input.trimmingCharacters(in: .whitespaces)
                    let trimOutput = output.trimmingCharacters(in: .whitespaces)
                    guard !trimInput.isEmpty, !trimOutput.isEmpty else { return }
                    onSave(trimInput, trimOutput, caseSensitive)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty ||
                          output.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

// MARK: - Helpers

private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool { self?.isEmpty ?? true }
}

private extension String {
    /// Returns nil when the string is empty (trims whitespace first).
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
