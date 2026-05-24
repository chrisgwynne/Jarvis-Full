package com.jarvis.assistant.voice.piper.textnorm

/**
 * TextNormalizer — converts raw text into a spoken-readable form that the
 * G2P stage can phonemise without choking on digits, abbreviations, or
 * contractions.
 *
 * Pure functions; no I/O.  English-UK focused per the brief (en_GB Piper
 * voice).  Cheap enough to run on the IO dispatcher right before
 * phonemisation — typical message-length inputs (1-200 chars) run in
 * sub-millisecond time on a midrange phone.
 *
 * Design constraint: this is the FIRST text the user's words touch in the
 * Piper path, so it must not log content at INFO.  Only the post-normalised
 * length is reported, and only at DEBUG.
 */
object TextNormalizer {

    /** Normalise [raw] for downstream phonemisation. */
    fun normalize(raw: String): String {
        if (raw.isBlank()) return ""
        
        // MAC PARITY: Markdown stripping (via com.jarvis.assistant.runtime.ResponseFormatter equivalent)
        var s = stripMarkdown(raw).trim()

        // 1. Expand contractions BEFORE we touch punctuation
        s = expandContractions(s)

        // 2. Replace symbol shorthand.
        s = expandSymbols(s)
        
        // MAC PARITY: ALL CAPS expansion (spell it out)
        s = expandAllCaps(s)

        // 3. Expand titles + common abbreviations.
        s = expandAbbreviations(s)

        // 4. Expand digits to words.
        s = expandTimeOfDay(s)
        s = expandYears(s)
        s = expandOrdinals(s)
        s = expandStandaloneNumbers(s)

        // 5. Collapse repeated whitespace.
        s = s.replace(Regex("\\s+"), " ").trim()

        return s
    }

    private fun stripMarkdown(text: String): String {
        return text
            .replace(Regex("""```[\s\S]*?```"""), "") // Block code
            .replace(Regex("""`([^`]+)`"""), "$1")    // Inline code
            .replace(Regex("""\[([^\]]+)\]\([^\)]+\)"""), "$1") // Links
            .replace(Regex("""[*_]{1,3}([^*_]+)[*_]{1,3}"""), "$1") // Bold/Italic
            .replace(Regex("""#{1,6}\s+"""), "")      // Headers
            .replace(Regex(""">\s+"""), "")           // Quotes
            .replace(Regex("""^[-*+]\s+""", RegexOption.MULTILINE), "") // Lists
    }

    private fun expandAllCaps(text: String): String {
        // Expand sequences of 2+ capital letters to spaced-out letters (e.g. GA4 -> G A four)
        // Only if they aren't part of a word that is mixed case.
        val rx = Regex("""\b([A-Z]{2,})(\d*)\b""")
        return rx.replace(text) { result ->
            val letters = result.groupValues[1]
            val digits = result.groupValues[2]
            val expanded = letters.map { it.toString() }.joinToString(" ")
            if (digits.isNotEmpty()) "$expanded $digits" else expanded
        }
    }

    // ── Contractions ────────────────────────────────────────────────────────

    private val CONTRACTIONS: List<Pair<Regex, String>> = listOf(
        Regex("""\b(can)not\b""",        RegexOption.IGNORE_CASE) to "can not",
        Regex("""\b(can)'t\b""",         RegexOption.IGNORE_CASE) to "can not",
        Regex("""\b(won)'t\b""",         RegexOption.IGNORE_CASE) to "will not",
        Regex("""\b(shan)'t\b""",        RegexOption.IGNORE_CASE) to "shall not",
        Regex("""\b(\w+)n't\b""",        RegexOption.IGNORE_CASE) to "$1 not",
        Regex("""\b(i)'m\b""",           RegexOption.IGNORE_CASE) to "I am",
        Regex("""\b(\w+)'re\b""",        RegexOption.IGNORE_CASE) to "$1 are",
        Regex("""\b(\w+)'ve\b""",        RegexOption.IGNORE_CASE) to "$1 have",
        Regex("""\b(\w+)'ll\b""",        RegexOption.IGNORE_CASE) to "$1 will",
        Regex("""\b(\w+)'d\b""",         RegexOption.IGNORE_CASE) to "$1 would",
        Regex("""\b(it|he|she|that|what|who|where|when|how|there|here)'s\b""",
            RegexOption.IGNORE_CASE) to "$1 is",
        Regex("""\b(let)'s\b""",         RegexOption.IGNORE_CASE) to "$1 us",
        Regex("""\b(o)'clock\b""",       RegexOption.IGNORE_CASE) to "$1 clock",
    )

    private fun expandContractions(text: String): String {
        var s = text
        for ((rx, replacement) in CONTRACTIONS) {
            s = rx.replace(s, replacement)
        }
        return s
    }

    // ── Symbols + chat-isms ─────────────────────────────────────────────────

    private val SYMBOLS: List<Pair<Regex, String>> = listOf(
        Regex("""\s*&\s*""")        to " and ",
        Regex("""\s*@\s*""")        to " at ",
        Regex("""(\d)%""")          to "$1 percent",
        Regex("""£(\d+)""")         to "$1 pounds",
        Regex("""\$(\d+)""")        to "$1 dollars",
        Regex("""€(\d+)""")         to "$1 euros",
        Regex("""\s*\+\s*""")       to " plus ",
        Regex("""\s*=\s*""")        to " equals ",
        Regex("""\.{3,}""")         to ", ",   // ellipsis → short pause
        Regex("""\s*—\s*""")        to ", ",
        Regex("""\s*–\s*""")        to ", ",
        Regex("""[\"“”]""") to "",    // strip quotes; they confuse G2P
    )

    private fun expandSymbols(text: String): String {
        var s = text
        for ((rx, replacement) in SYMBOLS) {
            s = rx.replace(s, replacement)
        }
        return s
    }

    // ── Abbreviations ───────────────────────────────────────────────────────

    /**
     * Common honorifics + titles.  Lookups are case-insensitive but we keep
     * the original casing for downstream consistency.  Each entry includes
     * the period so we strip it cleanly.
     */
    private val ABBREVIATIONS: Map<String, String> = mapOf(
        "dr."    to "doctor",
        "dr"     to "doctor",
        "mr."    to "mister",
        "mr"     to "mister",
        "mrs."   to "missus",
        "mrs"    to "missus",
        "ms."    to "miss",
        "ms"     to "miss",
        "prof."  to "professor",
        "prof"   to "professor",
        "st."    to "saint",
        "rd."    to "road",
        "ave."   to "avenue",
        "blvd."  to "boulevard",
        "ln."    to "lane",
        "etc."   to "etcetera",
        "e.g."   to "for example",
        "i.e."   to "that is",
        "vs."    to "versus",
        "vs"     to "versus",
        "uk"     to "U K",
        "usa"    to "U S A",
        "u.k."   to "U K",
        "u.s."   to "U S",
        "u.s.a." to "U S A",
        "tv"     to "T V",
        "ai"     to "A I",
        "id"     to "I D",
        "ok"     to "okay",
    )

    private fun expandAbbreviations(text: String): String {
        // Replace whole-word matches only — preserves "stop", "drag" etc.
        val tokens = text.split(Regex("\\s+"))
        return tokens.joinToString(" ") { raw ->
            // 1. Try the raw token first.  Map entries that include a period
            //    ("dr.", "etc.", "u.k.") match here AND CONSUME the period —
            //    that's the desired behaviour for "Dr. Smith" → "doctor Smith".
            val rawLower = raw.lowercase()
            ABBREVIATIONS[rawLower]?.let { return@joinToString it }

            // 2. Fall back to stripped lookup with leading/trailing punctuation
            //    re-attached.  Used when the token has punctuation NOT part of
            //    the abbreviation (e.g. "Smith," or quoted forms).
            val leading  = raw.takeWhile { !it.isLetterOrDigit() }
            val trailing = raw.takeLastWhile { !it.isLetterOrDigit() }
            val core     = raw.substring(leading.length, raw.length - trailing.length)
            val replacement = ABBREVIATIONS[core.lowercase()]
            if (replacement != null) leading + replacement + trailing else raw
        }
    }

    // ── Time of day (HH:MM) ─────────────────────────────────────────────────

    private val TIME_RX = Regex("""\b(\d{1,2}):(\d{2})\b""")

    private fun expandTimeOfDay(text: String): String =
        TIME_RX.replace(text) { m ->
            val h = m.groupValues[1].toIntOrNull() ?: return@replace m.value
            val mm = m.groupValues[2].toIntOrNull() ?: return@replace m.value
            if (h !in 0..23 || mm !in 0..59) return@replace m.value
            val hourWord = numberToWords(h)
            val minuteWord = when {
                mm == 0 -> "o clock"
                mm < 10 -> "oh ${numberToWords(mm)}"
                else    -> numberToWords(mm)
            }
            "$hourWord $minuteWord"
        }

    // ── Years (1900-2099 typical conversational range) ──────────────────────

    private val YEAR_RX = Regex("""\b(19\d{2}|20\d{2})\b""")

    private fun expandYears(text: String): String =
        YEAR_RX.replace(text) { m ->
            val y = m.value.toInt()
            val first = y / 100
            val second = y % 100
            when {
                // 2000 / 1000 → "two thousand".  Round-millennium years are
                // spoken with the thousand form, not the century form
                // ("twenty hundred" is not English).
                y % 1000 == 0    -> "${numberToWords(y.toLong() / 1000)} thousand"
                // 2001–2009: "two thousand and N" reads more naturally than
                // "twenty oh N" for early-millennium years.
                first == 20 && second in 1..9 ->
                    "two thousand and ${numberToWords(second)}"
                second == 0      -> "${numberToWords(first)} hundred"
                second < 10      -> "${numberToWords(first)} oh ${numberToWords(second)}"
                else             -> "${numberToWords(first)} ${numberToWords(second)}"
            }
        }

    // ── Ordinals ────────────────────────────────────────────────────────────

    private val ORDINAL_RX = Regex("""\b(\d+)(st|nd|rd|th)\b""", RegexOption.IGNORE_CASE)
    
    private val ORDINALS_ONES = listOf("zeroth", "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth")
    private val ORDINALS_TEENS = listOf("tenth", "eleventh", "twelfth", "thirteenth", "fourteenth", "fifteenth", "sixteenth", "seventeenth", "eighteenth", "nineteenth")
    private val ORDINALS_TENS = listOf("", "", "twentieth", "thirtieth", "fortieth", "fiftieth", "sixtieth", "seventieth", "eightieth", "ninetieth")

    private fun expandOrdinals(text: String): String =
        ORDINAL_RX.replace(text) { m ->
            val numStr = m.groupValues[1]
            val n = numStr.toLongOrNull() ?: return@replace m.value
            
            // Fast paths for common ordinals < 100
            if (n < 10) return@replace ORDINALS_ONES[n.toInt()]
            if (n < 20) return@replace ORDINALS_TEENS[(n - 10).toInt()]
            if (n < 100) {
                val tens = (n / 10).toInt()
                val rem = (n % 10).toInt()
                if (rem == 0) return@replace ORDINALS_TENS[tens]
                return@replace "${TENS[tens]} ${ORDINALS_ONES[rem]}"
            }
            
            // For larger ordinals (100th, 21st, etc.), we reuse the cardinal logic
            // for the base part, and only make the LAST word ordinal.
            val baseWords = numberToWords(n).split(" ")
            if (baseWords.isEmpty()) return@replace m.value
            
            val lastWord = baseWords.last()
            val baseWithoutLast = baseWords.dropLast(1).joinToString(" ")
            
            // Convert just the last word to its ordinal form
            val ordinalLast = when (lastWord) {
                "one" -> "first"
                "two" -> "second"
                "three" -> "third"
                "five" -> "fifth"
                "eight" -> "eighth"
                "nine" -> "ninth"
                "twelve" -> "twelfth"
                "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety" -> 
                    lastWord.dropLast(1) + "ieth"
                else -> lastWord + "th"
            }
            
            if (baseWithoutLast.isEmpty()) ordinalLast else "$baseWithoutLast $ordinalLast"
        }

    // ── Standalone numbers ──────────────────────────────────────────────────

    private val NUMBER_RX = Regex("""\b-?\d{1,9}(?:\.\d+)?\b""")

    private fun expandStandaloneNumbers(text: String): String =
        NUMBER_RX.replace(text) { m ->
            val v = m.value
            val isNegative = v.startsWith("-")
            val abs = if (isNegative) v.substring(1) else v
            val asLong = abs.toLongOrNull()
            if (asLong != null) {
                val w = numberToWords(asLong)
                if (isNegative) "minus $w" else w
            } else {
                // Decimal — "1.5" → "one point five"
                val parts = abs.split(".")
                if (parts.size != 2) return@replace v
                val intPart  = parts[0].toLongOrNull() ?: return@replace v
                val fracPart = parts[1]
                val intWords = numberToWords(intPart)
                val fracWords = fracPart.map { ch -> digitWord(ch.digitToIntOrNull() ?: return@replace v) }
                    .joinToString(" ")
                val sign = if (isNegative) "minus " else ""
                "$sign$intWords point $fracWords"
            }
        }

    // ── Number → words ──────────────────────────────────────────────────────

    private val ONES = listOf("zero","one","two","three","four","five","six","seven","eight","nine")
    private val TEENS = listOf("ten","eleven","twelve","thirteen","fourteen","fifteen","sixteen",
                               "seventeen","eighteen","nineteen")
    private val TENS  = listOf("","","twenty","thirty","forty","fifty","sixty","seventy","eighty","ninety")

    private fun digitWord(d: Int): String = ONES[d.coerceIn(0, 9)]

    fun numberToWords(n: Int): String = numberToWords(n.toLong())

    /**
     * Convert [n] to English words.  Supports negatives and up to a billion
     * — anything larger reads as digit-by-digit.
     */
    fun numberToWords(n: Long): String {
        if (n < 0) return "minus " + numberToWords(-n)
        return when {
            n < 10              -> ONES[n.toInt()]
            n < 20              -> TEENS[(n - 10).toInt()]
            n < 100             -> {
                val tens = (n / 10).toInt()
                val rem  = (n % 10).toInt()
                if (rem == 0) TENS[tens] else "${TENS[tens]} ${ONES[rem]}"
            }
            n < 1_000           -> {
                val hundreds = (n / 100).toInt()
                val rem      = n % 100
                if (rem == 0L) "${ONES[hundreds]} hundred"
                else "${ONES[hundreds]} hundred ${numberToWords(rem)}"
            }
            n < 1_000_000       -> {
                val thousands = n / 1_000
                val rem       = n % 1_000
                if (rem == 0L) "${numberToWords(thousands)} thousand"
                else "${numberToWords(thousands)} thousand ${numberToWords(rem)}"
            }
            n < 1_000_000_000   -> {
                val millions = n / 1_000_000
                val rem      = n % 1_000_000
                if (rem == 0L) "${numberToWords(millions)} million"
                else "${numberToWords(millions)} million ${numberToWords(rem)}"
            }
            else                -> {
                // Fall back to digit-by-digit for very large numbers.
                n.toString().map { digitWord(it.digitToInt()) }.joinToString(" ")
            }
        }
    }
}
