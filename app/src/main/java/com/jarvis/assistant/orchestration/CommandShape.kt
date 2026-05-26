package com.jarvis.assistant.orchestration

/**
 * CommandShape — deterministic test for "does this utterance look like an
 * imperative command Jarvis should ROUTE TO A TOOL rather than treat as a
 * memory/preference statement?"
 *
 * Called by [JarvisRuntime] BEFORE [IntentClassifier] and
 * [com.jarvis.assistant.preferences.ResponsePreferenceEngine] so obvious
 * commands ("send a whatsapp to wifey", "directions to Sainsbury's",
 * "turn off the lights", "open Spotify") can never be swallowed by the
 * memory or preference handlers.
 *
 * False-positive cost: we'd skip a real memory/preference utterance that
 * happens to start with a command verb.  Mitigation: only fire on phrases
 * that are clearly imperatives with a recognised verb + complement shape;
 * pure information statements ("I prefer brief weather") never match.
 *
 * False-negative cost: a real command falls through to the LLM and gets
 * narrated as chat.  Mitigation: cover all the verbs the user listed in the
 * regression report — send/text/whatsapp/sms/message, call/dial/ring/phone,
 * open/launch/start, close/quit/kill/stop, play/pause/skip, turn (on|off),
 * navigate/drive/walk/take me/directions, set/start/cancel timer/reminder/
 * alarm, what's playing / where am I / how long.
 */
object CommandShape {

    /**
     * True when the utterance looks like an imperative command that should
     * route to a tool — i.e. memory + preference classifiers must skip it.
     */
    fun isImperativeCommand(utterance: String): Boolean {
        val lower = utterance.lowercase().trim()
        if (lower.isEmpty()) return false
        return IMPERATIVE_PATTERNS.any { it.containsMatchIn(lower) }
    }

    /**
     * Each pattern below anchors on the START of the utterance with a strong
     * verb + complement shape.  Anchoring on `^` keeps "I love sending
     * messages" from matching.  Patterns deliberately overlap so a single
     * miss still has fallbacks — coverage over minimalism.
     */
    private val IMPERATIVE_PATTERNS: List<Regex> = listOf(

        // ── Messaging ──────────────────────────────────────────────────────
        // send a whatsapp to X / send X a whatsapp / message X / text X /
        // whatsapp X / sms X / reply to X
        Regex(
            """^(?:please\s+)?send\s+(?:a\s+|an\s+|the\s+)?""" +
            """(?:whatsapp|whats[\s-]?app|wa|text|sms|message)\b""",
            RegexOption.IGNORE_CASE,
        ),
        Regex(
            """^(?:please\s+)?(?:message|text|whatsapp|whats[\s-]?app|wa|sms|email)\s+\S""",
            RegexOption.IGNORE_CASE,
        ),
        Regex(
            """^(?:please\s+)?reply\s+(?:to\s+|saying\s+)""",
            RegexOption.IGNORE_CASE,
        ),

        // ── Calls ─────────────────────────────────────────────────────────
        Regex(
            """^(?:please\s+)?(?:call|dial|ring|phone)\s+\S""",
            RegexOption.IGNORE_CASE,
        ),
        Regex(
            """^(?:please\s+)?(?:hang\s*up|end\s+(?:the\s+)?call)\b""",
            RegexOption.IGNORE_CASE,
        ),

        // ── Apps ──────────────────────────────────────────────────────────
        Regex(
            """^(?:please\s+)?(?:open|launch|start|run|fire\s+up)\s+\S""",
            RegexOption.IGNORE_CASE,
        ),
        Regex(
            """^(?:please\s+)?(?:close|shut|exit|dismiss|quit|kill)\s+\S""",
            RegexOption.IGNORE_CASE,
        ),
        Regex(
            """^(?:please\s+)?(?:switch\s+to|switch\s+back\s+to|go\s+back|go\s+home)\b""",
            RegexOption.IGNORE_CASE,
        ),

        // ── Media ─────────────────────────────────────────────────────────
        Regex(
            """^(?:please\s+)?(?:play|pause|resume|stop|skip|next|previous)\b""",
            RegexOption.IGNORE_CASE,
        ),
        Regex(
            """^(?:please\s+)?(?:turn\s+(?:up|down)\s+(?:the\s+)?volume|""" +
            """volume\s+(?:up|down|to|mute|unmute)|mute|unmute)\b""",
            RegexOption.IGNORE_CASE,
        ),
        Regex(
            """^(?:please\s+)?what(?:'s|\s+is)\s+(?:this\s+song|playing|on)\b""",
            RegexOption.IGNORE_CASE,
        ),

        // ── Smart home / lights / scenes ───────────────────────────────────
        Regex(
            """^(?:please\s+)?turn\s+(?:on|off|up|down)\b""",
            RegexOption.IGNORE_CASE,
        ),
        Regex(
            """^(?:please\s+)?(?:lights?|fan|tv|television|heating|aircon|air\s+con|thermostat)\s+""" +
            """(?:on|off|up|down|to)\b""",
            RegexOption.IGNORE_CASE,
        ),
        Regex(
            """^(?:please\s+)?(?:dim|brighten)\s+\S""",
            RegexOption.IGNORE_CASE,
        ),
        Regex(
            """^(?:please\s+)?(?:start|stop|pause|run)\s+(?:the\s+)?vacuum\b""",
            RegexOption.IGNORE_CASE,
        ),
        Regex(
            """^(?:please\s+)?(?:activate|trigger|run)\s+(?:the\s+)?(?:scene|routine)\b""",
            RegexOption.IGNORE_CASE,
        ),

        // ── Navigation / maps ──────────────────────────────────────────────
        Regex(
            """^(?:please\s+)?(?:navigate|drive|walk|cycle|run|head)\s+(?:to\s+|home|to\s+work)""",
            RegexOption.IGNORE_CASE,
        ),
        Regex(
            """^(?:please\s+)?(?:take|get)\s+me\s+(?:home|to\b|there)""",
            RegexOption.IGNORE_CASE,
        ),
        Regex(
            """^(?:please\s+)?(?:directions?|route|eta)\s+(?:to\s+|home|for\s+)""",
            RegexOption.IGNORE_CASE,
        ),
        Regex(
            """^(?:please\s+)?give\s+me\s+(?:directions?|the\s+route|the\s+eta|the\s+time)""",
            RegexOption.IGNORE_CASE,
        ),
        Regex(
            """^(?:please\s+)?how\s+long\s+(?:until|till|to\s+get|before)""",
            RegexOption.IGNORE_CASE,
        ),
        Regex(
            """^(?:please\s+)?where\s+(?:am\s+i|am\s+i\s+now)\b""",
            RegexOption.IGNORE_CASE,
        ),

        // ── Reminders / timers / alarms (these still go to IntentClassifier
        // for the actual handling — we don't skip them, only the preference
        // engine) — but include them so preferenceEngine doesn't catch them
        // via "tell me" patterns.
        Regex(
            """^(?:please\s+)?(?:remind\s+me|set\s+(?:a\s+)?reminder|set\s+(?:a\s+)?timer|""" +
            """set\s+(?:an\s+)?alarm|cancel\s+(?:the\s+)?(?:reminder|timer|alarm))\b""",
            RegexOption.IGNORE_CASE,
        ),

        // ── Device toggles ─────────────────────────────────────────────────
        Regex(
            """^(?:please\s+)?(?:flashlight|torch|brightness|do\s+not\s+disturb|dnd)\s+""" +
            """(?:on|off|up|down|to)\b""",
            RegexOption.IGNORE_CASE,
        ),
        Regex(
            """^(?:please\s+)?(?:take\s+a\s+(?:screenshot|photo|picture)|screenshot|rotate)\b""",
            RegexOption.IGNORE_CASE,
        ),

        // ── Tasks / lists ──────────────────────────────────────────────────
        Regex(
            """^(?:please\s+)?(?:add|create)\s+(?:a\s+)?(?:task|todo|to-do|reminder|note)\b""",
            RegexOption.IGNORE_CASE,
        ),
        Regex(
            """^(?:please\s+)?(?:complete|done|finish|tick\s+off|mark\s+(?:done|complete))\b""",
            RegexOption.IGNORE_CASE,
        ),
    )
}
