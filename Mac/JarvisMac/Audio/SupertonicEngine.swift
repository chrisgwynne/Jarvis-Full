import Foundation
import AVFoundation

// MARK: - SupertonicModelDirectory

/// Canonical paths for a Supertonic 3 model installation.
/// Expected layout under the base directory:
///   onnx/duration_predictor.onnx
///   onnx/text_encoder.onnx
///   onnx/vector_estimator.onnx
///   onnx/vocoder.onnx
///   onnx/tts.json
///   onnx/unicode_indexer.json
///   voice_styles/M1.json … M5.json, F1.json … F5.json
struct SupertonicModelDirectory {

    let base: URL

    static var defaultURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JarvisMac/TTS/Supertonic", isDirectory: true)
    }

    var onnxDir:        URL { base.appendingPathComponent("onnx",         isDirectory: true) }
    var voiceStylesDir: URL { base.appendingPathComponent("voice_styles", isDirectory: true) }
    var generatedDir:   URL { base.appendingPathComponent("generated",    isDirectory: true) }

    var durationPredictorURL: URL { onnxDir.appendingPathComponent("duration_predictor.onnx") }
    var textEncoderURL:       URL { onnxDir.appendingPathComponent("text_encoder.onnx")       }
    var vectorEstimatorURL:   URL { onnxDir.appendingPathComponent("vector_estimator.onnx")   }
    var vocoderURL:           URL { onnxDir.appendingPathComponent("vocoder.onnx")            }
    var configURL:            URL { onnxDir.appendingPathComponent("tts.json")                }
    var unicodeIndexerURL:    URL { onnxDir.appendingPathComponent("unicode_indexer.json")    }

    var requiredONNXFiles: [URL] {
        [durationPredictorURL, textEncoderURL, vectorEstimatorURL, vocoderURL]
    }

    /// All .json files in voice_styles/, sorted by name.
    var voiceStyleURLs: [URL] {
        guard let contents = try? FileManager.default
            .contentsOfDirectory(at: voiceStylesDir,
                                 includingPropertiesForKeys: nil,
                                 options: .skipsHiddenFiles) else { return [] }
        return contents
            .filter  { $0.pathExtension == "json" }
            .sorted  { $0.lastPathComponent < $1.lastPathComponent }
    }

    var defaultVoiceStyleURL: URL? { voiceStyleURLs.first }

    /// Returns paths (relative to `base`) of any required files that are missing.
    func missingFiles() -> [String] {
        let fm = FileManager.default
        var missing: [String] = []
        for url in requiredONNXFiles + [configURL, unicodeIndexerURL] {
            if !fm.fileExists(atPath: url.path) {
                missing.append(url.path.replacingOccurrences(of: base.path + "/", with: ""))
            }
        }
        if voiceStyleURLs.isEmpty {
            missing.append("voice_styles/M1.json (or any *.json style file)")
        }
        return missing
    }

    var allRequiredFilesPresent: Bool { missingFiles().isEmpty }

    func createGeneratedDir() {
        try? FileManager.default.createDirectory(at: generatedDir, withIntermediateDirectories: true)
    }
}

// MARK: - SupertonicConfig

/// Parsed content of `onnx/tts.json`.
struct SupertonicConfig {
    let sampleRate:        Int  // typically 44100
    let compressionFactor: Int  // latent frames to audio samples ratio (typically 8)
    let latentDim:         Int  // latent space dimensionality (typically 64 or 128)

    static let defaults = SupertonicConfig(sampleRate: 44100, compressionFactor: 8, latentDim: 128)

    static func load(from url: URL) -> SupertonicConfig {
        guard let data  = try? Data(contentsOf: url),
              let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .defaults
        }
        let sr = json["sample_rate"]        as? Int ?? defaults.sampleRate
        let cf = json["compression_factor"] as? Int ?? defaults.compressionFactor
        let ld = json["latent_dim"]         as? Int ?? defaults.latentDim
        return SupertonicConfig(sampleRate: sr, compressionFactor: cf, latentDim: ld)
    }
}

// MARK: - SupertonicVoiceStyle

/// Loaded content of a `voice_styles/*.json` file.
/// Each file contains two style embedding tensors: `style_ttl` (text encoder)
/// and `style_dp` (duration predictor), each with `data` (float array) and
/// optional `shape` metadata.
struct SupertonicVoiceStyle {

    struct Component: Decodable {
        let data:  [Float]
        let shape: [Int]?
    }

    let name:      String
    let style_ttl: Component
    let style_dp:  Component

    // Convenience: shape as [NSNumber] for ORTValue creation.
    var ttlShape: [Int] { style_ttl.shape ?? [1, 1, style_ttl.data.count] }
    var dpShape:  [Int] { style_dp.shape  ?? [1, 1, style_dp.data.count]  }

    private struct Wrapper: Decodable {
        let style_ttl: Component
        let style_dp:  Component
    }

    static func load(from url: URL) throws -> SupertonicVoiceStyle {
        let data    = try Data(contentsOf: url)
        let wrapper = try JSONDecoder().decode(Wrapper.self, from: data)
        let name    = url.deletingPathExtension().lastPathComponent
        return SupertonicVoiceStyle(name: name,
                                    style_ttl: wrapper.style_ttl,
                                    style_dp:  wrapper.style_dp)
    }
}

// MARK: - SupertonicUnicodeProcessor

/// Loads `unicode_indexer.json` and tokenises text into integer IDs.
/// Applies NFKD normalisation and wraps the input with `[lang=en]…[/lang=en]`
/// language tags, which is the format Supertonic 3 expects.
final class SupertonicUnicodeProcessor {

    private let charToIndex: [String: Int32]

    init(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let raw  = try JSONSerialization.jsonObject(with: data) as? [String: Int]
        charToIndex = (raw ?? [:]).mapValues { Int32($0) }
    }

    func tokenize(_ text: String, language: String = "en") -> [Int32] {
        let normalized = text.decomposedStringWithCompatibilityMapping
        let tagged     = "[lang=\(language)]\(normalized)[/lang=\(language)]"
        return tagged.unicodeScalars.map { scalar -> Int32 in
            charToIndex[String(scalar)] ?? 0
        }
    }
}

// MARK: - SupertonicTextChunker

/// Splits long text at sentence boundaries to stay within the 300-character
/// chunk limit recommended for Supertonic 3 inference.
enum SupertonicTextChunker {

    static let maxSize = 300

    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "rev", "gen",
        "sgt", "cpl", "pvt", "etc", "vs", "ltd", "inc"
    ]

    static func chunk(_ text: String, maxSize: Int = SupertonicTextChunker.maxSize) -> [String] {
        guard text.count > maxSize else { return [text.isEmpty ? text : text].filter { !$0.isEmpty } }
        var chunks: [String] = []
        let sentences = splitSentences(text)
        var current   = ""
        for sentence in sentences {
            if sentence.count > maxSize {
                if !current.isEmpty { chunks.append(current); current = "" }
                chunks.append(contentsOf: splitWords(sentence, maxSize: maxSize))
                continue
            }
            let candidate = current.isEmpty ? sentence : "\(current) \(sentence)"
            if candidate.count <= maxSize {
                current = candidate
            } else {
                if !current.isEmpty { chunks.append(current) }
                current = sentence
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks.filter { !$0.isEmpty }
    }

    private static func splitSentences(_ text: String) -> [String] {
        var result  = [String]()
        var current = ""
        let chars   = Array(text)
        for (i, ch) in chars.enumerated() {
            current.append(ch)
            guard ".!?".contains(ch) else { continue }
            let nextIsSpaceOrEnd = (i + 1 >= chars.count) || chars[i + 1] == " "
            guard nextIsSpaceOrEnd else { continue }
            let lastWord = current.split(separator: " ").last
                .map { $0.trimmingCharacters(in: .punctuationCharacters).lowercased() } ?? ""
            if !abbreviations.contains(lastWord) {
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            result.append(current.trimmingCharacters(in: .whitespaces))
        }
        return result
    }

    private static func splitWords(_ text: String, maxSize: Int) -> [String] {
        var result = [String]()
        var current = ""
        for word in text.split(separator: " ").map(String.init) {
            let candidate = current.isEmpty ? word : "\(current) \(word)"
            if candidate.count <= maxSize { current = candidate }
            else { if !current.isEmpty { result.append(current) }; current = word }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

// MARK: - SupertonicAudioWriter

/// Converts float audio samples (44.1 kHz, range −1…1) to a RIFF WAV blob.
enum SupertonicAudioWriter {

    /// 0.3-second silence at 44100 Hz (13230 zero samples).
    static func silenceSamples(sampleRate: Int, seconds: Double = 0.3) -> [Float] {
        [Float](repeating: 0, count: Int(Double(sampleRate) * seconds))
    }

    static func toWAV(samples: [Float], sampleRate: Int) -> Data {
        let channelCount: Int32  = 1
        let bitsPerSample: Int16 = 16
        let sr32                 = Int32(sampleRate)
        let byteRate             = sr32 * channelCount * Int32(bitsPerSample) / 8
        let blockAlign: Int16    = Int16(channelCount) * bitsPerSample / 8
        let pcm: [Int16]         = samples.map { s in
            Int16(max(-32767, min(32767, s * 32767.0)))
        }
        let dataBytes = Int32(pcm.count * 2)
        let riffSize  = Int32(36) + dataBytes

        var out = Data(capacity: 44 + pcm.count * 2)

        func append<T>(_ v: T) {
            withUnsafeBytes(of: v) { out.append(contentsOf: $0) }
        }

        out.append(contentsOf: "RIFF".utf8)
        append(riffSize.littleEndian)
        out.append(contentsOf: "WAVE".utf8)
        out.append(contentsOf: "fmt ".utf8)
        append(Int32(16).littleEndian)
        append(Int16(1).littleEndian)          // PCM
        append(Int16(channelCount).littleEndian)
        append(sr32.littleEndian)
        append(byteRate.littleEndian)
        append(blockAlign.littleEndian)
        append(bitsPerSample.littleEndian)
        out.append(contentsOf: "data".utf8)
        append(dataBytes.littleEndian)
        for s in pcm { append(s.littleEndian) }

        return out
    }
}

// MARK: - SupertonicInferenceEngine (requires ONNX Runtime)

#if canImport(onnxruntime)
import onnxruntime

/// Owns the four ONNX Runtime sessions for Supertonic 3 inference.
/// Thread safety: all public methods must be called from the synthesis queue.
final class SupertonicInferenceEngine {

    private let config:       SupertonicConfig
    private let unicode:      SupertonicUnicodeProcessor
    private let ortEnv:       ORTEnv

    private let dpSession:      ORTSession   // duration predictor
    private let textEncSession: ORTSession   // text encoder
    private let vecEstSession:  ORTSession   // vector estimator (denoising loop)
    private let vocoderSession: ORTSession   // latent → waveform

    // MARK: Init

    init(directory: SupertonicModelDirectory) throws {
        config  = SupertonicConfig.load(from: directory.configURL)
        unicode = try SupertonicUnicodeProcessor(from: directory.unicodeIndexerURL)
        ortEnv  = try ORTEnv(loggingLevel: .warning)

        let opts = try ORTSessionOptions()
        try opts.setIntraOpNumThreads(4)

        dpSession      = try ORTSession(env: ortEnv, modelPath: directory.durationPredictorURL.path, sessionOptions: opts)
        textEncSession = try ORTSession(env: ortEnv, modelPath: directory.textEncoderURL.path,       sessionOptions: opts)
        vecEstSession  = try ORTSession(env: ortEnv, modelPath: directory.vectorEstimatorURL.path,   sessionOptions: opts)
        vocoderSession = try ORTSession(env: ortEnv, modelPath: directory.vocoderURL.path,           sessionOptions: opts)
    }

    // MARK: Synthesis

    /// Synthesises `text` and returns raw WAV data.
    /// - Parameters:
    ///   - text:       Input text (may include Supertonic expression tags).
    ///   - style:      Voice style loaded from a voice_styles/*.json file.
    ///   - speed:      Playback speed multiplier (1.0 = natural, 1.5 = faster).
    ///   - totalSteps: Denoising loop iterations (5–12; 8 is a good default).
    ///   - cancelled:  Checked between chunks — set true to abort early.
    func synthesize(
        text: String,
        style: SupertonicVoiceStyle,
        speed: Float = 1.0,
        totalSteps: Int = 8,
        cancelled: () -> Bool = { false }
    ) throws -> Data {

        let chunks   = SupertonicTextChunker.chunk(text)
        var allSamples = [Float]()

        let silence = SupertonicAudioWriter.silenceSamples(sampleRate: config.sampleRate)

        for (idx, chunk) in chunks.enumerated() {
            if cancelled() { break }
            let chunkSamples = try synthesizeChunk(
                chunk, style: style, speed: speed, totalSteps: totalSteps)
            allSamples.append(contentsOf: chunkSamples)
            if idx < chunks.count - 1 { allSamples.append(contentsOf: silence) }
        }

        guard !allSamples.isEmpty else {
            throw SupertonicError.emptyAudioOutput
        }
        return SupertonicAudioWriter.toWAV(samples: allSamples, sampleRate: config.sampleRate)
    }

    // MARK: Single-chunk pipeline

    private func synthesizeChunk(
        _ text: String,
        style: SupertonicVoiceStyle,
        speed: Float,
        totalSteps: Int
    ) throws -> [Float] {

        // 1 ─ Tokenise
        let tokenIds = unicode.tokenize(text)
        let seqLen   = tokenIds.count
        guard seqLen > 0 else { return [] }

        // 2 ─ Build shared input tensors
        let textIdsTensor  = try makeInt64Tensor(tokenIds.map(Int64.init), shape: [1, seqLen])
        let textMaskTensor = try makeFloatTensor([Float](repeating: 1.0, count: seqLen), shape: [1, seqLen])
        let styleTTLTensor = try makeFloatTensor(style.style_ttl.data, shape: style.ttlShape)
        let styleDPTensor  = try makeFloatTensor(style.style_dp.data,  shape: style.dpShape)

        // 3 ─ Duration predictor → latent length
        let dpOutputs = try dpSession.run(
            withInputs: ["text_ids": textIdsTensor,
                         "style_dp": styleDPTensor,
                         "text_mask": textMaskTensor],
            outputNames: Set(["duration"]),
            runOptions:  nil
        )
        let rawDuration = try extractFloats(from: dpOutputs["duration"]!)
        let latentLen   = max(1, Int(rawDuration.map { max(0, $0) / max(speed, 0.1) }.reduce(0, +).rounded()))

        // 4 ─ Text encoder → contextual embeddings
        let textEncOutputs = try textEncSession.run(
            withInputs: ["text_ids":  textIdsTensor,
                         "style_ttl": styleTTLTensor,
                         "text_mask": textMaskTensor],
            outputNames: Set(["text_emb"]),
            runOptions:  nil
        )
        let textEmbValue = textEncOutputs["text_emb"]!   // reused as-is in the loop

        // 5 ─ Build latent-space tensors
        let latentMask = [Float](repeating: 1.0, count: latentLen)
        let latentMaskTensor = try makeFloatTensor(latentMask, shape: [1, latentLen])
        var noisyLatent      = sampleGaussian(count: latentLen * config.latentDim)

        let totalStepsTensor = try makeInt64Tensor([Int64(totalSteps)], shape: [1])

        // 6 ─ Denoising / flow-matching loop
        for step in 0..<totalSteps {
            let noisyLatentTensor  = try makeFloatTensor(noisyLatent, shape: [1, latentLen, config.latentDim])
            let currentStepTensor  = try makeInt64Tensor([Int64(step)], shape: [1])

            let vecOutputs = try vecEstSession.run(
                withInputs: ["noisy_latent":  noisyLatentTensor,
                             "text_emb":      textEmbValue,
                             "style_ttl":     styleTTLTensor,
                             "latent_mask":   latentMaskTensor,
                             "text_mask":     textMaskTensor,
                             "current_step":  currentStepTensor,
                             "total_step":    totalStepsTensor],
                outputNames: Set(["denoised_latent"]),
                runOptions:  nil
            )
            noisyLatent = try extractFloats(from: vecOutputs["denoised_latent"]!)
        }

        // 7 ─ Vocoder → waveform
        let latentTensor  = try makeFloatTensor(noisyLatent, shape: [1, latentLen, config.latentDim])
        let vocoderOutput = try vocoderSession.run(
            withInputs:  ["latent": latentTensor],
            outputNames: Set(["wav_tts"]),
            runOptions:  nil
        )
        return try extractFloats(from: vocoderOutput["wav_tts"]!)
    }

    // MARK: Tensor helpers

    private func makeFloatTensor(_ values: [Float], shape: [Int]) throws -> ORTValue {
        let byteCount = values.count * MemoryLayout<Float>.size
        let buf       = NSMutableData(length: byteCount)!
        values.withUnsafeBytes { buf.replaceBytes(in: NSRange(location: 0, length: byteCount), withBytes: $0.baseAddress!) }
        return try ORTValue(tensorData: buf, elementType: .float,
                            shape: shape.map { NSNumber(value: $0) })
    }

    private func makeInt64Tensor(_ values: [Int64], shape: [Int]) throws -> ORTValue {
        let byteCount = values.count * MemoryLayout<Int64>.size
        let buf       = NSMutableData(length: byteCount)!
        values.withUnsafeBytes { buf.replaceBytes(in: NSRange(location: 0, length: byteCount), withBytes: $0.baseAddress!) }
        return try ORTValue(tensorData: buf, elementType: .int64,
                            shape: shape.map { NSNumber(value: $0) })
    }

    private func extractFloats(from value: ORTValue) throws -> [Float] {
        let data = try value.tensorData() as Data
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    // MARK: Gaussian noise (Box-Muller transform)

    private func sampleGaussian(count: Int) -> [Float] {
        var result = [Float](repeating: 0, count: count)
        var i      = 0
        while i < count {
            let u1: Float = max(Float.ulpOfOne, Float.random(in: 0..<1))
            let u2: Float = Float.random(in: 0..<1)
            let mag       = sqrtf(-2.0 * logf(u1))
            result[i]     = mag * cosf(2.0 * .pi * u2)
            i += 1
            if i < count {
                result[i] = mag * sinf(2.0 * .pi * u2)
                i += 1
            }
        }
        return result
    }
}

// MARK: - SupertonicError

enum SupertonicError: LocalizedError {
    case emptyAudioOutput
    case engineNotLoaded
    case noVoiceStyle

    var errorDescription: String? {
        switch self {
        case .emptyAudioOutput: return "Supertonic produced no audio samples."
        case .engineNotLoaded:  return "Supertonic engine is not loaded yet."
        case .noVoiceStyle:     return "No voice style file found in voice_styles/."
        }
    }
}

#endif // canImport(onnxruntime)
