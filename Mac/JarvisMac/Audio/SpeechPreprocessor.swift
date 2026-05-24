import Foundation
import os

// MARK: - Diagnostic

/// Records exactly what the preprocessor changed for a given input.
/// Exposed to DebugHUDView and Settings → Voice → Diagnostics.
struct SpeechPreprocessorDiagnostic {
    let rawInput:          String
    let finalOutput:       String
    let replacements:      [(from: String, to: String)]   // dict + URL + technical
    let acronymExpansions: [(token: String, expanded: String)]

    var changed: Bool { rawInput != finalOutput }

    var summary: String {
        guard changed else { return "No changes" }
        var parts: [String] = []
        if !replacements.isEmpty {
            parts.append("\(replacements.count) replacement\(replacements.count == 1 ? "" : "s")")
        }
        if !acronymExpansions.isEmpty {
            parts.append("\(acronymExpansions.count) acronym\(acronymExpansions.count == 1 ? "" : "s")")
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - SpeechPreprocessor

/// Transforms raw response text into TTS-safe speech text before synthesis.
///
/// **Pipeline (executed in order):**
///  1. Strip markdown   — removes ``` fences, **bold**, # headers, etc.
///  2. Expand technical — "v1.2.5" → "version 1 point 2 point 5", "README.md" → "README dot em dee"
///  3. Expand URLs      — "github.com" → "github dot com"
///  4. Apply dictionary — user overrides + built-in brand/acronym table (longest-first)
///  5. Auto-expand acronyms — remaining ALL-CAPS tokens (3–8 chars) → "A.B.C." form
///  6. Normalize whitespace — collapse runs of spaces/newlines
///
/// All steps are synchronous string operations — sub-millisecond, no I/O.
@MainActor
final class SpeechPreprocessor {

    let dictionary: PronunciationDictionary
    private(set) var lastDiagnostic: SpeechPreprocessorDiagnostic?
    private let log = Logger(subsystem: "com.jarvis", category: "speech.preprocessor")

    init(dictionary: PronunciationDictionary) {
        self.dictionary = dictionary
    }

    // MARK: - Entry point

    func process(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var t = text
        var replacements:  [(String, String)] = []
        var expansions:    [(String, String)] = []

        t = stripMarkdown(t)
        t = expandTechnical(t, replacements: &replacements)
        t = expandURLs(t,      replacements: &replacements)
        t = dictionary.apply(to: t, replacements: &replacements)
        t = expandAcronyms(t,  expansions:    &expansions)
        t = normalizeWhitespace(t)

        lastDiagnostic = SpeechPreprocessorDiagnostic(
            rawInput:          text,
            finalOutput:       t,
            replacements:      replacements,
            acronymExpansions: expansions)

        if t != text {
            log.debug("Preprocessed: \"\(text.prefix(60))\" → \"\(t.prefix(60))\"")
        }
        return t
    }

    // MARK: - Step 1: Markdown stripping

    private func stripMarkdown(_ text: String) -> String {
        var t = text
        // Triple-backtick code fences (multi-line): ```...``` → space
        t = t.replacingOccurrences(of: "```[\\s\\S]*?```",
                                    with: " ", options: .regularExpression)
        // Inline code: `word` → word
        t = t.replacingOccurrences(of: "`([^`\n]+)`",
                                    with: "$1", options: .regularExpression)
        // Bold: **text** → text
        t = t.replacingOccurrences(of: "\\*\\*([^*\n]+)\\*\\*",
                                    with: "$1", options: .regularExpression)
        // Italic: *text* → text (after bold so **text** doesn't match twice)
        t = t.replacingOccurrences(of: "\\*([^*\n]+)\\*",
                                    with: "$1", options: .regularExpression)
        // ATX Headers: ### text → text  ((?m) = multi-line, ^ matches each line start)
        t = t.replacingOccurrences(of: "(?m)^#{1,6}[ \\t]+",
                                    with: "", options: .regularExpression)
        // Markdown links: [text](url) → text
        t = t.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]+\\)",
                                    with: "$1", options: .regularExpression)
        // Blockquotes: > text → text
        t = t.replacingOccurrences(of: "(?m)^[ \\t]*>[ \\t]*",
                                    with: "", options: .regularExpression)
        // Horizontal rules: ---  ***  ___ alone on a line → nothing
        t = t.replacingOccurrences(of: "(?m)^[ \\t]*[-*_]{3,}[ \\t]*$",
                                    with: "", options: .regularExpression)
        // Unordered bullet: "- item" or "* item" → item
        t = t.replacingOccurrences(of: "(?m)^[ \\t]*[-*+][ \\t]+",
                                    with: "", options: .regularExpression)
        // Ordered list: "1. item" → item
        t = t.replacingOccurrences(of: "(?m)^[ \\t]*\\d+\\.[ \\t]+",
                                    with: "", options: .regularExpression)
        return t
    }

    // MARK: - Step 2: Technical patterns

    // v1.2, v1.2.3, etc.
    private static let versionRE = try! NSRegularExpression(
        pattern: #"\bv(\d+(?:\.\d+)+)\b"#)

    // known file extensions
    private static let fileExtRE = try! NSRegularExpression(
        pattern: #"\b([\w][\w\-]*)\.(md|json|swift|py|js|ts|css|html|txt|yaml|yml|sh|bat|exe|pkg|dmg|zip|tar|gz|onnx|pb|pth|pt)\b"#,
        options: .caseInsensitive)

    private let fileExtSpeech: [String: String] = [
        "md":    "dot em dee",   "json":  "dot jason",    "swift": "dot swift",
        "py":    "dot pie",      "js":    "dot j s",      "ts":    "dot t s",
        "css":   "dot c s s",   "html":  "dot h t m l",  "txt":   "dot text",
        "yaml":  "dot yaml",    "yml":   "dot yaml",      "sh":    "dot s h",
        "bat":   "dot bat",     "exe":   "dot e x e",     "pkg":   "dot p k g",
        "dmg":   "dot d m g",   "zip":   "dot zip",       "tar":   "dot tar",
        "gz":    "dot g z",     "onnx":  "dot onnx",      "pb":    "dot p b",
        "pth":   "dot p t h",   "pt":    "dot p t",
    ]

    private func expandTechnical(_ text: String,
                                  replacements: inout [(String, String)]) -> String {
        var t = text

        // Versions: v1.2.5 → "version 1 point 2 point 5"
        let vMatches = Self.versionRE.matches(
            in: t, range: NSRange(t.startIndex..., in: t))
        for m in vMatches.reversed() {
            guard let full = Range(m.range,        in: t),
                  let numR = Range(m.range(at: 1), in: t) else { continue }
            let original = String(t[full])
            let numStr   = String(t[numR])
            let spoken   = "version " + numStr.replacingOccurrences(of: ".", with: " point ")
            replacements.append((original, spoken))
            t.replaceSubrange(full, with: spoken)
        }

        // Files: README.md → "README dot em dee"
        let fMatches = Self.fileExtRE.matches(
            in: t, range: NSRange(t.startIndex..., in: t))
        for m in fMatches.reversed() {
            guard let full  = Range(m.range,        in: t),
                  let extR  = Range(m.range(at: 2), in: t) else { continue }
            let original = String(t[full])
            let ext      = String(t[extR]).lowercased()
            guard let speech = fileExtSpeech[ext] else { continue }
            let base   = String(original.dropLast(ext.count + 1))
            let spoken = "\(base) \(speech)"
            replacements.append((original, spoken))
            t.replaceSubrange(full, with: spoken)
        }

        return t
    }

    // MARK: - Step 3: URL expansion

    private static let fullURLRE = try! NSRegularExpression(
        pattern: #"https?://[^\s,;\"')>\]]+"#)
    private static let bareURLRE = try! NSRegularExpression(
        pattern: #"\b([a-zA-Z0-9][-a-zA-Z0-9]*)\.(com|io|net|org|co|dev|ai|app|me|tv)\b"#)

    private func expandURLs(_ text: String,
                             replacements: inout [(String, String)]) -> String {
        var t = text

        // https://github.com/user/repo → "github dot com"
        let urlMatches = Self.fullURLRE.matches(
            in: t, range: NSRange(t.startIndex..., in: t))
        for m in urlMatches.reversed() {
            guard let range = Range(m.range, in: t) else { continue }
            let original = String(t[range])
            if let url = URL(string: original), let host = url.host {
                let spoken = host
                    .replacingOccurrences(of: "www.", with: "")
                    .replacingOccurrences(of: ".", with: " dot ")
                    .trimmingCharacters(in: .whitespaces)
                replacements.append((original, spoken))
                t.replaceSubrange(range, with: spoken)
            }
        }

        // Bare domains: github.com → "github dot com"
        let domMatches = Self.bareURLRE.matches(
            in: t, range: NSRange(t.startIndex..., in: t))
        for m in domMatches.reversed() {
            guard let range = Range(m.range, in: t) else { continue }
            let original = String(t[range])
            let spoken   = original.replacingOccurrences(of: ".", with: " dot ")
            replacements.append((original, spoken))
            t.replaceSubrange(range, with: spoken)
        }

        return t
    }

    // MARK: - Step 5: Auto-acronym expansion

    /// Common English words and known-safe abbreviations that must NOT be
    /// letter-expanded even when they appear in ALL CAPS.
    private static let acronymExceptions: Set<String> = [
        // English words
        "AND", "THE", "FOR", "ARE", "BUT", "NOT", "YOU", "ALL", "CAN",
        "WAS", "ONE", "OUR", "OUT", "WHO", "GET", "HAS", "HIM", "HIS",
        "HOW", "MAN", "NEW", "NOW", "OLD", "SEE", "TWO", "WAY", "DID",
        "ITS", "LET", "MEN", "PUT", "SAY", "SHE", "TOO", "USE", "MAY",
        "DAY", "GOT", "BIG", "SIX", "TEN", "YES", "YET", "ACT", "ADD",
        "AGO", "AIM", "AIR", "ARM", "ART", "ASK", "BAD", "BAR", "BAY",
        "BED", "BIT", "BOY", "BUS", "BUY", "CAR", "CAT", "CUT", "EAR",
        "EAT", "END", "EYE", "FAR", "FAT", "FEW", "FIT", "FLY", "FUN",
        "GAS", "HAD", "HAT", "HIT", "HOT", "JAM", "JOB", "JOY", "KEY",
        "KID", "LAW", "LAY", "LEG", "LIE", "LOG", "LOT", "LOW", "MAP",
        "MIX", "MOM", "NET", "ODD", "OIL", "OWN", "PAD", "PAY", "PET",
        "PIE", "PIG", "PIT", "POT", "RAW", "RED", "RIB", "ROD", "ROW",
        "RUG", "RUN", "SAT", "SAW", "SET", "SIN", "SIT", "SKY", "SOB",
        "SON", "SPA", "SPY", "SUB", "SUM", "SUN", "TAB", "TAP", "TAR",
        "TAX", "TIE", "TIN", "TIP", "TON", "TOP", "TOW", "TOY", "TUB",
        "VAT", "VIA", "VOW", "WAX", "WEB", "WIG", "WIN", "WIT", "WOE",
        "WON", "YAK", "YAM", "ZIP", "ZOO",
        // Time / common abbreviations that sound fine as whole words
        "OK", "AM", "PM",
        // Multi-syllable words that are sometimes all-caps for emphasis
        "OPEN", "VERY", "ALSO", "JUST", "LIKE", "THIS", "THAT", "THEN",
        "WHEN", "WILL", "WITH", "FROM", "BEEN", "HAVE", "MORE", "SOME",
        "SUCH", "THAN", "THEM", "THEY", "TIME", "WELL", "WERE", "WHAT",
        "YOUR", "AFTER", "COULD", "EVERY", "FIRST", "FOUND", "GREAT",
        "THEIR", "THERE", "THESE", "THINK", "THOSE", "WHICH", "WHILE",
        "WOULD", "ABOUT", "AGAIN", "BEING", "BRING", "BUILT", "COMES",
        "DOING", "GIVEN", "GOING", "HELPS", "LARGE", "LEARN", "LIGHT",
        "MAKES", "NEEDS", "OTHER", "PLACE", "POINT", "RIGHT", "SINCE",
        "SMALL", "START", "STATE", "STILL", "STORE", "THREE", "UNDER",
        "USING", "WHOLE", "ABOVE", "BASED", "BELOW", "BRIEF", "CLEAR",
        "CLOSE", "CROSS", "EARLY", "FRONT", "GUESS", "HEARD", "HTTPS",
        "INTEL", "LATER", "LEVEL", "LOCAL", "MEANS", "MODEL", "NEVER",
        "NOTES", "OPENS", "ORDER", "PANEL", "PRESS", "PRICE", "PRINT",
        "PROOF", "QUICK", "QUITE", "RADIO", "RANGE", "REACH", "READS",
        "READY", "REPLY", "RESET", "RIDER", "RINGS", "RIVER", "ROUND",
        "ROUTE", "RULES", "SAVES", "SCENE", "SCOPE", "SCORE", "SEEMS",
        "SENSE", "SEVEN", "SHAPE", "SHARE", "SHORT", "SHOWS", "SIDES",
        "SINCE", "SIZED", "SLEEP", "SLIDE", "SMART", "SOUND", "SPACE",
        "SPEED", "SPEND", "SPOKE", "STACK", "STEPS", "STONE", "STOOD",
        "STOPS", "STORY", "STUDY", "STYLE", "SUPER", "SWIPE", "TESTS",
        "THING", "THIRD", "TITLE", "TODAY", "TOKEN", "TOTAL", "TOUGH",
        "TRACE", "TRACK", "TRADE", "TRIAL", "TRUST", "TRUTH", "TURNS",
        "TYPED", "TYPES", "UNSET", "UNTIL", "UPPER", "USAGE", "USERS",
        "VALUE", "VIDEO", "VIEWS", "VISIT", "VOICE", "WATCH", "WHERE",
        "WHOSE", "WIDER", "WORKS", "WORLD", "WRITE", "YEARS",
    ]

    private static let acronymRE = try! NSRegularExpression(
        pattern: #"\b([A-Z]{3,8})\b"#)

    private func expandAcronyms(_ text: String,
                                 expansions: inout [(String, String)]) -> String {
        var t = text
        let matches = Self.acronymRE.matches(
            in: t, range: NSRange(t.startIndex..., in: t))
        for m in matches.reversed() {
            guard let range = Range(m.range, in: t) else { continue }
            let token = String(t[range])
            guard !Self.acronymExceptions.contains(token) else { continue }
            let expanded = token.map { String($0) }.joined(separator: ".") + "."
            expansions.append((token, expanded))
            t.replaceSubrange(range, with: expanded)
        }
        return t
    }

    // MARK: - Step 6: Whitespace normalization

    private func normalizeWhitespace(_ text: String) -> String {
        text
            .replacingOccurrences(of: "[ \\t]{2,}", with: " ",  options: .regularExpression)
            .replacingOccurrences(of: "[\\n\\r]+",  with: " ",  options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
