import Foundation
import AVFoundation

// MARK: - Protocol

protocol TextToSpeaking: AnyObject {
    func speak(_ text: String)
    func stop()
    var isSpeaking: Bool { get }
    var isSpeakingStream: AsyncStream<Bool> { get }
}

extension TextToSpeaking {
    /// Speaks the standard Jarvis test phrase.
    func testVoice() {
        speak("Good evening. Jarvis systems are online.")
    }
}

// MARK: - Voice discovery

/// Lightweight snapshot of an `AVSpeechSynthesisVoice` for use in UI pickers.
struct VoiceInfo: Identifiable, Equatable, Hashable {
    let id: String          // AVSpeechSynthesisVoice.identifier — stable across launches
    let name: String
    let language: String
    let qualityLabel: String    // "Premium" | "Enhanced" | "Default"
    let genderLabel: String     // "Male" | "Female" | ""
}

enum VoiceProvider {

    // MARK: - Enumerate voices

    /// All English voices sorted by quality (Premium first) then name.
    static func allEnglishVoices() -> [VoiceInfo] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .map { info(from: $0) }
            .sorted { lhs, rhs in
                let ql = qualityRank(lhs.qualityLabel), qr = qualityRank(rhs.qualityLabel)
                if ql != qr { return ql > qr }
                return lhs.name < rhs.name
            }
    }

    static func info(from v: AVSpeechSynthesisVoice) -> VoiceInfo {
        let quality: String
        switch v.quality {
        case .premium:  quality = "Premium"
        case .enhanced: quality = "Enhanced"
        default:        quality = "Default"
        }
        let gender: String
        if #available(macOS 12, *) {
            switch v.gender {
            case .male:   gender = "Male"
            case .female: gender = "Female"
            default:      gender = ""
            }
        } else {
            gender = genderHeuristicFromName(v.name)
        }
        return VoiceInfo(id: v.identifier, name: v.name,
                         language: v.language, qualityLabel: quality,
                         genderLabel: gender)
    }

    // MARK: - Male default selection

    /// Returns the best available male English voice identifier for first-launch
    /// default. Preference: en-GB > en-AU > en-US > any English, Premium > Enhanced > Default.
    static func bestMaleEnglishIdentifier() -> String? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let english = voices.filter { $0.language.hasPrefix("en") }

        var maleVoices: [AVSpeechSynthesisVoice]
        if #available(macOS 12, *) {
            maleVoices = english.filter { $0.gender == .male }
        } else {
            maleVoices = english.filter { genderHeuristicFromName($0.name) == "Male" }
        }

        let pool = maleVoices.isEmpty ? english : maleVoices
        let sorted = pool.sorted { a, b in
            let qa = qualityRankVoice(a), qb = qualityRankVoice(b)
            if qa != qb { return qa > qb }
            return localePreference(a.language) > localePreference(b.language)
        }
        return sorted.first?.identifier
    }

    // MARK: - Private helpers

    private static func qualityRank(_ label: String) -> Int {
        switch label { case "Premium": return 2; case "Enhanced": return 1; default: return 0 }
    }
    private static func qualityRankVoice(_ v: AVSpeechSynthesisVoice) -> Int {
        switch v.quality { case .premium: return 2; case .enhanced: return 1; default: return 0 }
    }
    private static func localePreference(_ lang: String) -> Int {
        if lang.hasPrefix("en-GB") { return 4 }
        if lang.hasPrefix("en-AU") { return 3 }
        if lang.hasPrefix("en-US") { return 2 }
        return lang.hasPrefix("en") ? 1 : 0
    }

    /// Name-based gender heuristic for macOS < 12 that lacks `.gender` API.
    static func genderHeuristicFromName(_ name: String) -> String {
        let l = name.lowercased()
        let maleNames = ["daniel", "malcolm", "oliver", "alex", "tom", "aaron",
                          "arthur", "bruce", "gordon", "lee", "reed", "rishi",
                          "sandy", "thomas", "fred", "rishi", "junior"]
        for m in maleNames where l.contains(m) { return "Male" }
        return "Female"
    }
}

// MARK: - AVSpeechTTS

/// Apple TTS. Configure once at boot with `configure(prefs:)`, then update on
/// any preference change. Every `speak()` call uses the current configuration.
final class AVSpeechTTS: NSObject, TextToSpeaking, AVSpeechSynthesizerDelegate, @unchecked Sendable {

    private let synth = AVSpeechSynthesizer()
    private var continuation: AsyncStream<Bool>.Continuation?
    let isSpeakingStream: AsyncStream<Bool>
    var isSpeaking: Bool { synth.isSpeaking }

    // Serial queue at .userInitiated keeps AVSpeechSynthesizer calls off the
    // main thread and avoids the QoS priority-inversion warning.
    private let ttsQueue = DispatchQueue(label: "com.jarvis.tts", qos: .userInitiated)

    // Current voice config — updated by configure(prefs:)
    private var configuredVoiceId: String? = nil
    private var configuredRate: Float = AVSpeechUtteranceDefaultSpeechRate
    private var configuredPitch: Float = 1.0
    private var configuredVolume: Float = 1.0

    override init() {
        var cont: AsyncStream<Bool>.Continuation!
        self.isSpeakingStream = AsyncStream { c in cont = c }
        super.init()
        self.continuation = cont
        synth.delegate = self
    }

    // MARK: - Configuration

    func configure(prefs: Preferences) {
        configuredVoiceId = prefs.ttsVoiceIdentifier
        configuredRate    = prefs.ttsRate
        configuredPitch   = prefs.ttsPitch
        configuredVolume  = prefs.ttsVolume
    }

    /// Resolved voice: stored identifier → best male English → en-GB fallback.
    var resolvedVoice: AVSpeechSynthesisVoice? {
        if let id = configuredVoiceId,
           let v  = AVSpeechSynthesisVoice(identifier: id) { return v }
        if let id = VoiceProvider.bestMaleEnglishIdentifier(),
           let v  = AVSpeechSynthesisVoice(identifier: id) { return v }
        return AVSpeechSynthesisVoice(language: "en-GB")
    }

    // MARK: - TextToSpeaking

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let voice   = resolvedVoice
        let rate    = configuredRate
        let pitch   = configuredPitch
        let volume  = configuredVolume
        ttsQueue.async { [weak self] in
            guard let self else { return }
            if self.synth.isSpeaking { self.synth.stopSpeaking(at: .immediate) }
            let utterance             = AVSpeechUtterance(string: trimmed)
            utterance.voice           = voice
            utterance.rate            = rate
            utterance.pitchMultiplier = pitch
            utterance.volume          = volume
            self.synth.speak(utterance)
        }
    }

    func stop() {
        ttsQueue.async { [weak self] in
            guard let self else { return }
            if self.synth.isSpeaking {
                self.synth.stopSpeaking(at: .immediate)
            } else {
                self.continuation?.yield(false)
            }
        }
    }

    // MARK: - Delegate

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance)    { continuation?.yield(true)  }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance)   { continuation?.yield(false) }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance)   { continuation?.yield(false) }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didPause u: AVSpeechUtterance)    { continuation?.yield(false) }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didContinue u: AVSpeechUtterance) { continuation?.yield(true)  }
}
