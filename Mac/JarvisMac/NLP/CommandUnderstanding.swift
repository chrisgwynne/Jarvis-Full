import Foundation

// MARK: - TranscriptNormalizer

/// Turns whatever the user said into a canonical lower-case command
/// string the rest of the pipeline can reason about. The output stays
/// in plain English ("show news", "close camera") so existing
/// substring-based router patterns keep working — we're not inventing
/// a DSL, we're cleaning up the human one.
enum TranscriptNormalizer {

    static func normalize(_ text: String) -> String {
        var t = text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".?!,;:"))

        // 1. Contractions → full forms (so "what's" becomes "what is",
        //    and downstream code only has to recognise one form).
        for (k, v) in contractions {
            t = t.replacingOccurrences(of: k, with: v)
        }

        // 2. Collapse internal whitespace and re-trim.
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        t = t.trimmingCharacters(in: .whitespaces)

        // 3. Wake-word prefix strip ("hey jarvis show news" → "show news").
        let wakes = ["hey jarvis", "ok jarvis", "okay jarvis", "jarvis,", "jarvis."]
        for w in wakes {
            if t.hasPrefix(w + " ") {
                t = String(t.dropFirst(w.count + 1))
                break
            }
            if t == w { return "" }
        }
        if t.hasPrefix("jarvis ") { t = String(t.dropFirst("jarvis ".count)) }
        if t == "jarvis" { return "" }

        // 4. Polite / filler prefixes, applied iteratively so stacked
        //    phrases like "could you please" both come off.
        for _ in 0..<3 {
            var changed = false
            for p in politePrefixes where t.hasPrefix(p) {
                t = String(t.dropFirst(p.count))
                changed = true
                break
            }
            if !changed { break }
        }

        // 5. Multi-word verb aliases — MUST run before we strip filler
        //    words like " me ", otherwise "show me" / "let me see" never
        //    line up with the canonical "show".
        for (old, new) in verbAliases {
            if t.hasPrefix(old) {
                t = new + String(t.dropFirst(old.count))
                break
            }
        }
        for (old, new) in verbAliases {
            t = t.replacingOccurrences(of: " " + old, with: " " + new)
        }

        // 6. "put X on" pattern — meaningfully different from "put on X".
        //    Translates "put the news on" → "watch the news" so the
        //    target token survives the filler strip in the next step.
        if t.hasPrefix("put ") && t.hasSuffix(" on") {
            let mid = String(t.dropFirst("put ".count).dropLast(" on".count))
                .trimmingCharacters(in: .whitespaces)
            if !mid.isEmpty { t = "watch " + mid }
        }

        // 7. Mid-sentence filler words — "the", "a", "an", "my", etc.
        //    Note: spaces on both sides so we only catch them as separate
        //    words ("amber" must NOT become "anber").
        for f in midSentenceFillers {
            t = t.replacingOccurrences(of: f, with: " ")
        }
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }

        // 8. Trailing polite / colloquial fragments.
        for trail in [" please", " thanks", " thank you", " for me",
                      " for us", " right now", " now", " quickly", " mate"] {
            if t.hasSuffix(trail) { t = String(t.dropLast(trail.count)) }
        }

        return t.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Tables

    private static let contractions: [(String, String)] = [
        ("what's", "what is"),   ("whats", "what is"),
        ("what're", "what are"), ("how's", "how is"),  ("hows", "how is"),
        ("who's", "who is"),     ("whos", "who is"),
        ("there's", "there is"), ("theres", "there is"),
        ("it's", "it is"),
        ("don't", "do not"),     ("dont", "do not"),
        ("won't", "will not"),   ("wont", "will not"),
        ("can't", "can not"),    ("cant", "can not"),
        ("couldn't", "could not"), ("couldnt", "could not"),
        ("wouldn't", "would not"), ("wouldnt", "would not"),
        ("shouldn't", "should not"), ("shouldnt", "should not"),
        ("i'm", "i am"),
        ("you're", "you are"),   ("youre", "you are"),
        ("we're", "we are"),     ("they're", "they are"),
        ("i've", "i have"),      ("you've", "you have"),
        ("we've", "we have"),    ("they've", "they have"),
        ("i'd", "i would"),      ("you'd", "you would"),
        ("we'd", "we would"),    ("they'd", "they would"),
        ("i'll", "i will"),      ("you'll", "you will"),
        ("we'll", "we will"),    ("they'll", "they will"),
    ]

    private static let politePrefixes: [String] = [
        "please ",
        "can you please ",
        "could you please ",
        "would you please ",
        "please can you ",
        "please could you ",
        "can you ",
        "could you ",
        "would you ",
        "would you mind ",
        "can i ",
        "could i ",
        "may i ",
        "i want to ",
        "i would like to ",
        "i wanna ",
        "go ahead and ",
        "go on and ",
    ]

    /// Phrase-level rewrites that align varying English forms to a single
    /// canonical verb. Order is significant — longer phrases first.
    private static let verbAliases: [(String, String)] = [
        ("show me ", "show "),
        ("let me see ", "show "),
        ("can i see ", "show "),
        ("bring up ", "show "),
        ("pull up ", "show "),
        ("display ", "show "),
        ("get rid of ", "close "),
        ("take down ", "close "),
        ("turn off ", "close "),
        ("make this bigger", "maximise overlay"),
        ("make that bigger", "maximise overlay"),
        ("make it bigger", "maximise overlay"),
        ("make this smaller", "minimise overlay"),
        ("make that smaller", "minimise overlay"),
        ("make it smaller", "minimise overlay"),
        ("tell me ", "tell "),  // "tell me the time" → "tell time" later
    ]

    private static let midSentenceFillers: [String] = [
        " the ", " a ", " an ",
        " my ", " our ", " your ",
        " just ", " quickly",
        " for me", " for us",
        " right now",
    ]
}

// MARK: - CommandAction / CommandTarget

enum CommandAction: String, Codable, Equatable {
    case show       // show, open, display (canonical)
    case close      // close, hide, dismiss
    case watch      // watch, play (live video / channels)
    case summarise  // summarise / summarize / read
    case stop       // stop talking / stop listening
    case repeatLast // repeat / say again
    case switchTo   // switch / change channel
    case maximise   // make bigger / fullscreen
    case minimise   // make smaller / shrink
    case ask        // catch-all interrogative (what / how / tell)
}

/// Coarse target of the command. `label` is filled when the target
/// has a name (app, channel). Everything else uses `kind` only.
struct CommandTarget: Equatable, Codable {
    enum Kind: String, Codable {
        case news, camera, dashboard, orbMode
        case time, status
        case article, overlay
        case timeline, memory, screen, chat
        case test, headlines
        case channel, app, hearing, listeningState
        case calendar, tasks
        case unknown
    }
    let kind: Kind
    let label: String?

    static let news        = CommandTarget(kind: .news,        label: nil)
    static let camera      = CommandTarget(kind: .camera,      label: nil)
    static let dashboard   = CommandTarget(kind: .dashboard,   label: nil)
    static let orbMode     = CommandTarget(kind: .orbMode,     label: nil)
    static let time        = CommandTarget(kind: .time,        label: nil)
    static let status      = CommandTarget(kind: .status,      label: nil)
    static let article     = CommandTarget(kind: .article,     label: nil)
    static let overlay     = CommandTarget(kind: .overlay,     label: nil)
    static let timeline    = CommandTarget(kind: .timeline,    label: nil)
    static let memory      = CommandTarget(kind: .memory,      label: nil)
    static let screen      = CommandTarget(kind: .screen,      label: nil)
    static let chat        = CommandTarget(kind: .chat,        label: nil)
    static let test        = CommandTarget(kind: .test,        label: nil)
    static let headlines   = CommandTarget(kind: .headlines,   label: nil)
    static let hearing     = CommandTarget(kind: .hearing,     label: nil)
    static func channel(_ name: String) -> CommandTarget {
        CommandTarget(kind: .channel, label: name)
    }
    static func app(_ name: String) -> CommandTarget {
        CommandTarget(kind: .app, label: name)
    }
}

// MARK: - ParsedCommand

struct ParsedCommand: Equatable {
    let rawText: String
    let normalizedText: String
    let action: CommandAction?
    let target: CommandTarget?
    let modifiers: [String]
    let ordinal: Int?
    let confidence: Double
}

// MARK: - NaturalCommandParser

/// Walks the normalised transcript and pulls out a (verb, noun, ordinal)
/// triple. The IntentRouter then decides which concrete `Intent` matches.
enum NaturalCommandParser {

    static func parse(rawText: String, normalizedText: String) -> ParsedCommand {
        let t = normalizedText
        let action = detectAction(in: t)
        let (target, label) = detectTarget(in: t, action: action)
        let ordinal = detectOrdinal(in: t)
        let confidence = scoreConfidence(action: action, target: target,
                                         hasOrdinal: ordinal != nil)
        let resolved: CommandTarget?
        if let target {
            resolved = label.map { CommandTarget(kind: target, label: $0) }
                ?? CommandTarget(kind: target, label: nil)
        } else {
            resolved = nil
        }
        return ParsedCommand(
            rawText: rawText,
            normalizedText: t,
            action: action,
            target: resolved,
            modifiers: [],
            ordinal: ordinal,
            confidence: confidence
        )
    }

    // MARK: Action

    private static let actionVerbs: [(String, CommandAction)] = [
        // Multi-word forms first so longer prefixes win.
        ("maximise overlay", .maximise),
        ("minimise overlay", .minimise),
        ("show ", .show),
        ("open ", .show),
        ("close ", .close),
        ("hide ", .close),
        ("dismiss ", .close),
        ("watch ", .watch),
        ("play ", .watch),
        ("summarise ", .summarise),
        ("summarize ", .summarise),
        ("read ", .summarise),
        ("tell ", .ask),
        ("what ", .ask),
        ("how ", .ask),
        ("who ", .ask),
        ("when ", .ask),
        ("where ", .ask),
        ("stop ", .stop),
        ("repeat ", .repeatLast),
        ("switch ", .switchTo),
        ("change ", .switchTo),
        ("maximise ", .maximise),
        ("maximize ", .maximise),
        ("enlarge ", .maximise),
        ("minimise ", .minimise),
        ("minimize ", .minimise),
        ("shrink ", .minimise),
    ]

    private static func detectAction(in t: String) -> CommandAction? {
        for (prefix, action) in actionVerbs {
            if t.hasPrefix(prefix) || t == String(prefix.dropLast()) {
                return action
            }
        }
        // Standalone single-word commands.
        switch t {
        case "stop":   return .stop
        case "repeat": return .repeatLast
        case "next":   return .switchTo
        case "previous", "back": return .switchTo
        default: break
        }
        return nil
    }

    // MARK: Target

    private static func detectTarget(in t: String,
                                     action: CommandAction?) -> (CommandTarget.Kind?, String?) {
        // Hearing/listening sanity-check phrases.
        if t.contains("hear me") || t.contains("you listening")
            || t.contains("are you there") || t.contains("you awake") {
            return (.hearing, nil)
        }
        // Time queries — ask + time word.
        if t.contains("time") && !t.contains("timeline") { return (.time, nil) }
        if t.contains("headlines") { return (.headlines, nil) }
        // "news" as a standalone command or together with an explicit action verb.
        // A bare `t.contains("news")` would fire on conversational context such as
        // "you shouldn't be listening to the news when it's on" — which must never
        // route to the news overlay.  Require either an exact match, a news-prefixed
        // topic phrase, or an action verb being present alongside the word.
        if t == "news" || t.hasPrefix("news ") || (action != nil && t.contains("news")) {
            return (.news, nil)
        }
        if t.contains("camera")    { return (.camera, nil) }
        if t.contains("webcam")    { return (.camera, nil) }
        if t.contains("dashboard") || t.contains("diagnostics") {
            return (.dashboard, nil)
        }
        if t.contains("orb mode") || t.contains("focus mode")
            || t == "orb" || t == "focus" {
            return (.orbMode, nil)
        }
        if t.contains("article") || t.contains("story") || t.contains("link") {
            return (.article, nil)
        }
        if t.contains("timeline") { return (.timeline, nil) }
        if t.contains("memory") || t.contains("memories") { return (.memory, nil) }
        if t.contains("screen")   { return (.screen, nil) }
        if t.contains("chat") || t.contains("transcript") { return (.chat, nil) }
        if t.contains("calendar") || t.contains("events") { return (.calendar, nil) }
        if t.contains("tasks") || t.contains("todoist") || t.contains("task list") { return (.tasks, nil) }
        if t == "status" || t.contains("system status") || t.contains("status overlay") {
            return (.status, nil)
        }
        if t.contains("test overlay") { return (.test, nil) }
        if t == "that" || t == "this"
            || t.contains("overlay") || t.contains("popup") {
            return (.overlay, nil)
        }

        // "watch BLOOMBERG" — the action is watch and what follows is a
        // channel name. Same for "show Sky News".
        if action == .watch || action == .switchTo {
            // Strip the verb prefix to isolate the name.
            for (prefix, _) in actionVerbs {
                if t.hasPrefix(prefix) {
                    let rest = String(t.dropFirst(prefix.count))
                        .trimmingCharacters(in: .whitespaces)
                    if !rest.isEmpty && rest.split(separator: " ").count <= 4 {
                        return (.channel, rest)
                    }
                }
            }
        }

        // App targets: "open safari", "launch chrome".
        let apps = ["safari", "chrome", "finder", "terminal", "mail",
                    "messages", "calendar", "notes", "reminders", "music",
                    "photos", "preview", "slack", "spotify", "xcode",
                    "settings", "system settings", "system preferences"]
        for a in apps where t.contains(a) {
            return (.app, a.capitalized)
        }

        return (nil, nil)
    }

    // MARK: Ordinal

    private static let wordToNumber: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5,
        "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10,
    ]

    private static func detectOrdinal(in t: String) -> Int? {
        // 1) After "story"/"article"/"headline".
        for marker in ["story ", "article ", "headline "] {
            if let r = t.range(of: marker) {
                let after = String(t[r.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                let first = after.split(separator: " ").first.map(String.init) ?? ""
                let cleaned = first.trimmingCharacters(in: CharacterSet.decimalDigits.inverted)
                if let n = Int(cleaned), n > 0 { return n }
                if let n = wordToNumber[first] { return n }
            }
        }
        // 2) "first story" form (e.g. "open the first story").
        for (word, n) in wordToNumber where t.contains(word + " story")
            || t.contains(word + " article") || t.contains(word + " headline") {
            return n
        }
        return nil
    }

    // MARK: Confidence

    private static func scoreConfidence(action: CommandAction?,
                                        target: CommandTarget.Kind?,
                                        hasOrdinal: Bool) -> Double {
        var s = 0.0
        if action != nil { s += 0.45 }
        if target != nil { s += 0.45 }
        if hasOrdinal    { s += 0.10 }
        return min(s, 1.0)
    }
}
