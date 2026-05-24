import Foundation
import AVFoundation

// MARK: - PiperTTS

/// Piper ONNX TTS using the official Piper CLI executable.
///
/// Runs synthesis in a background queue via `Process`, writes a WAV file,
/// then plays it with `AVAudioPlayer`. Never blocks the main thread.
///
/// Setup:
///   1. Install Piper CLI: `brew install piper-tts` or download from
///      https://github.com/rhasspy/piper/releases
///   2. Download a `.onnx` model + matching `.onnx.json` config.
///   3. In Settings → Jarvis Voice → Piper, set the paths.
///      The resolver handles ~ and nested piper/piper layouts automatically.
final class PiperTTS: NSObject, TextToSpeaking, AVAudioPlayerDelegate, @unchecked Sendable {

    // MARK: - Public state

    var isSpeaking: Bool { _isSpeaking }
    let isSpeakingStream: AsyncStream<Bool>

    // ── Raw preference values (set by configure) ──────────────────────────────
    private(set) var executablePath: String = ""
    private(set) var modelPath:      String = ""
    private(set) var configPath:     String = ""

    // ── Resolved paths (computed by PiperPathResolver during configure) ───────
    private(set) var execResolution:   PiperPathResolution = .init(rawPath: "", resolvedPath: nil, status: .empty)
    private(set) var modelResolution:  PiperPathResolution = .init(rawPath: "", resolvedPath: nil, status: .empty)
    private(set) var configResolution: PiperPathResolution = .init(rawPath: "", resolvedPath: nil, status: .empty)

    /// Resolved executable path — empty string when resolution failed.
    var resolvedExecutablePath: String { execResolution.resolvedPath ?? "" }
    /// Resolved model path — empty string when resolution failed.
    var resolvedModelPath:      String { modelResolution.resolvedPath  ?? "" }
    /// Resolved config path — empty string when resolution failed.
    var resolvedConfigPath:     String { configResolution.resolvedPath ?? "" }

    var speakerId: Int?       = nil
    var fallbackToApple: Bool = true

    /// Reference to the Apple fallback — set by JarvisController after both are created.
    weak var fallbackTTS: AVSpeechTTS?

    // ── Diagnostics (read-only from outside) ──────────────────────────────────
    private(set) var lastError:         String?  = nil
    private(set) var lastSynthesisMs:   Int      = 0
    private(set) var lastCommandArgs:   [String] = []
    private(set) var lastExitCode:      Int32    = 0
    private(set) var lastStderr:        String   = ""
    private(set) var lastOutputPath:    String   = ""
    private(set) var lastOutputSizeBytes: Int    = 0
    private(set) var lastUsedConfigFlag: Bool    = false

    // MARK: - Private state

    private var _isSpeaking: Bool = false {
        didSet { continuation?.yield(_isSpeaking) }
    }
    private var continuation: AsyncStream<Bool>.Continuation?
    private var currentProcess: Process?
    private var currentPlayer:  AVAudioPlayer?
    private let synthesisQueue  = DispatchQueue(label: "com.jarvis.piper.synth", qos: .userInitiated)
    private let outputDir: URL

    // MARK: - Init

    override init() {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        outputDir = support
            .appendingPathComponent("JarvisMac/TTS/Piper/generated", isDirectory: true)
        try? FileManager.default.createDirectory(at: outputDir,
                                                 withIntermediateDirectories: true)
        var cont: AsyncStream<Bool>.Continuation!
        isSpeakingStream = AsyncStream { c in cont = c }
        super.init()
        continuation = cont
        cleanOldFiles()
    }

    // MARK: - Configuration

    func configure(prefs: Preferences) {
        executablePath = prefs.piperExecutablePath ?? ""
        modelPath      = prefs.piperModelPath      ?? ""
        configPath     = prefs.piperConfigPath     ?? ""
        speakerId      = prefs.piperSpeakerId
        fallbackToApple = prefs.piperFallbackToApple

        // Resolve all three paths using the canonical resolver.
        // Both Settings validation AND runtime synthesis read from these results.
        execResolution   = PiperPathResolver.resolveExecutable(executablePath)
        modelResolution  = PiperPathResolver.resolveModel(modelPath)
        configResolution = PiperPathResolver.resolveConfig(configPath)

        let logExec = "\(executablePath) → \(resolvedExecutablePath)"
        let logModel = "\(modelPath) → \(resolvedModelPath)"
        let logConfig = "\(configPath) → \(resolvedConfigPath)"
        Log.app.info("[PiperTTS] configured exec='\(logExec)' model='\(logModel)' config='\(logConfig)'")
    }

    // MARK: - TextToSpeaking

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        stop()

        let outputURL = outputDir.appendingPathComponent("\(UUID().uuidString).wav")
        synthesisQueue.async { [weak self] in
            self?.synthesizeAndPlay(trimmed, outputURL: outputURL)
        }
    }

    func stop() {
        currentProcess?.terminate()
        currentProcess = nil
        currentPlayer?.stop()
        currentPlayer = nil
        if _isSpeaking { _isSpeaking = false }
    }

    // MARK: - AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully _: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?._isSpeaking = false
            self?.currentPlayer = nil
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            self?.lastError = "AVAudioPlayer decode error: \(error?.localizedDescription ?? "unknown")"
            self?._isSpeaking = false
        }
    }

    // MARK: - Validation

    struct ValidationResult {
        // Path resolution results
        var execResolution:   PiperPathResolution?
        var modelResolution:  PiperPathResolution?
        var configResolution: PiperPathResolution?

        // Legacy boolean accessors kept for UI compatibility
        var executableOk:  Bool { execResolution?.isValid  ?? false }
        var modelExists:   Bool { modelResolution?.isValid ?? false }
        var configExists:  Bool { configResolution?.isValid ?? false }

        // Config content
        var configJSON:       Bool     = false
        var configSampleRate: Int?     = nil
        var configSpeakers:   Int?     = nil

        // Synthesis
        var synthesisSuc:    Bool      = false
        var wavSize:         Int       = 0
        var exitCode:        Int32     = -1
        var stderr:          String    = ""
        var usedConfigFlag:  Bool      = false

        var errors: [String] = []
    }

    /// Full validation: path resolution → config parse → test synthesis.
    /// Runs synchronously — call from a background thread.
    func validate() -> ValidationResult {
        var r = ValidationResult()

        // 1. Resolve paths (mirror what configure() does, with current raw values)
        let execRes   = PiperPathResolver.resolveExecutable(executablePath)
        let modelRes  = PiperPathResolver.resolveModel(modelPath)
        let configRes = PiperPathResolver.resolveConfig(configPath)

        r.execResolution   = execRes
        r.modelResolution  = modelRes
        r.configResolution = configRes

        // 2. Specific error messages — never "not found" when the problem is something else
        if !execRes.isValid  { r.errors.append(execRes.statusLabel) }
        if !modelRes.isValid { r.errors.append(modelRes.statusLabel) }
        if !configRes.isValid { r.errors.append(configRes.statusLabel) }

        // 3. Parse config JSON for sample-rate / speaker count
        if let cp = configRes.resolvedPath,
           let data = try? Data(contentsOf: URL(fileURLWithPath: cp)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            r.configJSON = true
            if let audio = json["audio"] as? [String: Any],
               let sr = audio["sample_rate"] as? Int { r.configSampleRate = sr }
            if let inference = json["inference"] as? [String: Any],
               let ns = inference["num_speakers"] as? Int { r.configSpeakers = ns }
        } else if configRes.isValid {
            r.errors.append("Config file is not valid JSON: \(configRes.resolvedPath ?? "")")
        }

        guard execRes.isValid, modelRes.isValid else { return r }

        // 4. Test synthesis — try with --config first, fall back without
        let testURL = outputDir.appendingPathComponent("validate-\(UUID().uuidString).wav")
        let (code, stderr, usedConfig) = runSynthesis(
            text: "Jarvis online.",
            execPath: resolvedExecutablePath,
            modelPath: resolvedModelPath,
            configPath: resolvedConfigPath,
            outputPath: testURL.path
        )
        r.exitCode       = code
        r.stderr         = stderr
        r.usedConfigFlag = usedConfig

        if code != 0 {
            r.errors.append("Piper exited \(code). stderr: \(r.stderr.prefix(300))")
            return r
        }

        if let attrs = try? FileManager.default.attributesOfItem(atPath: testURL.path),
           let size  = attrs[.size] as? Int, size > 500 {
            r.synthesisSuc = true
            r.wavSize      = size
        } else {
            r.errors.append("Output WAV missing or too small at: \(testURL.path)")
        }
        try? FileManager.default.removeItem(at: testURL)
        return r
    }

    // MARK: - Private synthesis

    private func synthesizeAndPlay(_ text: String, outputURL: URL) {
        let start = Date()
        lastError = nil

        // Log raw vs resolved for diagnostics
        let synthLogExec = "\(self.executablePath) → \(self.resolvedExecutablePath)"
        let synthLogModel = "\(self.modelPath) → \(self.resolvedModelPath)"
        Log.app.info("[PiperTTS] synthesize exec='\(synthLogExec)' model='\(synthLogModel)'")

        guard !self.resolvedExecutablePath.isEmpty else {
            let msg = self.execResolution.errorDescription ?? "Piper executable path is empty."
            self.lastError = msg
            Log.app.error("[PiperTTS] \(msg)")
            if self.fallbackToApple { DispatchQueue.main.async { [weak self] in self?.fallbackTTS?.speak(text) } }
            return
        }
        guard !self.resolvedModelPath.isEmpty else {
            let msg = self.modelResolution.errorDescription ?? "Piper model path is empty."
            self.lastError = msg
            Log.app.error("[PiperTTS] \(msg)")
            if self.fallbackToApple { DispatchQueue.main.async { [weak self] in self?.fallbackTTS?.speak(text) } }
            return
        }

        let (code, stderrStr, usedConfig) = runSynthesis(
            text: text,
            execPath: resolvedExecutablePath,
            modelPath: resolvedModelPath,
            configPath: resolvedConfigPath,
            outputPath: outputURL.path
        )
        lastExitCode      = code
        lastStderr        = stderrStr
        lastUsedConfigFlag = usedConfig
        lastSynthesisMs   = Int(Date().timeIntervalSince(start) * 1000)

        if code != 0 {
            let errMsg = "Piper exited \(code): \(stderrStr)"
            lastError = errMsg
            Log.app.error("[PiperTTS] \(errMsg)")
            if fallbackToApple { DispatchQueue.main.async { [weak self] in self?.fallbackTTS?.speak(text) } }
            return
        }

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
              let size  = attrs[.size] as? Int, size > 500 else {
            let errMsg = "Piper output WAV missing or too small at: \(outputURL.path)"
            lastError = errMsg
            Log.app.error("[PiperTTS] \(errMsg)")
            if fallbackToApple { DispatchQueue.main.async { [weak self] in self?.fallbackTTS?.speak(text) } }
            return
        }
        lastOutputPath      = outputURL.path
        lastOutputSizeBytes = size

        DispatchQueue.main.async { [weak self] in self?.playWAV(outputURL) }
    }

    private func playWAV(_ url: URL) {
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            currentPlayer = player
            _isSpeaking   = true
            player.play()
        } catch {
            lastError   = "AVAudioPlayer init failed: \(error.localizedDescription)"
            _isSpeaking = false
        }
    }

    // MARK: - Synthesis runner (with --config fallback)

    /// Runs Piper synthesis, returning (exitCode, stderr, usedConfigFlag).
    /// Tries `--config` first; if Piper rejects it (stderr mentions "config" or
    /// "unknown" option), retries without `--config` once.
    private func runSynthesis(text: String,
                               execPath: String,
                               modelPath: String,
                               configPath: String,
                               outputPath: String) -> (Int32, String, Bool) {
        // Attempt A: with --config (preferred)
        var args = buildArgs(modelPath: modelPath, configPath: configPath,
                             outputPath: outputPath, useConfig: true)
        lastCommandArgs = args
        var stderr = ""
        var code = runProcess(execPath: execPath, args: args, input: text, stderrOut: &stderr)

        if code == 0 { return (code, stderr, true) }

        // Attempt B: without --config — some Piper builds don't accept it
        let stderrLower = stderr.lowercased()
        let configRejected = stderrLower.contains("--config") ||
                             stderrLower.contains("unrecognized") ||
                             stderrLower.contains("unknown option") ||
                             stderrLower.contains("invalid option")
        if configRejected && !configPath.isEmpty {
            Log.app.info("[PiperTTS] --config rejected by Piper, retrying without it")
            args = buildArgs(modelPath: modelPath, configPath: configPath,
                             outputPath: outputPath, useConfig: false)
            lastCommandArgs = args
            var stderr2 = ""
            let code2 = runProcess(execPath: execPath, args: args, input: text, stderrOut: &stderr2)
            if code2 == 0 { return (code2, stderr2, false) }
            // Both failed — return the original error (more informative)
        }

        return (code, stderr, true)
    }

    /// Builds the argument list. Never uses shell interpolation.
    private func buildArgs(modelPath: String, configPath: String,
                            outputPath: String, useConfig: Bool) -> [String] {
        var args = ["--model", modelPath, "--output_file", outputPath]
        if useConfig && !configPath.isEmpty {
            args += ["--config", configPath]
        }
        if let sid = speakerId { args += ["--speaker", "\(sid)"] }
        return args
    }

    /// Launches Piper as a subprocess, feeds text via stdin, returns exit code.
    @discardableResult
    private func runProcess(execPath: String, args: [String],
                             input: String, stderrOut: inout String) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: execPath)
        process.arguments     = args

        let stdinPipe  = Pipe()
        let stderrPipe = Pipe()
        process.standardInput  = stdinPipe
        process.standardError  = stderrPipe

        do {
            try process.run()
            currentProcess = process
        } catch {
            stderrOut = "Failed to launch Piper at '\(execPath)': \(error.localizedDescription)"
            return -1
        }

        if let data = input.data(using: .utf8) {
            stdinPipe.fileHandleForWriting.write(data)
        }
        stdinPipe.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        stderrOut = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8) ?? ""
        currentProcess = nil
        return process.terminationStatus
    }

    // MARK: - Cleanup

    private func cleanOldFiles() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: outputDir, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-60)
        for file in files where file.pathExtension == "wav" {
            let created = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantFuture
            if created < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }
}
