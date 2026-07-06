package com.jarvis.assistant.voice.piper

import android.content.Context
import android.util.Log
import com.jarvis.assistant.voice.piper.g2p.EnglishG2P
import com.jarvis.assistant.voice.piper.textnorm.TextNormalizer

/**
 * SherpaPiperPhonemizer — production [PiperPhonemizer] that runs the
 * normalize-then-G2P pipeline and looks the resulting IPA phonemes up in
 * the voice's [PiperVoiceConfig.phonemeIdMap].
 */
class SherpaPiperPhonemizer(private val context: Context) : PiperPhonemizer {

    companion object {
        private const val TAG = "SherpaPiperPhonemizer"
        private const val LOG_VERBOSE_TEXT: Boolean = true
        const val MIN_MAPPING_SUCCESS_PERCENT: Int = 70
        private const val MAX_UNKNOWN_SAMPLES_LOGGED: Int = 8
    }

    override val name: String = "kotlin-en-gb-g2p"

    override val isAvailable: Boolean = true

    /** Last normalized text fed to G2P — populated after each [textToPhonemeIds] call. */
    @Volatile var lastNormalizedText: String = ""

    /** Last per-sentence phoneme lists produced by G2P — populated after each call. */
    @Volatile var lastPhonemes: List<List<String>> = emptyList()

    override fun textToPhonemeIds(
        text: String,
        config: PiperVoiceConfig,
    ): List<List<Int>> {
        if (text.isBlank()) return emptyList()
        
        val normalized = try {
            TextNormalizer.normalize(text)
        } catch (e: Exception) {
            return emptyList()
        }
        if (normalized.isBlank()) return emptyList()

        lastNormalizedText = normalized

        val sentencePhonemes: List<List<String>> = try {
            EnglishG2P.phonemize(normalized)
        } catch (e: Exception) {
            return emptyList()
        }

        lastPhonemes = sentencePhonemes
        
        val totalPhonemes = sentencePhonemes.sumOf { it.size }
        if (totalPhonemes == 0) return emptyList()

        val idMap = config.phonemeIdMap ?: return emptyList()

        var skipped = 0
        var processedCount = 0
        val unknownSamples = LinkedHashSet<String>()
        val idsPerSentence: List<List<Int>> = sentencePhonemes.map { phs ->
            val ids = ArrayList<Int>(phs.size * 4)
            for (rawPh in phs) {
                // Fix for missing phoneme mappings in jarvis-medium.onnx
                val ph = when (rawPh) {
                    "r" -> "ɹ"
                    "g" -> "ɡ"
                    else -> rawPh
                }

                val nfd = java.text.Normalizer.normalize(ph, java.text.Normalizer.Form.NFD)
                val exactMatch = idMap[nfd] ?: idMap[ph]
                if (exactMatch != null) {
                    ids.addAll(exactMatch)
                    processedCount++
                    continue
                }

                var cpIdx = 0
                while (cpIdx < nfd.length) {
                    val cp = nfd.codePointAt(cpIdx)
                    val token = String(Character.toChars(cp))
                    processedCount++
                    val mapped = idMap[token]
                    if (mapped == null) {
                        skipped++
                        unknownSamples.add(token)
                    } else {
                        ids.addAll(mapped)
                    }
                    cpIdx += Character.charCount(cp)
                }
            }
            ids
        }.filter { it.isNotEmpty() }

        val mapped = processedCount - skipped
        val successPercent = if (processedCount <= 0) 0
            else ((mapped.toLong() * 100L) / processedCount.toLong()).toInt()

        val aborted = processedCount > 0 && successPercent < MIN_MAPPING_SUCCESS_PERCENT
        PiperDiagnostics.update { snap ->
            snap.copy(
                phonemeMappingSuccessPercent       = successPercent,
                phonemeMappingAbortedLowCoverage   = aborted,
                lastPhonemeIdSkips                 = skipped,
            )
        }
        if (aborted) {
            return emptyList()
        }
        return idsPerSentence
    }
}
