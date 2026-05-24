package com.jarvis.assistant.voice.piper.g2p

/**
 * EnglishG2P — pragmatic rules-based grapheme-to-phoneme converter for
 * British English, producing IPA-ish phonemes compatible with the
 * espeak-ng phoneme set that mainline Piper voices were trained on.
 *
 * SCOPE + LIMITATIONS (documented honestly):
 *   - This is NOT espeak-ng.  It's a small dictionary of high-frequency
 *     irregular words + letter-pattern rules.  Common words sound
 *     reasonable; rare words can sound stilted or wrong.
 *   - The output is best-effort.  Any phoneme the model's
 *     [phoneme_id_map] doesn't recognise is silently skipped during
 *     id-mapping, so a partial result is still spoken.
 *   - For production-quality phonemisation, plug in espeak-ng-jni or
 *     a real sherpa-onnx phonemizer via [PiperPhonemizer].  The
 *     interface stays identical; only the implementation changes.
 *
 * Output format:
 *   - One phoneme per token, separated by ` ` in the returned String,
 *     or as a `List<String>` from [phonemize].
 *   - Per-sentence list when the input contains `.`, `!`, or `?`.
 *
 * Phoneme inventory chosen to match what en_GB Piper voices typically
 * carry in their phoneme_id_map.  Stress marks are NOT emitted (the
 * Piper model handles prosody on its own).
 */
object EnglishG2P {

    /**
     * Phonemise [text] (already normalised by TextNormalizer) into a list
     * of sentences, each a list of phoneme strings.  Empty list if [text]
     * has no phonemisable content.
     */
    fun phonemize(text: String): List<List<String>> {
        if (text.isBlank()) return emptyList()
        val sentences = splitSentences(text)
        val result = ArrayList<List<String>>(sentences.size)
        for (sentence in sentences) {
            val phonemes = ArrayList<String>(sentence.length)
            val words = sentence.split(Regex("\\s+")).filter { it.isNotBlank() }
            for ((index, word) in words.withIndex()) {
                // Lowercase only — DO NOT strip trailing punctuation here.
                // phonemizeWord owns trailing-punctuation handling so the
                // period / comma / question mark survives as its own phoneme
                // (Piper JSONs map these to short pauses).
                val lower = word.lowercase()
                if (lower.isBlank()) continue
                val wordPhonemes = phonemizeWord(lower)
                if (wordPhonemes.isEmpty()) continue
                phonemes.addAll(wordPhonemes)
                // Inter-word boundary marker (silence) — most Piper voices
                // accept ` ` (space) as a phoneme in their phoneme_id_map.
                if (index < words.size - 1) phonemes.add(" ")
            }
            if (phonemes.isNotEmpty()) result.add(phonemes)
        }
        return result
    }

    private fun splitSentences(text: String): List<String> {
        // Keep punctuation by splitting and re-emitting trailing markers
        // as their own short utterances when present.  Simple heuristic —
        // matches the Piper-standard sentence-level segmentation closely
        // enough for conversational TTS.
        return text.split(Regex("(?<=[.!?])\\s+")).filter { it.isNotBlank() }
    }

    private fun phonemizeWord(word: String): List<String> {
        // 1. Strip a trailing punctuation cluster so we phonemise the
        //    bare word, then re-emit punctuation as phonemes the Piper
        //    JSON typically maps to silence/pause.
        val trailing = word.takeLastWhile { it in ".!?,;:" }
        val core     = if (trailing.isEmpty()) word else word.dropLast(trailing.length)
        if (core.isEmpty()) return punctuationPhonemes(trailing)

        // 2. Dictionary lookup for irregular high-frequency words.
        IRREGULARS[core]?.let { return it.split(' ').filter { it.isNotEmpty() } + punctuationPhonemes(trailing) }

        // 3. Letter-rules fallback.
        return applyLetterRules(core) + punctuationPhonemes(trailing)
    }

    private fun punctuationPhonemes(punct: String): List<String> {
        if (punct.isEmpty()) return emptyList()
        // Output each punctuation char as its own phoneme — Piper JSONs
        // typically include `.`, `,`, `?`, `!` in their phoneme_id_map.
        return punct.map { it.toString() }
    }

    // ── Irregular high-frequency words ──────────────────────────────────────
    //
    // Hand-curated list of the most common English words whose
    // pronunciation can't be derived by simple letter rules.  Coverage
    // here directly determines how natural conversational TTS sounds —
    // these words make up the bulk of any utterance.
    //
    // Format: lowercase word → space-separated IPA phonemes.
    private val IRREGULARS: Map<String, String> = mapOf(
        // Articles / determiners
        "the" to "ð ə", "a" to "ə", "an" to "ə n", "this" to "ð ɪ s",
        "that" to "ð æ t", "these" to "ð iː z", "those" to "ð əʊ z",
        // Pronouns
        "i" to "aɪ", "you" to "j uː", "he" to "h iː", "she" to "ʃ iː",
        "it" to "ɪ t", "we" to "w iː", "they" to "ð eɪ",
        "me" to "m iː", "him" to "h ɪ m", "her" to "h ɜː",
        "us" to "ʌ s", "them" to "ð ɛ m",
        "my" to "m aɪ", "your" to "j ɔː", "his" to "h ɪ z",
        "our" to "aʊ ə", "their" to "ð eə",
        // Verbs (be, have, do)
        "is" to "ɪ z", "am" to "æ m", "are" to "ɑː", "was" to "w ɒ z",
        "were" to "w ɜː", "be" to "b iː", "been" to "b iː n",
        "have" to "h æ v", "has" to "h æ z", "had" to "h æ d",
        "do" to "d uː", "does" to "d ʌ z", "did" to "d ɪ d",
        // Modals
        "will" to "w ɪ l", "would" to "w ʊ d", "can" to "k æ n",
        "could" to "k ʊ d", "should" to "ʃ ʊ d", "may" to "m eɪ",
        "might" to "m aɪ t", "must" to "m ʌ s t",
        // Common verbs
        "go" to "ɡ əʊ", "going" to "ɡ əʊ ɪ ŋ", "went" to "w ɛ n t",
        "come" to "k ʌ m", "came" to "k eɪ m", "get" to "ɡ ɛ t",
        "got" to "ɡ ɒ t", "give" to "ɡ ɪ v", "gave" to "ɡ eɪ v",
        "take" to "t eɪ k", "took" to "t ʊ k",
        "make" to "m eɪ k", "made" to "m eɪ d",
        "see" to "s iː", "saw" to "s ɔː", "say" to "s eɪ", "said" to "s ɛ d",
        "know" to "n əʊ", "knew" to "n j uː", "think" to "θ ɪ ŋ k",
        "want" to "w ɒ n t", "need" to "n iː d",
        "tell" to "t ɛ l", "told" to "t əʊ l d",
        "ask" to "ɑː s k", "asked" to "ɑː s k t",
        "send" to "s ɛ n d", "sent" to "s ɛ n t",
        "listen" to "l ɪ s ə n", "listening" to "l ɪ s ə n ɪ ŋ", 
        "listened" to "l ɪ s ə n d", "listener" to "l ɪ s ə n ə",
        "open" to "əʊ p ə n", "close" to "k l əʊ z",
        "play" to "p l eɪ", "pause" to "p ɔː z", "stop" to "s t ɒ p",
        "start" to "s t ɑː t", "turn" to "t ɜː n",
        "call" to "k ɔː l", "calling" to "k ɔː l ɪ ŋ",
        "message" to "m ɛ s ɪ dʒ", "text" to "t ɛ k s t",
        // Prepositions
        "to" to "t uː", "of" to "ɒ v", "in" to "ɪ n", "on" to "ɒ n",
        "at" to "æ t", "by" to "b aɪ", "for" to "f ɔː",
        "with" to "w ɪ ð", "from" to "f r ɒ m", "about" to "ə b aʊ t",
        "into" to "ɪ n t uː", "over" to "əʊ v ə",
        // Conjunctions / particles
        "and" to "æ n d", "or" to "ɔː", "but" to "b ʌ t", "if" to "ɪ f",
        "so" to "s əʊ", "as" to "æ z", "than" to "ð æ n",
        "because" to "b ɪ k ɒ z",
        // Question words
        "what" to "w ɒ t", "when" to "w ɛ n", "where" to "w eə",
        "who" to "h uː", "why" to "w aɪ", "how" to "h aʊ",
        "which" to "w ɪ tʃ",
        // Answers
        "yes" to "j ɛ s", "yeah" to "j ɛ ə", "no" to "n əʊ",
        "okay" to "əʊ k eɪ", "ok" to "əʊ k eɪ", "alright" to "ɔː l r aɪ t",
        // Numbers (written form — TextNormalizer expands digits)
        "one" to "w ʌ n", "two" to "t uː", "three" to "θ r iː",
        "four" to "f ɔː", "five" to "f aɪ v", "six" to "s ɪ k s",
        "seven" to "s ɛ v ə n", "eight" to "eɪ t", "nine" to "n aɪ n",
        "ten" to "t ɛ n", "eleven" to "ɪ l ɛ v ə n", "twelve" to "t w ɛ l v",
        "thirteen" to "θ ɜː t iː n", "fourteen" to "f ɔː t iː n",
        "fifteen" to "f ɪ f t iː n", "sixteen" to "s ɪ k s t iː n",
        "seventeen" to "s ɛ v ə n t iː n", "eighteen" to "eɪ t iː n",
        "nineteen" to "n aɪ n t iː n", "twenty" to "t w ɛ n t i",
        "thirty" to "θ ɜː t i", "forty" to "f ɔː t i", "fifty" to "f ɪ f t i",
        "sixty" to "s ɪ k s t i", "seventy" to "s ɛ v ə n t i",
        "eighty" to "eɪ t i", "ninety" to "n aɪ n t i",
        "hundred" to "h ʌ n d r ɪ d", "thousand" to "θ aʊ z ə n d",
        "million" to "m ɪ l j ə n", "billion" to "b ɪ l j ə n",
        "zero" to "z ɪə r əʊ", "first" to "f ɜː s t", "second" to "s ɛ k ə n d",
        "third" to "θ ɜː d",
        // Time
        "today" to "t ə d eɪ", "tomorrow" to "t ə m ɒ r əʊ",
        "yesterday" to "j ɛ s t ə d eɪ", "now" to "n aʊ", "later" to "l eɪ t ə",
        "morning" to "m ɔː n ɪ ŋ", "evening" to "iː v n ɪ ŋ",
        "night" to "n aɪ t", "day" to "d eɪ", "week" to "w iː k",
        "month" to "m ʌ n θ", "year" to "j ɪə",
        "monday" to "m ʌ n d eɪ", "tuesday" to "t j uː z d eɪ",
        "wednesday" to "w ɛ n z d eɪ", "thursday" to "θ ɜː z d eɪ",
        "friday" to "f r aɪ d eɪ", "saturday" to "s æ t ə d eɪ",
        "sunday" to "s ʌ n d eɪ",
        // Identity / Jarvis-specific
        "jarvis" to "dʒ ɑː v ɪ s", "chris" to "k r ɪ s",
        "hello" to "h ɛ l əʊ", "hi" to "h aɪ", "hey" to "h eɪ",
        "thanks" to "θ æ ŋ k s", "thank" to "θ æ ŋ k",
        "please" to "p l iː z", "sorry" to "s ɒ r i",
        "good" to "ɡ ʊ d", "bad" to "b æ d", "great" to "ɡ r eɪ t",
        "fine" to "f aɪ n", "well" to "w ɛ l",
        // Tech / app names
        "spotify" to "s p ɒ t ɪ f aɪ", "youtube" to "j uː tj uː b",
        "google" to "ɡ uː ɡ ə l", "maps" to "m æ p s",
        "whatsapp" to "w ɒ t s æ p", "android" to "æ n d r ɔɪ d",
        "systems" to "s ɪ s t ə m z", "system" to "s ɪ s t ə m",
        "online" to "ɒ n l aɪ n", "offline" to "ɒ f l aɪ n",
        // Common adjectives
        "all" to "ɔː l", "every" to "ɛ v r i", "any" to "ɛ n i",
        "some" to "s ʌ m", "many" to "m ɛ n i", "much" to "m ʌ tʃ",
        "more" to "m ɔː", "most" to "m əʊ s t", "less" to "l ɛ s",
        "few" to "f j uː", "little" to "l ɪ t ə l", "big" to "b ɪ ɡ",
        "small" to "s m ɔː l", "old" to "əʊ l d", "new" to "n j uː",
        "right" to "r aɪ t", "left" to "l ɛ f t", "up" to "ʌ p",
        "down" to "d aʊ n",
        // Common nouns
        "thing" to "θ ɪ ŋ", "things" to "θ ɪ ŋ z",
        "people" to "p iː p ə l", "person" to "p ɜː s ə n",
        "place" to "p l eɪ s", "time" to "t aɪ m", "way" to "w eɪ",
        "home" to "h əʊ m", "work" to "w ɜː k", "house" to "h aʊ s",
        "phone" to "f əʊ n", "light" to "l aɪ t", "lights" to "l aɪ t s",
        "music" to "m j uː z ɪ k", "song" to "s ɒ ŋ", "voice" to "v ɔɪ s",
        "name" to "n eɪ m", "names" to "n eɪ m z",
        "doctor" to "d ɒ k t ə", "mister" to "m ɪ s t ə",
        "miss" to "m ɪ s", "missus" to "m ɪ s ɪ z",
    )

    // ── Letter rules ────────────────────────────────────────────────────────
    //
    // Applied left-to-right, greedy on longest digraph first.  Imperfect
    // by design — real English letter-to-sound is a deep system.  This is
    // the "make unknown words pronounceable" tier.
    private fun applyLetterRules(word: String): List<String> {
        val out = ArrayList<String>(word.length)
        var i = 0
        val n = word.length
        while (i < n) {
            // Try 3-letter combos first (tch, dge, igh, etc.)
            if (i + 3 <= n) {
                val tri = word.substring(i, i + 3)
                TRIGRAPHS[tri]?.let { ph ->
                    // Some entries encode multiple phonemes separated by space
                    // (e.g. "ure"→"j ʊə").  Split so each becomes its own
                    // token rather than producing a spurious pause mid-sound.
                    ph.split(' ').filter { it.isNotEmpty() }.forEach { out.add(it) }
                    i += 3
                    continue
                }
            }
            // 2-letter combos (digraphs)
            if (i + 2 <= n) {
                val di = word.substring(i, i + 2)
                DIGRAPHS[di]?.let { ph ->
                    // Same split logic — "qu"→"k w" must become ["k","w"].
                    ph.split(' ').filter { it.isNotEmpty() }.forEach { out.add(it) }
                    i += 2
                    continue
                }
            }
            // Single letter
            val ch = word[i]
            // Final-e is generally silent — skip when last letter of word
            // and previous letter was a consonant.
            if (ch == 'e' && i == n - 1 && i > 0 && word[i - 1] !in "aeiou") {
                i += 1
                continue
            }
            SINGLE_LETTERS[ch]?.let { ph ->
                // "x"→"k s": split here too.
                ph.split(' ').filter { it.isNotEmpty() }.forEach { out.add(it) }
            }
            i += 1
        }
        return out
    }

    private val TRIGRAPHS: Map<String, String> = mapOf(
        "tch" to "tʃ", "dge" to "dʒ", "igh" to "aɪ", "ear" to "ɪə",
        "air" to "eə", "are" to "eə", "ire" to "aɪ ə", "ure" to "j ʊə",
        "tio" to "ʃ ə", "ssi" to "ʃ", "cci" to "tʃ",
    )

    private val DIGRAPHS: Map<String, String> = mapOf(
        // Consonant digraphs
        "th" to "θ", "sh" to "ʃ", "ch" to "tʃ", "ph" to "f", "ng" to "ŋ",
        "ck" to "k", "qu" to "k w", "wh" to "w",
        // Silent letters
        "kn" to "n", "wr" to "r", "gn" to "n", "ps" to "s", "mn" to "m",
        // Vowel pairs
        "ee" to "iː", "ea" to "iː", "ie" to "iː", "ei" to "eɪ",
        "ai" to "eɪ", "ay" to "eɪ", "oa" to "əʊ", "ow" to "aʊ",
        "ou" to "aʊ", "oo" to "uː", "oi" to "ɔɪ", "oy" to "ɔɪ",
        "au" to "ɔː", "aw" to "ɔː", "ar" to "ɑː", "or" to "ɔː",
        "er" to "ɜː", "ir" to "ɜː", "ur" to "ɜː", "ue" to "uː",
    )

    private val SINGLE_LETTERS: Map<Char, String> = mapOf(
        'a' to "æ", 'b' to "b", 'c' to "k", 'd' to "d", 'e' to "ɛ",
        'f' to "f", 'g' to "ɡ", 'h' to "h", 'i' to "ɪ", 'j' to "dʒ",
        'k' to "k", 'l' to "l", 'm' to "m", 'n' to "n", 'o' to "ɒ",
        'p' to "p", 'q' to "k", 'r' to "r", 's' to "s", 't' to "t",
        'u' to "ʌ", 'v' to "v", 'w' to "w", 'x' to "k s", 'y' to "j",
        'z' to "z",
        '\'' to "",
    )
}
