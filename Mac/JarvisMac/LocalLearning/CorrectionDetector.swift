import Foundation

struct DetectedCorrection {
    let originalPhrase: String?      // what the user said before (nil = use last transcript)
    let correctedIntentHint: String  // what they meant (free-form; caller resolves to Intent)
    let wasNegation: Bool
}

enum CorrectionDetector {

    // Each tuple: (regex pattern, isNegation, hasTwoCaptures)
    // hasTwoCaptures = true → group 1 = original phrase, group 2 = corrected hint
    // hasTwoCaptures = false → group 1 = corrected hint only (original = lastTranscript)
    private static let patterns: [(String, Bool, Bool)] = [
        (#"^no[,.]?\s+when (?:i say|you hear) (.+?) (?:i mean|i want|do|show|open|play) (.+)$"#,    true,  true),
        (#"^when (?:i say|you hear) (.+?) (?:i mean|i want|do|show|open|play) (.+)$"#,              false, true),
        (#"^no[,.]?\s+if i say (.+?) (?:i mean|i want) (.+)$"#,                                      true,  true),
        (#"^no[,.]?\s+i (?:meant|mean) (.+)$"#,                                                      true,  false),
        (#"^i (?:meant|mean) (.+)$"#,                                                                 false, false),
        (#"^(?:that's|that is) wrong[,.]?\s+i (?:wanted|meant|mean) (.+)$"#,                         true,  false),
        (#"^not (?:that|it)[,.]?\s+(.+)$"#,                                                          true,  false),
        (#"^actually[,.]?\s+(.+)$"#,                                                                  false, false),
        (#"^no[,.]?\s+(?:i want|i need|show|open|do|play) (.+)$"#,                                   true,  false),
        (#"^(?:wrong|incorrect)[,.]?\s+i wanted (.+)$"#,                                              true,  false),
    ]

    static func detect(transcript: String, lastTranscript: String?) -> DetectedCorrection? {
        let norm = transcript.lowercased().trimmingCharacters(in: .whitespaces)
        for (pattern, isNeg, twoCaptures) in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            else { continue }
            let ns = norm as NSString
            let range = NSRange(location: 0, length: ns.length)
            guard let m = re.firstMatch(in: norm, range: range) else { continue }

            if twoCaptures && m.numberOfRanges >= 3 {
                let original  = ns.substring(with: m.range(at: 1))
                let corrected = ns.substring(with: m.range(at: 2))
                return DetectedCorrection(originalPhrase: original, correctedIntentHint: corrected, wasNegation: isNeg)
            } else if !twoCaptures && m.numberOfRanges >= 2 {
                let corrected = ns.substring(with: m.range(at: 1))
                return DetectedCorrection(originalPhrase: lastTranscript, correctedIntentHint: corrected, wasNegation: isNeg)
            }
        }
        return nil
    }
}
