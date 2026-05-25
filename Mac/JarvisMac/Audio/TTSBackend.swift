import Foundation
import AVFoundation

// MARK: - TTSSynthesisResult

/// Result from a synthesize() call on a TTSBackend.
struct TTSSynthesisResult {
    let audioURL:        URL?
    let synthesisDoneMs: Int     // ms from speak() to audio-data-ready
    let playbackStartMs: Int     // ms from speak() until first audible output
    let error:           String?
    var succeeded: Bool { error == nil }
}

// MARK: - TTSBackendDiagnostics

struct TTSBackendDiagnostics {
    let isAvailable:       Bool
    let unavailableReason: String?
    let lastError:         String?
    let lastSynthesisMs:   Int
    let lastTextLength:    Int
    let extraInfo:         [String: String]
}

// MARK: - TTSBackend Protocol

/// Common interface for every TTS engine Jarvis can use.
/// Extends TextToSpeaking so any backend can be plugged into the existing
/// `tts: TextToSpeaking` slot with zero JarvisController changes.
protocol TTSBackend: TextToSpeaking {
    /// Stable identifier, used as the persistence key in Preferences.
    var id:                  String { get }
    var displayName:         String { get }
    /// Whether this backend is ready to synthesise right now.
    var isAvailable:         Bool   { get }
    var supportsStreaming:    Bool   { get }
    /// Whether this backend natively handles <tag> expression markup.
    /// If false, tags will be stripped before the text reaches the engine.
    var supportsExpressionTags: Bool { get }
    var diagnostics:         TTSBackendDiagnostics { get }

    /// Optional warm-up. Call at startup; safe to skip.
    func preload() async
}

// MARK: - TTSTagStripper

/// Strips XML-style expression / emotion tags from text for backends
/// that don't support them. Preserves the inner text.
///
/// Example:
///   "<happy>Hello</happy>, <break/> world." → "Hello, world."
enum TTSTagStripper {

    private static let openCloseRegex: NSRegularExpression = {
        // Matches <tag>, </tag> – preserves content between them
        (try? NSRegularExpression(pattern: "</?[a-zA-Z][^>]*>"))!
    }()

    static func strip(_ text: String) -> String {
        let range  = NSRange(text.startIndex..., in: text)
        var result = openCloseRegex.stringByReplacingMatches(
            in: text, range: range, withTemplate: "")
        // Collapse runs of whitespace created by tag removal
        result = result.replacingOccurrences(of: #"\s{2,}"#,
            with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Conditionally strips tags based on backend capability.
    static func prepare(_ text: String, for backend: TTSBackend) -> String {
        backend.supportsExpressionTags ? text : strip(text)
    }
}
