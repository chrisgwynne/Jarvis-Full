import Foundation
import NaturalLanguage

// MARK: - ConversationEntityExtractor

@MainActor
final class ConversationEntityExtractor {

    static let shared = ConversationEntityExtractor()

    private let tagger = NLTagger(tagSchemes: [.nameType])

    // MARK: - Extract from turn

    func extract(from transcript: String, source: EntitySource, deviceId: String? = nil) -> [EntityMemNode] {
        var nodes: [EntityMemNode] = []
        nodes += nerEntities(from: transcript, source: source)
        nodes += patternEntities(from: transcript, source: source)
        if let deviceId {
            for i in 0..<nodes.count { nodes[i].associatedDevices = [deviceId] }
        }
        return nodes
    }

    // MARK: - Reference phrase detection

    func detectReferencePhrase(in normalized: String) -> ReferencePhrase? {
        let lower = normalized.lowercased()

        if lower.hasPrefix("do that again") || lower.hasPrefix("repeat that") ||
           lower.hasPrefix("do it again") || lower == "again" ||
           lower.hasPrefix("continue") || lower.hasPrefix("keep going") ||
           lower.hasPrefix("carry on") || lower.hasPrefix("resume") {
            return ReferencePhrase(text: lower, kind: .continual)
        }

        if lower.contains("on windows") || lower.contains("from the other") ||
           lower.contains("from windows") || lower.contains("other machine") ||
           lower.contains("other device") {
            return ReferencePhrase(text: lower, kind: .crossDevice)
        }

        if lower.contains("the other one") || lower.contains("the last one") ||
           lower.contains("that thing") || lower.contains("the other pr") ||
           lower.contains("the other issue") || lower.contains("the other tab") ||
           lower.contains("the previous") {
            return ReferencePhrase(text: lower, kind: .recency)
        }

        if lower.contains("that button") || lower.contains("that field") ||
           lower.contains("that window") || lower.contains("that section") ||
           lower.contains("the button") || lower.contains("the field") ||
           lower.contains("the window") || lower.contains("that element") {
            return ReferencePhrase(text: lower, kind: .deictic)
        }

        let pronounPhrases = ["open it", "close it", "click it", "show it",
                              "do that", "use that", "take that", "send that",
                              "open that", "close that", "reply to it", "it"]
        if pronounPhrases.contains(where: { lower == $0 || lower.hasPrefix($0 + " ") }) {
            return ReferencePhrase(text: lower, kind: .pronoun)
        }

        return nil
    }

    // MARK: - NER

    private func nerEntities(from text: String, source: EntitySource) -> [EntityMemNode] {
        var results: [EntityMemNode] = []
        tagger.string = text
        let range = text.startIndex..<text.endIndex
        tagger.enumerateTags(
            in: range, unit: .word, scheme: .nameType,
            options: [.omitWhitespace, .omitPunctuation]
        ) { tag, tokenRange in
            guard let tag else { return true }
            let name = String(text[tokenRange])
            guard name.count > 2 else { return true }
            switch tag {
            case .personalName:
                results.append(EntityMemNode(entityKind: .person, canonicalName: name, source: source))
            default:
                break
            }
            return true
        }
        return results
    }

    // MARK: - Pattern matching

    private static let urlPattern = try! NSRegularExpression(pattern: #"https?://[^\s]+"#)
    private static let prPattern = try! NSRegularExpression(
        pattern: #"(?:PR|pull request)\s*#?(\d+)"#, options: .caseInsensitive)
    private static let issuePattern = try! NSRegularExpression(
        pattern: #"(?:issue|bug)\s*#?(\d+)"#, options: .caseInsensitive)
    private static let filePattern = try! NSRegularExpression(
        pattern: #"\b(\w+\.(swift|py|ts|tsx|js|jsx|kt|go|rs|rb|java|md|json|yaml|yml))\b"#,
        options: .caseInsensitive)

    private func patternEntities(from text: String, source: EntitySource) -> [EntityMemNode] {
        var results: [EntityMemNode] = []
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)

        for match in Self.urlPattern.matches(in: text, range: range) {
            let url = nsText.substring(with: match.range)
            results.append(EntityMemNode(entityKind: .url, canonicalName: url,
                                      source: source, metadata: ["url": url]))
        }
        for match in Self.prPattern.matches(in: text, range: range) {
            let num = nsText.substring(with: match.range(at: 1))
            results.append(EntityMemNode(entityKind: .pullRequest, canonicalName: "PR #\(num)",
                                      source: source, metadata: ["number": num]))
        }
        for match in Self.issuePattern.matches(in: text, range: range) {
            let num = nsText.substring(with: match.range(at: 1))
            results.append(EntityMemNode(entityKind: .githubIssue, canonicalName: "Issue #\(num)",
                                      source: source, metadata: ["number": num]))
        }
        for match in Self.filePattern.matches(in: text, range: range) {
            let name = nsText.substring(with: match.range(at: 1))
            results.append(EntityMemNode(entityKind: .file, canonicalName: name, source: source))
        }

        return results
    }
}
