# Piper TTS Parity Audit: Mac vs Android

**Date:** 2026-05-24  
**Mac pipeline:** Piper CLI subprocess (espeak-ng en-gb-x-rp)  
**Android pipeline:** In-process ONNX + Kotlin G2P  
**Voice model:** jarvis-medium.onnx (en_GB, 22050 Hz)

## Architecture Comparison

Mac delegates ALL text normalization and phonemization to the Piper CLI binary, which uses
espeak-ng internally. Android must replicate this in-process.

## Audit Table

| Area | Mac Behaviour | Android Behaviour | Mismatch | Severity | Fix Applied |
|------|--------------|-------------------|----------|----------|-------------|
| Model loading | Piper CLI subprocess | OnnxRuntime in-process | Architectural (unavoidable on Android) | None | N/A |
| ONNX session options | Piper CLI defaults (CPU) | CPUExecutionProvider, default opts | Matches | None | N/A |
| Input tensor: input | int64 [1, T] | int64 [1, T] via LongBuffer | Match | None | N/A |
| Input tensor: input_lengths | int64 [1] | int64 [1] via LongBuffer | Match | None | N/A |
| Input tensor: scales | float32 [3] | float32 [3] via FloatBuffer | Match | None | N/A |
| noise_scale | 0.667 (from config JSON) | 0.667 (from config JSON via Gson) | Match | None | N/A |
| length_scale | 1.15 (from config JSON) | 1.15 (from config JSON via Gson) | Match | None | N/A |
| noise_w | 0.8 (from config JSON) | 0.8 (from config JSON via Gson) | Match | None | N/A |
| BOS/PAD/EOS format | [BOS, PAD, ph, PAD, ..., PAD, EOS] | [BOS, PAD, ph, PAD, ..., PAD, EOS] | Match | None | N/A |
| Sample rate | 22050 (from config) | 22050 (from config) | Match | None | N/A |
| Speaker ID | Single speaker — no sid tensor | Single speaker — no sid tensor | Match | None | N/A |
| Phonemizer | espeak-ng en-gb-x-rp (full IPA) | Kotlin EnglishG2P (~200 words + letter rules) | **Critical** — wrong phonemes for unknown words | Critical | Expanded IRREGULARS by ~80 words |
| "th" digraph | ð or θ (espeak chooses contextually) | IRREGULARS correct for common words; letter rules always θ | Partial — high-freq words covered | Medium | N/A (covered by IRREGULARS) |
| Word-final "-er" | /ə/ (unstressed schwa) | /ɜː/ (wrong — ɜː is the stressed vowel in "her") | **Bug** — affects quarter, reminder, water, over, etc. | High | Fixed: word-final -er rule added to applyLetterRules |
| Past tense "-ed" | Correct voiced/voiceless/syllabic | Produces /ɛ d/ always | **Bug** — "turned" → "t ɜː n ɛ d" | High | Fixed: added common past tenses to IRREGULARS |
| British BATH vowel | /ɑː/ in bath/path/past/fast | /æ/ via letter rules | **Bug** — "past" → "p æ s t" | High | Fixed: BATH words added to IRREGULARS |
| "door", "floor" | /ɔː/ | /uː ɹ/ via oo+r letter rules | **Bug** | High | Fixed: added to IRREGULARS |
| "front" | /ʌ/ (British strut vowel) | /ɒ/ via letter rules | **Bug** | Medium | Fixed: added to IRREGULARS |
| "quarter" | /k w ɔː t ə/ | /k w ɑː t ɜː/ (wrong vowels) | **Bug** | High | Fixed: added to IRREGULARS |
| "reminder" | /ɹ ɪ m aɪ n d ə/ | /ɹ ɛ m ɪ n d ɜː/ (wrong) | **Bug** | High | Fixed: added to IRREGULARS |
| URL expansion | SpeechPreprocessor expands URLs | Not present | Gap | Medium | Added expandUrls() to TextNormalizer |
| Version numbers | SpeechPreprocessor expands v1.2.3 | Not present | Gap | Low | Added expandVersionNumbers() to TextNormalizer |
| Tech brand names | PronunciationDictionary (AI→A.I., ONNX→O.N.N.X., etc.) | Not present | Gap | Medium | Added expandTechBrands() to TextNormalizer |
| Contraction handling | espeak-ng handles implicitly | Explicit TextNormalizer.expandContractions() | Android is more explicit — safer | None | N/A |
| Number expansion | espeak-ng handles | TextNormalizer.expandStandaloneNumbers() | Both correct | None | N/A |
| PCM conversion | Piper CLI: peak normalize → int16 | Peak normalize (floor 0.01) → int16 | Match (0.01 floor prevents div/0) | None | N/A |
| Float to int16 scale | 32767 | 32767 | Match | None | N/A |
| Channel count | Mono | Mono | Match | None | N/A |
| Silence padding | None (WAV → AVAudioPlayer) | 20ms leading + 100ms trailing | Android addition for hardware spin-up | Low | N/A |
| Debug export | None | PiperTtsDebugExporter (new, disabled by default) | Android now has debug export | N/A | Added |
| Diagnostics exposure | N/A | SherpaPiperPhonemizer.lastNormalizedText / lastPhonemes | N/A | N/A | Added |
| espeak-ng | Used via Piper CLI | Data files present; EspeakNgPhonemizer interface defined | Disabled — pluggable interface exists | N/A | Interface documented |

## Test Phrase Analysis

### "Good evening, Chris."
- Mac: espeak-ng → ɡ ʊ d | iː v n ɪ ŋ | k ɹ ɪ s
- Android: IRREGULARS has "good"→"ɡ ʊ d", "evening"→"iː v n ɪ ŋ", "chris"→"k r ɪ s" (r→ɹ by SherpaPiperPhonemizer)
- **Result: Match ✓**

### "The front door is unlocked."
- Mac: espeak-ng → ð ə | f ɹ ʌ n t | d ɔː | ɪ z | ʌ n l ɒ k t
- Android before fix: "front"→"f ɹ ɒ n t" (wrong), "door"→"d uː ɹ" (wrong), "unlocked"→"ʌ n l ɒ k ɛ d" (wrong)
- Android after fix: "front"→"f ɹ ʌ n t" ✓, "door"→"d ɔː" ✓, "unlocked"→"ʌ n l ɒ k t" ✓
- **Result: Fixed ✓**

### "I've turned the living room lights on."
- TextNormalizer expands "I've" → "I have"
- Mac: espeak-ng handles "turned" → t ɜː n d
- Android before fix: "turned" → "t ɜː n ɛ d" (wrong)
- Android after fix: "turned" → "t ɜː n d" ✓
- **Result: Fixed ✓**

### "Your reminder is set for quarter past seven."
- Mac: espeak-ng → ɹ ɪ m aɪ n d ə | k w ɔː t ə | p ɑː s t
- Android before fix: "reminder"→wrong, "quarter"→wrong, "past"→"p æ s t"
- Android after fix: "reminder"→"ɹ ɪ m aɪ n d ə" ✓, "quarter"→"k w ɔː t ə" ✓, "past"→"p ɑː s t" ✓
- **Result: Fixed ✓**

### "I didn't catch that."
- TextNormalizer expands "didn't" → "did not"
- All words in IRREGULARS or produce correct phonemes via letter rules
- **Result: Match ✓**

### "WhatsApp message sent."
- "whatsapp" in IRREGULARS: "w ɒ t s æ p" ✓
- TextNormalizer TECH_BRANDS expands "WhatsApp" → "Whats App" before G2P
- "message" in IRREGULARS: "m ɛ s ɪ dʒ" ✓
- "sent" via letter rules: "s ɛ n t" ✓
- **Result: Match ✓**

### "The Mac brain is unavailable."
- "mac" via letter rules: "m æ k" ✓
- "brain" via letter rules: "b ɹ eɪ n" ✓
- "unavailable" added to IRREGULARS: "ʌ n ə v eɪ l ə b l" ✓
- **Result: Fixed ✓**

### "Running version v1.2.3 of the model."
- Before fix: "v1.2.3" was letter-ruled as garbage
- After fix: TextNormalizer.expandVersionNumbers → "version 1 point 2 point 3" ✓
- **Result: Fixed ✓**

### "Check github.com for updates."
- Before fix: "github.com" → G2P tried to phonemize the dot
- After fix: TextNormalizer.expandUrls → "github dot com" ✓
- **Result: Fixed ✓**

## Remaining Gap to True Mac Parity

The fundamental limitation is that Android cannot run espeak-ng as an embedded native library
without NDK compilation. The fixes applied here close the most audible gaps (common words) but
rare/technical vocabulary will still be mispronounced by the letter-rules fallback.

### To achieve true parity:
1. Compile espeak-ng for Android ABI (armeabi-v7a, arm64-v8a, x86_64) using NDK
2. Create JNI wrapper (`EspeakNgJni.kt` + `espeak_jni.cpp`)
3. Implement `EspeakNgPhonemizer` using the JNI wrapper
4. Wire into PiperVoiceManager via `installPhonemizer(EspeakNgPhonemizer(context))`

The `espeak-ng-data/` assets are already bundled — only the native library and JNI glue are missing.
The `EspeakNgPhonemizer` interface is already defined and accepts Context.

### Short-term workarounds already applied:
- Expanded IRREGULARS by ~80 words covering Jarvis domain vocabulary
- Fixed word-final "-er" letter rule to produce /ə/ (schwa) not /ɜː/
- Added BATH vowel split words (past, last, fast, path, bath, glass, etc.)
- Added common past tense forms with correct final consonant
- Added URL, version number, and tech brand normalization to TextNormalizer

### Monitoring coverage gaps:
- Enable `PiperTtsDebugExporter.enabled = true` in diagnostics screen
- Configure output via `PiperTtsDebugExporter.configure(dir)` (already wired in PiperVoiceManager)
- JSON exports reveal which phoneme IDs were skipped (unknown phonemes)
- Log unknown words at DEBUG level to identify vocabulary gaps
