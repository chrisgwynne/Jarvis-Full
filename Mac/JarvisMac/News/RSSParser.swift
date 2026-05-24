import Foundation

// MARK: - SAX delegate

private final class FeedParserDelegate: NSObject, XMLParserDelegate {

    // Output
    var items: [ParsedFeedItem] = []
    var feedTitle: String = ""

    // State
    private var currentElement = ""
    private var currentTitle = ""
    private var currentLink = ""
    private var currentDescription = ""
    private var currentPubDate: String = ""
    private var currentGuid = ""
    private var currentAuthor = ""
    private var inItem = false
    private var inEntry = false   // Atom
    private var buffer = ""
    private var isAtom = false

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName: String?,
                attributes: [String: String]) {
        currentElement = elementName.lowercased()
        buffer = ""

        switch currentElement {
        case "item":
            inItem = true
            resetCurrentItem()
        case "entry":
            inEntry = true
            isAtom = true
            resetCurrentItem()
        case "link":
            // Atom <link href="..."> self-closing
            if isAtom, let href = attributes["href"], !href.isEmpty {
                currentLink = href
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser,
                foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser,
                foundCDATA CDATABlock: Data) {
        buffer += String(data: CDATABlock, encoding: .utf8) ?? ""
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName: String?) {
        let el = elementName.lowercased()
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)

        if inItem || inEntry {
            switch el {
            case "title":       currentTitle = text
            case "link":        if !isAtom { currentLink = text } // RSS <link>
            case "description", "summary", "content", "content:encoded":
                if currentDescription.isEmpty { currentDescription = text }
            case "pubdate", "published", "updated", "dc:date":
                if currentPubDate.isEmpty { currentPubDate = text }
            case "guid", "id":  currentGuid = text
            case "author", "dc:creator", "name":
                if currentAuthor.isEmpty { currentAuthor = text }
            case "item", "entry":
                let parsed = ParsedFeedItem(
                    title: currentTitle,
                    link: currentLink,
                    description: stripHTML(currentDescription),
                    pubDate: parseDate(currentPubDate),
                    guid: currentGuid.isEmpty ? currentLink : currentGuid,
                    author: currentAuthor
                )
                if !parsed.title.isEmpty || !parsed.link.isEmpty {
                    items.append(parsed)
                }
                inItem = false
                inEntry = false
            default:
                break
            }
        } else {
            if el == "title" && feedTitle.isEmpty {
                feedTitle = text
            }
        }

        buffer = ""
    }

    // MARK: - Helpers

    private func resetCurrentItem() {
        currentTitle = ""
        currentLink = ""
        currentDescription = ""
        currentPubDate = ""
        currentGuid = ""
        currentAuthor = ""
    }

    private func stripHTML(_ string: String) -> String {
        guard string.contains("<") else { return string }
        var result = ""
        var inTag = false
        for char in string {
            if char == "<" { inTag = true; continue }
            if char == ">" { inTag = false; continue }
            if !inTag { result.append(char) }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseDate(_ string: String) -> Date? {
        if string.isEmpty { return nil }
        let formatters: [DateFormatter] = [
            rfc2822Formatter,
            iso8601Formatter,
            rfc822Short,
        ]
        for f in formatters {
            if let d = f.date(from: string) { return d }
        }
        // ISO8601DateFormatter for Atom
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: string) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: string)
    }

    private lazy var rfc2822Formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f
    }()

    private lazy var iso8601Formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return f
    }()

    private lazy var rfc822Short: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "dd MMM yyyy HH:mm:ss Z"
        return f
    }()
}

// MARK: - Public parser

enum RSSParser {

    /// Parse `data` into an array of `ParsedFeedItem`.
    /// Handles RSS 2.0 and Atom 1.0.
    static func parse(data: Data) throws -> [ParsedFeedItem] {
        let delegate = FeedParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false

        guard parser.parse() else {
            let err = parser.parserError?.localizedDescription ?? "unknown XML error"
            throw RSSParserError.malformedXML(err)
        }

        return delegate.items
    }
}

enum RSSParserError: LocalizedError {
    case malformedXML(String)

    var errorDescription: String? {
        switch self {
        case .malformedXML(let msg): return "RSS parse error: \(msg)"
        }
    }
}
