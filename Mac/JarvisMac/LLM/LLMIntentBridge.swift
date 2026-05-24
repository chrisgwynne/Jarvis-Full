import Foundation

/// Wire format the LLM must produce. We strictly validate every field —
/// any unrecognised intent name falls through to `unknown` and any
/// "dangerous" intent is rejected outright. The LLM is a *suggester*,
/// not an executor.
struct LLMIntentJSON: Decodable {
    let intent: String
    let target: String?
    let entities: [String: String]?
    let confidence: Double?
    let speak: String?
    let requiresConfirmation: Bool?
    let reason: String?

    // Conversational continuity fields.
    // When `awaitResponse == true` the controller enters `.awaitingResponse`
    // after TTS and listens for a follow-up without requiring the wake word.
    let awaitResponse: Bool?
    /// "yesNo" | "clarification" | "freeform"
    let pendingResponseType: String?
    /// What Jarvis says if the user replies positively (yesNo contexts).
    let pendingOnYes: String?
    /// What Jarvis says if the user replies negatively (yesNo contexts).
    let pendingOnNo: String?
}

enum LLMBridgeError: Error {
    case lowConfidence(LLMIntentJSON)
    case blockedAction(String)
    case unmapped(LLMIntentJSON)
    case parseFailed(String)
}

/// Parses the LLM response and maps to a local `Intent`. Centralises
/// the allowlist of LLM-routable intents so it's easy to audit what
/// the LLM is allowed to do.
enum LLMIntentBridge {

    /// Minimum confidence required to act without a clarifying question.
    static let confidenceFloor: Double = 0.70

    /// Allowed `intent` values from the LLM, mapped to local Intent cases
    /// (some require entities — handled in `intent(from:)`).
    /// Anything not in this map is treated as `unknown`.
    static let allowedIntents: Set<String> = [
        "show_news", "close_news", "summarise_news", "watch_news",
        "show_camera", "close_camera",
        "tell_time",
        "open_app",
        "show_dashboard", "focus_mode",
        "show_overlay", "close_overlay",
        "show_memory", "search_memory", "remember", "what_was_i_doing",
        "show_timeline", "what_did_i_do_today",
        "show_screen", "read_my_screen", "what_am_i_looking_at",
        "what_can_you_see",
        "repeat_last", "stop_talking", "status",
        "can_you_hear_me", "are_you_listening",
        "disable_listening", "enable_listening",
        "unknown"
    ]

    /// Hard-blocked actions — even if the LLM names them, the bridge
    /// refuses to map and logs `blocked_llm_action`.
    static let blockedActions: Set<String> = [
        "shell", "exec", "system_exec",
        "ssh", "sftp", "scp",
        "git_commit", "git_push", "git_force",
        "send_email", "send_message",
        "delete_file", "rm", "rmdir",
        "delete_memory", "wipe",
        "purchase", "buy", "transfer_money",
        "home_assistant_destructive",
    ]

    /// Parse the LLM's raw text into the JSON shape, tolerant of
    /// surrounding chatter ("Sure thing! Here is the JSON: …").
    static func parse(_ text: String) -> LLMIntentJSON? {
        guard let data = extractJSON(from: text) else { return nil }
        return try? JSONDecoder().decode(LLMIntentJSON.self, from: data)
    }

    /// Map a parsed JSON envelope to a local `Intent`, applying the
    /// allowlist + blocklist. Returns either a valid intent or a
    /// reason it was rejected.
    static func intent(from j: LLMIntentJSON) -> Result<Intent, LLMBridgeError> {
        // Block first.
        if blockedActions.contains(j.intent.lowercased()) {
            return .failure(.blockedAction(j.intent))
        }
        // Confidence gate.
        if let c = j.confidence, c < confidenceFloor, j.intent != "unknown" {
            return .failure(.lowConfidence(j))
        }
        // Allowlist check.
        if !allowedIntents.contains(j.intent) {
            return .failure(.unmapped(j))
        }

        let e = j.entities ?? [:]
        let target = (j.target ?? "").lowercased()

        switch j.intent {
        case "show_news":           return .success(.showNews)
        case "close_news":          return .success(.hideNews)
        case "summarise_news":      return .success(.summariseNews)
        case "watch_news":
            // Optional channel name in entities.
            if let ch = e["channel"], !ch.isEmpty {
                return .success(.watchNewsChannel(name: ch))
            }
            return .success(.watchNews)

        case "show_camera":         return .success(.showCameraOverlay)
        case "close_camera":        return .success(.hideCamera)
        case "what_can_you_see":    return .success(.whatCanYouSee)

        case "tell_time":           return .success(.tellTime)

        case "open_app":
            let name = (e["app"] ?? j.target ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return .failure(.unmapped(j)) }
            return .success(.openApp(name: name.capitalized))

        case "show_dashboard":      return .success(.dashboardMode)
        case "focus_mode":          return .success(.focusMode)

        case "show_overlay":
            switch target {
            case "news":      return .success(.showNews)
            case "camera":    return .success(.showCameraOverlay)
            case "memory":    return .success(.showMemoryOverlay)
            case "screen":    return .success(.showScreenOverlay)
            case "timeline":  return .success(.showTimeline)
            case "chat":      return .success(.showChat)
            case "test", "status": return .success(.showTestOverlay)
            default:          return .success(.showTestOverlay)
            }
        case "close_overlay":       return .success(.closeOverlay)

        case "show_memory":         return .success(.showMemoryOverlay)
        case "search_memory":
            let q = (e["query"] ?? e["q"] ?? j.target ?? "").trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { return .failure(.unmapped(j)) }
            return .success(.searchMemory(query: q))
        case "remember":
            let text = (e["text"] ?? e["note"] ?? j.target ?? "").trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return .failure(.unmapped(j)) }
            return .success(.rememberThis(text: text))
        case "what_was_i_doing":    return .success(.whatWasIDoingEarlier)

        case "show_timeline":       return .success(.showTimeline)
        case "what_did_i_do_today": return .success(.whatDidIDoToday)

        case "show_screen":         return .success(.showScreenOverlay)
        case "read_my_screen":      return .success(.readMyScreen)
        case "what_am_i_looking_at":return .success(.whatAmILookingAt)

        case "repeat_last":         return .success(.repeatLast)
        case "stop_talking":        return .success(.stopTalking)
        case "status":              return .success(.status)
        case "can_you_hear_me":     return .success(.canYouHearMe)
        case "are_you_listening":   return .success(.areYouListening)
        case "disable_listening":   return .success(.disableListening)
        case "enable_listening":    return .success(.enableListening)

        case "unknown":             return .failure(.unmapped(j))
        default:                    return .failure(.unmapped(j))
        }
    }

    // MARK: - Helpers

    /// Pull the first balanced `{ … }` block out of the LLM's text and
    /// return it as `Data`. Tolerates leading/trailing prose like
    /// "Sure: …" or markdown code fences.
    private static func extractJSON(from text: String) -> Data? {
        // Strip code fences.
        var t = text
        if let fenceStart = t.range(of: "```json")?.upperBound {
            t = String(t[fenceStart...])
        } else if let fenceStart = t.range(of: "```")?.upperBound {
            t = String(t[fenceStart...])
        }
        if let fenceEnd = t.range(of: "```")?.lowerBound {
            t = String(t[..<fenceEnd])
        }
        // Find the first balanced { … }.
        guard let open = t.firstIndex(of: "{") else { return nil }
        var depth = 0
        var endIdx: String.Index?
        var i = open
        while i < t.endIndex {
            let c = t[i]
            if c == "{" { depth += 1 }
            else if c == "}" {
                depth -= 1
                if depth == 0 { endIdx = i; break }
            }
            i = t.index(after: i)
        }
        guard let end = endIdx else { return nil }
        let slice = String(t[open...end])
        return slice.data(using: .utf8)
    }
}

// MARK: - Prompt template

enum LLMPrompts {
    /// System prompt the controller uses when asking the LLM to classify
    /// an unrouted command. Tight constraints + a literal JSON schema
    /// stop the model improvising free-form replies.
    static let intentClassifierSystem = """
    You are the reasoning layer for Jarvis, a macOS voice assistant.
    The user said something the deterministic router could not classify.
    Map the request to ONE of the intents below and reply with JSON ONLY.

    Allowed intents:
      show_news | close_news | summarise_news | watch_news
      show_camera | close_camera | what_can_you_see
      tell_time
      open_app                (requires entities.app, e.g. "Safari")
      show_dashboard | focus_mode
      show_overlay | close_overlay
      show_memory | search_memory | remember | what_was_i_doing
      what_do_you_remember
      show_timeline | what_did_i_do_today
      show_screen | read_my_screen | what_am_i_looking_at
      ask_my_name | ask_assistant_name | ask_personal_facts
      repeat_last | stop_talking | status
      can_you_hear_me | are_you_listening
      disable_listening | enable_listening
      unknown

    Reply with this exact JSON shape, no commentary, no markdown:
    {
      "intent": "<one of the above>",
      "target": "<noun this is about, may be empty>",
      "entities": { },
      "confidence": 0.0,
      "speak": "<short natural reply, <= 12 words>",
      "requiresConfirmation": false,
      "reason": "<= 20 word explanation>",
      "awaitResponse": false,
      "pendingResponseType": "",
      "pendingOnYes": "",
      "pendingOnNo": ""
    }

    Conversational continuity rules:
    - If the request cannot be fulfilled AND you want to offer an alternative
      or ask a clarifying question, set "awaitResponse": true so Jarvis
      listens for the reply WITHOUT requiring the wake word.
    - For yes/no questions set "pendingResponseType": "yesNo", put the
      "yes" reply in "pendingOnYes" and the "no" reply in "pendingOnNo"
      (both <= 10 words).
    - For clarification questions (e.g. "which app?") set
      "pendingResponseType": "clarification" — the follow-up will be
      re-routed to you with the full conversation context.
    - Example: user asks about weather (not supported):
      { "intent": "unknown", "confidence": 0.1,
        "speak": "I can't check weather yet. Should I note it for later?",
        "awaitResponse": true, "pendingResponseType": "yesNo",
        "pendingOnYes": "Noted. I'll add weather to the feature list.",
        "pendingOnNo": "No problem." }
    - Example: user asks to open an app but name is ambiguous:
      { "intent": "unknown", "confidence": 0.4,
        "speak": "Which browser did you mean?",
        "awaitResponse": true, "pendingResponseType": "clarification" }

    General rules:
    - If you are not sure and no follow-up is warranted, set "intent": "unknown"
      and put a brief clarifying question in "speak" (awaitResponse: false).
    - Never invent intents outside the list.
    - confidence must be between 0 and 1.
    - Do NOT include shell, file, email, network, or git operations
      under any circumstances.
    """
}
