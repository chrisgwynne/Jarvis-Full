import Foundation

// MARK: - Built-in DocumentationContributors
//
// Each contributor reads live state from its dependency (PreferencesStore,
// AndroidBridgeManager, etc.) and returns a section that reflects what
// the user can ACTUALLY do right now.  Contributors that depend on a
// feature being enabled return `nil` when it isn't — and the engine then
// silently hides them.
//
// To add a new subsystem to the help system:
//   1. Add a new contributor class here (or in the subsystem's folder).
//   2. Register it from `JarvisController.registerBuiltInDocumentationContributors()`.
//   3. Done — the help overlay + conversational lookup pick it up.

// MARK: - GettingStartedContributor

/// Always-on overview.  Pure documentation, no live state.
@MainActor
final class GettingStartedContributor: DocumentationContributor {
    let id = "core.getting_started"
    func section() -> DocumentationSection? {
        DocumentationSection(
            id: id,
            category: .gettingStarted,
            title: "Getting Started",
            subtitle: "Jarvis listens for the wake word \"Jarvis\" and stays in conversation for up to ten minutes after you start talking.",
            bodyMarkdown: """
            Say "Jarvis" then a command.  Jarvis stays in a listening session for up \
            to ten minutes after your last utterance, so follow-up questions don't \
            need the wake word again.

            Three modes:

            * **Passive** — waiting for the wake word.
            * **Listening** — actively transcribing.
            * **Conversational** — armed for follow-ups.

            Say "stop listening" or "go quiet" to permanently end the session.
            """,
            examples: [
                .init(phrase: "Jarvis, what can you do",                   followUp: "show help"),
                .init(phrase: "Jarvis, show the news"),
                .init(phrase: "stop listening", kind: .commandPhrase),
            ],
            relatedSettings: ["Settings → Voice", "Settings → Wake Word"],
            status: .informational,
            searchTags: ["start", "begin", "intro", "overview", "wake"])
    }
}

// MARK: - WakeAndListeningContributor

@MainActor
final class WakeAndListeningContributor: DocumentationContributor {
    let id = "core.wake_listening"
    private let prefs: PreferencesStore
    init(prefs: PreferencesStore) { self.prefs = prefs }
    func section() -> DocumentationSection? {
        let engine = prefs.current.speechEngine == .apple
            ? "Apple Speech (cloud-assist)" : "Whisper (on-device)"
        let wakeOn = prefs.current.wakeWord.enabled
        return DocumentationSection(
            id: id,
            category: .wakeAndListening,
            title: "Wake Word & Listening",
            subtitle: "Wake word is currently \(wakeOn ? "ON" : "OFF").  Speech engine: \(engine).",
            bodyMarkdown: """
            Jarvis uses two listening pipelines:

            * **Wake word** — always-on, low-power.  Runs Sherpa-ONNX or Apple Speech in keyword-spotting mode.
            * **Command STT** — fires after the wake word, full transcription via \(engine).

            **Barge-in:** say "Jarvis" or "stop talking" while Jarvis is speaking to interrupt it.

            **Listening lifecycle:**
            * Wake → STT → command → either a deterministic action or an LLM answer.
            * Conversational mode stays armed for 10 minutes after each interaction.
            * 4 events end the session permanently: "stop listening", emergency stop, microphone loss, 10-minute idle.
            """,
            examples: [
                .init(phrase: "Jarvis"),
                .init(phrase: "stop listening"),
                .init(phrase: "go quiet"),
                .init(phrase: "are you listening"),
                .init(phrase: "stop talking", kind: .followUp),
            ],
            relatedSettings: ["Settings → Wake Word", "Settings → Voice"],
            status: wakeOn ? .enabled : .disabled,
            searchTags: ["wake", "listen", "barge", "interrupt", "stt", "whisper"])
    }
}

// MARK: - ConversationsContributor

@MainActor
final class ConversationsContributor: DocumentationContributor {
    let id = "core.conversations"
    func section() -> DocumentationSection? {
        DocumentationSection(
            id: id,
            category: .conversations,
            title: "Conversations",
            subtitle: "Jarvis tracks context across follow-ups — pronouns like \"it\" and \"him\" resolve against the most recent action.",
            bodyMarkdown: """
            After Jarvis does something, you can refer to it without naming it again.

            * After the camera describes the desk: **"what colour is it"**, **"describe it more"**.
            * After Mike calls: **"call him back"**, **"reply saying I'm busy"**.
            * After a file search: **"open the second one"**.
            * After a Shopify summary: **"which is urgent"**.

            Jarvis also remembers what it just answered, so you can ask **"tell me more about that"** \
            on top of any previous reply.
            """,
            examples: [
                .init(phrase: "what colour is it",   kind: .contextual),
                .init(phrase: "call him back",       kind: .contextual),
                .init(phrase: "open the second one", kind: .contextual),
                .init(phrase: "tell me more",        kind: .followUp),
                .init(phrase: "summarise that",      kind: .followUp),
            ],
            status: .informational,
            searchTags: ["follow", "pronoun", "context", "it", "that", "him", "her", "them"])
    }
}

// MARK: - AndroidIntegrationContributor

@MainActor
final class AndroidContributor: DocumentationContributor {
    let id = "android.integration"
    private let stateRef: () -> AndroidBridgeDiagnostics
    init(diagnostics: @escaping () -> AndroidBridgeDiagnostics) {
        self.stateRef = diagnostics
    }
    func section() -> DocumentationSection? {
        let diag = stateRef()
        let status: DocumentationStatus = diag.isConnected ? .enabled : .notConfigured
        let device = diag.deviceName.isEmpty ? "your phone" : diag.deviceName
        let subtitle: String
        if diag.isConnected {
            let batt = diag.batteryLevel >= 0 ? "\(diag.batteryLevel)%" : "unknown battery"
            subtitle = "\(device) is connected.  Battery \(batt)\(diag.isCharging == true ? ", charging" : "")."
        } else {
            subtitle = "Android phone is not connected.  Pair it via Settings → Network and run the Jarvis Android app."
        }
        let troubleshooting: [DocumentationTroubleshooting] = [
            DocumentationTroubleshooting(
                symptom: "Android integration is offline",
                cause: diag.isConnected ? nil : "No heartbeat received recently.",
                fix: "Open the Jarvis app on your phone and re-pair via Settings → Network.",
                isActive: !diag.isConnected),
            DocumentationTroubleshooting(
                symptom: "Calls don't connect",
                fix: "Grant the call-management permission in the Jarvis Android app.")
        ]
        return DocumentationSection(
            id: id,
            category: .androidIntegration,
            title: "Android Integration",
            subtitle: subtitle,
            bodyMarkdown: """
            Jarvis talks to your phone over a local WebSocket bridge so it can place \
            calls, send SMS / WhatsApp messages, read notifications, and report battery / signal.

            The phone authenticates with a shared token that's stored in the macOS Keychain.  \
            Every frame is auth-checked — both commands the Mac sends to the phone and events \
            the phone pushes back.

            **Status right now:** \(subtitle)
            """,
            examples: [
                .init(phrase: "what's the battery on my phone"),
                .init(phrase: "is my phone charging"),
                .init(phrase: "phone status"),
                .init(phrase: "is my phone online"),
                .init(phrase: "ring my phone"),
            ],
            relatedSettings: ["Settings → Integrations → Android",
                              "Developer → Brain API → Pairing"],
            requiredIntegrations: ["Jarvis Android app paired"],
            troubleshooting: troubleshooting,
            status: status,
            searchTags: ["phone", "android", "bridge", "pair", "battery", "charging"])
    }
}

// MARK: - CallsAndMessagingContributor

@MainActor
final class CallsAndMessagingContributor: DocumentationContributor {
    let id = "android.calls_messaging"
    private let stateRef: () -> AndroidBridgeDiagnostics
    init(diagnostics: @escaping () -> AndroidBridgeDiagnostics) {
        self.stateRef = diagnostics
    }
    func section() -> DocumentationSection? {
        let diag = stateRef()
        let status: DocumentationStatus = diag.isConnected ? .enabled : .notConfigured
        return DocumentationSection(
            id: id,
            category: .callsAndMessaging,
            title: "Calls & Messaging",
            subtitle: diag.isConnected
                ? "Calls + SMS + WhatsApp ready via your phone."
                : "Pair your Android phone first to enable calls and messaging.",
            bodyMarkdown: """
            All calls and messages route through your connected Android phone.  \
            Jarvis disambiguates contact names by asking you to pick one if multiple match.

            **Incoming calls** open the phone overlay with answer / decline / speaker / hang-up \
            controls — those buttons are clickable AND voice-driven.
            """,
            examples: [
                .init(phrase: "call Mike"),
                .init(phrase: "answer it",          kind: .contextual),
                .init(phrase: "decline it",         kind: .contextual),
                .init(phrase: "hang up",            kind: .followUp),
                .init(phrase: "text Sarah I'll be there in 10"),
                .init(phrase: "WhatsApp Cath asking what time"),
                .init(phrase: "call him back",      kind: .contextual,
                      followUp: "after a missed call notification"),
                .init(phrase: "reply saying yes",   kind: .contextual,
                      followUp: "after an SMS arrives"),
            ],
            requiredIntegrations: ["Jarvis Android app paired",
                                    "Phone-call permission granted on Android"],
            status: status,
            searchTags: ["call", "ring", "dial", "text", "sms", "whatsapp", "message"])
    }
}

// MARK: - CameraAndVisionContributor

@MainActor
final class CameraVisionContributor: DocumentationContributor {
    let id = "vision.camera"
    private let prefs: PreferencesStore
    init(prefs: PreferencesStore) { self.prefs = prefs }
    func section() -> DocumentationSection? {
        let cloudOn   = prefs.current.cloudVisionConsent
        let preferred = prefs.current.preferredVisionProviderRaw
        let status: DocumentationStatus =
            cloudOn ? .enabled : .degraded  // Apple Vision still works when cloud off
        let subtitle: String
        if cloudOn {
            subtitle = "Cloud vision is ON — preferred provider: \(preferred).  Falls back to on-device Apple Vision."
        } else {
            subtitle = "Cloud vision is OFF — Jarvis only uses on-device Apple Vision.  Enable cloud vision in Settings → Vision to use MiniMax or Gemini."
        }
        return DocumentationSection(
            id: id,
            category: .cameraAndVision,
            title: "Camera & Vision",
            subtitle: subtitle,
            bodyMarkdown: """
            Ask Jarvis what it sees.  Two pipelines:

            * **User-facing description** — "what do you see" routes through your preferred cloud provider (or Apple Vision fallback).
            * **Background watch** — periodic frame analysis runs through the local Vision model only.

            Privacy: **no camera frame ever leaves the machine** unless you explicitly enable \
            cloud-vision consent in Settings → Vision.  When that's off, all responses come from on-device Apple Vision.
            """,
            examples: [
                .init(phrase: "what do you see"),
                .init(phrase: "what can you see"),
                .init(phrase: "describe the room"),
                .init(phrase: "what's on my desk"),
                .init(phrase: "read this"),
                .init(phrase: "what colour is it", kind: .contextual),
            ],
            relatedSettings: ["Settings → Vision",
                              "Settings → Vision → Cloud-vision consent"],
            limitations: [
                "Apple Vision can detect text and people but can't describe objects without a cloud provider.",
                "Cloud vision requires either MiniMax or Gemini to be configured."
            ],
            status: status,
            searchTags: ["camera", "vision", "see", "look", "describe", "view", "ocr", "read"])
    }
}

// MARK: - AIProvidersContributor

@MainActor
final class AIProvidersContributor: DocumentationContributor {
    let id = "ai.providers"
    private let prefs: PreferencesStore
    init(prefs: PreferencesStore) { self.prefs = prefs }
    func section() -> DocumentationSection? {
        let p = prefs.current
        var enabledNames: [String] = []
        var statusLines: [String] = []
        if p.miniMaxEnabled {
            enabledNames.append("MiniMax")
            let hasKey = (Keychain.get(KeychainAccount.miniMaxAPIKey)?.isEmpty == false)
            statusLines.append("MiniMax: \(hasKey ? "configured" : "key missing")")
        }
        if p.geminiEnabled {
            enabledNames.append("Gemini")
            let hasKey = (Keychain.get(KeychainAccount.geminiAPIKey)?.isEmpty == false)
            statusLines.append("Gemini: \(hasKey ? "configured" : "key missing")")
        }
        if p.llamaCppEnabled {
            enabledNames.append("llama.cpp")
            statusLines.append("llama.cpp: enabled")
        }
        let status: DocumentationStatus =
            enabledNames.isEmpty ? .notConfigured : .enabled
        let subtitle = enabledNames.isEmpty
            ? "No AI provider enabled.  Jarvis answers from deterministic commands only."
            : "Active providers: " + enabledNames.joined(separator: ", ")
                + ".  Mode: \(p.llmProviderModeRaw)."
        var trouble: [DocumentationTroubleshooting] = []
        if p.geminiEnabled, (Keychain.get(KeychainAccount.geminiAPIKey)?.isEmpty != false) {
            trouble.append(DocumentationTroubleshooting(
                symptom: "Gemini configured but missing API key",
                fix: "Settings → AI → Gemini → paste your API key.  The token is stored in the macOS Keychain, never preferences.json.",
                isActive: true))
        }
        if p.miniMaxEnabled, (Keychain.get(KeychainAccount.miniMaxAPIKey)?.isEmpty != false) {
            trouble.append(DocumentationTroubleshooting(
                symptom: "MiniMax configured but missing API key",
                fix: "Settings → AI → MiniMax → paste your API key.",
                isActive: true))
        }
        return DocumentationSection(
            id: id,
            category: .aiProviders,
            title: "AI Providers",
            subtitle: subtitle,
            bodyMarkdown: """
            Jarvis routes open-ended questions through one or more LLM providers.  Three are supported:

            * **MiniMax** — multimodal (text + vision), cloud-hosted.
            * **Gemini** — Google's generative-language API, multimodal.
            * **llama.cpp** — local OpenAI-compatible server for fully-offline operation (port 8080).

            \(statusLines.isEmpty ? "" : "**Live status:** " + statusLines.joined(separator: " · "))

            Provider mode (Settings → AI) determines the order Jarvis tries them in.  \
            A circuit breaker pauses providers that fail repeatedly, so a flaky network \
            never blocks a deterministic command.
            """,
            examples: [
                .init(phrase: "what's the meaning of consciousness"),
                .init(phrase: "explain how convection works"),
                .init(phrase: "summarise that for me",  kind: .followUp),
            ],
            relatedSettings: ["Settings → AI"],
            requiredIntegrations: enabledNames.isEmpty
                ? ["Enable at least one provider in Settings → AI"]
                : [],
            troubleshooting: trouble,
            status: status,
            searchTags: ["llm", "ai", "minimax", "gemini", "lm studio", "provider", "model"])
    }
}

// MARK: - NewsAndMediaContributor

@MainActor
final class NewsContributor: DocumentationContributor {
    let id = "news.media"
    func section() -> DocumentationSection? {
        DocumentationSection(
            id: id,
            category: .newsAndMedia,
            title: "News & Media",
            subtitle: "Watch live news channels in an iframe overlay (no cookie banners, no sign-in walls).",
            bodyMarkdown: """
            Jarvis embeds live news channels via the YouTube embed-only iframe path — \
            cookie / sign-in prompts you'd see on youtube.com don't appear.

            Add custom channels in **Settings → News**.  Paste a YouTube watch URL, \
            short link, embed URL, or iframe snippet — Jarvis normalises all of them.

            Channel URLs that point at @handle/live without a video ID can't be embedded.  \
            Jarvis surfaces a clear "embed not possible" message and an Open-in-browser button.
            """,
            examples: [
                .init(phrase: "show news"),
                .init(phrase: "watch the news"),
                .init(phrase: "watch BBC"),
                .init(phrase: "watch Bloomberg"),
                .init(phrase: "summarise the headlines"),
                .init(phrase: "open the first story",  kind: .contextual),
                .init(phrase: "tell me more",           kind: .followUp),
            ],
            relatedSettings: ["Settings → News"],
            status: .enabled,
            searchTags: ["news", "watch", "headlines", "bbc", "sky", "bloomberg", "youtube", "live"])
    }
}

// MARK: - MemoryAndObsidianContributor

@MainActor
final class MemoryObsidianContributor: DocumentationContributor {
    let id = "memory.obsidian"
    private let prefs: PreferencesStore
    init(prefs: PreferencesStore) { self.prefs = prefs }
    func section() -> DocumentationSection? {
        let vault = prefs.current.obsidianVaultPath ?? ""
        let obsOn = !vault.isEmpty && prefs.current.obsidianLLMContextEnabled
        let status: DocumentationStatus = obsOn ? .enabled : .notConfigured
        let subtitle = obsOn
            ? "Obsidian RAG enabled — vault at \(vault).  Notes are injected into LLM context."
            : "Obsidian is not configured.  Memory still works for everything Jarvis explicitly remembers."
        return DocumentationSection(
            id: id,
            category: .memoryAndObsidian,
            title: "Memory & Obsidian",
            subtitle: subtitle,
            bodyMarkdown: """
            Jarvis has two long-term memory layers:

            * **Memory store** — things you explicitly ask it to remember.  Persisted in SQLite + a semantic index.  Hybrid keyword+vector search.
            * **Obsidian vault** — your `.md` notes indexed for full-text + semantic retrieval.  Used as live context for LLM answers ("ask the vault about X").

            Both are local-only.  Nothing in memory or the vault leaves the machine \
            unless an LLM call needs context — and even then only the matching snippets, \
            not whole notes.
            """,
            examples: [
                .init(phrase: "remember I prefer flat whites"),
                .init(phrase: "what do you remember about Shopify"),
                .init(phrase: "what was I doing earlier"),
                .init(phrase: "search obsidian for project plan"),
                .init(phrase: "open Obsidian"),
            ],
            relatedSettings: ["Settings → Obsidian"],
            requiredIntegrations: obsOn ? [] : ["Set vault path in Settings → Obsidian"],
            status: status,
            searchTags: ["memory", "remember", "obsidian", "notes", "vault", "rag", "recall"])
    }
}

// MARK: - PrivacyContributor

@MainActor
final class PrivacyContributor: DocumentationContributor {
    let id = "core.privacy"
    private let prefs: PreferencesStore
    init(prefs: PreferencesStore) { self.prefs = prefs }
    func section() -> DocumentationSection? {
        let cloudVision = prefs.current.cloudVisionConsent
        let authOn      = prefs.current.requireWebSocketAuth
        return DocumentationSection(
            id: id,
            category: .privacy,
            title: "Privacy & Security",
            subtitle: "Cloud vision: \(cloudVision ? "ON" : "OFF").  WebSocket auth: \(authOn ? "required" : "off").",
            bodyMarkdown: """
            Privacy-by-default rules baked into Jarvis:

            * **Camera frames never leave the machine** unless cloud-vision consent is on.
            * **API keys live in the macOS Keychain only** — never in `preferences.json`, never in logs.
            * **WebSocket auth** is enforced on every Android frame when enabled (default).  Failed-auth attempts are silently dropped and rate-limited.
            * **Logs** never contain tokens, transcripts of long utterances, or full prompts.
            * **Voice recordings** are processed in-memory and discarded — Jarvis stores transcripts and intent labels, never audio.
            """,
            relatedSettings: ["Settings → Vision",
                              "Settings → Network → Require WebSocket auth",
                              "Settings → AI"],
            status: .informational,
            searchTags: ["privacy", "security", "keychain", "auth", "token", "consent"])
    }
}

// MARK: - MacSystemContributor

@MainActor
final class MacSystemContributor: DocumentationContributor {
    let id = "system.mac"
    func section() -> DocumentationSection? {
        DocumentationSection(
            id: id,
            category: .macSystem,
            title: "Mac System Control",
            subtitle: "Open apps, control music, clipboard, screen, and basic system actions.",
            bodyMarkdown: """
            Jarvis can drive macOS via AppleScript and direct CocoaScripting:

            * Open / close / focus applications.
            * Spotify playback (next / previous / pause / volume / what's playing).
            * System clipboard — read or write the current item.
            * Take a screenshot of the active screen.
            * Wi-Fi and Bluetooth on/off (Wi-Fi via `networksetup`; BT requires `blueutil`).
            * Apple Notes / Reminders (where permission granted).
            """,
            examples: [
                .init(phrase: "open Safari"),
                .init(phrase: "close Google Maps"),
                .init(phrase: "next track"),
                .init(phrase: "pause music"),
                .init(phrase: "what am I listening to"),
                .init(phrase: "copy that to clipboard"),
                .init(phrase: "turn wifi off"),
            ],
            limitations: [
                "Destructive actions like \"delete all my files\" are blocked at the intent bridge — Jarvis refuses them.",
                "Bluetooth control needs `brew install blueutil` for full support."
            ],
            status: .enabled,
            searchTags: ["mac", "open", "close", "app", "spotify", "clipboard", "wifi", "bluetooth"])
    }
}

// MARK: - ProactivityContributor

@MainActor
final class ProactivityContributor: DocumentationContributor {
    let id = "core.proactivity"
    func section() -> DocumentationSection? {
        DocumentationSection(
            id: id,
            category: .proactivity,
            title: "Automation & Proactivity",
            subtitle: "Jarvis speaks up when it has something useful for you — calendar, weather, GitHub, Shopify, HA, Obsidian.",
            bodyMarkdown: """
            Background providers poll their integrations and emit `ProactivitySignal` values \
            into a central engine.  The engine deduplicates, applies cooldowns and quiet hours, \
            and surfaces signals via spoken alerts and the notifications tray.

            Daily / per-event flags are persisted so a Mac restart doesn't re-fire morning briefings.
            """,
            examples: [
                .init(phrase: "what's happening today"),
                .init(phrase: "show notifications"),
                .init(phrase: "dismiss it",      kind: .contextual),
                .init(phrase: "mute proactivity", kind: .followUp),
                .init(phrase: "quiet hours"),
            ],
            relatedSettings: ["Settings → General → Proactivity"],
            status: .enabled,
            searchTags: ["alert", "notify", "proactive", "automation", "calendar", "weather", "github"])
    }
}

// MARK: - SpatialInteractionContributor

/// Documents the full spatial / hand-gesture vocabulary: ambient hand tracking,
/// cursor, HUD, pinch-to-drag, throw physics, two-hand spread, dwell-click,
/// orb hover ring, and contextual HUD.
@MainActor
final class SpatialInteractionContributor: DocumentationContributor {
    let id = "spatial.interaction"

    func section() -> DocumentationSection? {
        DocumentationSection(
            id: id,
            category: .developer,
            title: "Spatial Hand Gestures",
            subtitle: "Ambient hand tracking — no voice command needed. Raise your hand and the cursor appears automatically.",
            bodyMarkdown: """
            Jarvis uses your Mac's camera to passively track your hand in 3D space. \
            The spatial layer runs at all times alongside the normal UI — there is no \
            special mode to enter. Simply raise your hand in front of the camera.

            ## Cursor

            A translucent cursor dot follows your index fingertip in real time. \
            It fades in smoothly when a hand appears and fades out after the hand \
            leaves (0.8 s grace window).  The cursor applies a *magnetic* scale \
            boost when it approaches the Jarvis orb.

            ## Orb hover ring

            When the cursor enters the orb's hover radius a pulsing cyan ring \
            appears around the orb — confirming the hover target without any click.

            ## Overlay focus glow

            When the cursor drifts over an open overlay panel a cyan border \
            illuminates the panel, indicating it is the spatial focus target.

            ## Radial HUD (pinch)

            Pinch your thumb and index finger together to open the radial HUD. \
            Six items arc above the pinch point:

            **Default (no panel focused):**
            | Item | Action |
            |------|--------|
            | News | Open the news overlay |
            | Camera | Open the camera view |
            | Memory | Open the memory browser |
            | Debug | Open runtime diagnostics |
            | Close | Close the top overlay |
            | Reset | Reset orb to centre stage |

            **When an overlay is focused:**
            | Item | Action |
            |------|--------|
            | News | Open news |
            | Camera | Open camera |
            | Memory | Open memory |
            | Pin | Pin / unpin the focused overlay |
            | Expand | Toggle full-stage maximise |
            | Close | Close the focused overlay |

            ## Selecting a HUD item

            Two ways to select:
            * **Pinch release** — move to an item while pinching, then release.
            * **Dwell-click** — hover on an item for **1.5 seconds** without releasing; \
              it fires automatically. A circular arc fills around the chip to show progress.

            ## Pinch-to-drag (overlay reposition)

            To move an overlay panel:
            1. Position your cursor **inside** the panel.
            2. Pinch — the panel enters drag mode (HUD does not open).
            3. Move your hand to reposition the panel in real time.
            4. Release your pinch to drop and commit the position.

            **Throw physics:** releasing with a fast hand velocity throws the panel \
            in that direction, sliding it to a natural resting position.

            ## Two-hand spread (resize)

            1. Raise **both hands** in front of the camera.
            2. Ensure an overlay panel is focused (cursor inside it).
            3. Spread your hands apart to enlarge the panel; bring them together to shrink it.

            The panel resizes proportionally, centred on its current position. \
            Minimum 360 × 280 pt, maximum 1100 × 780 pt.

            ## Adaptive performance

            - **No hand detected:** Vision runs at ~5 fps (every 12th frame).  CPU cost is negligible.
            - **Hand detected:** Vision runs at up to 60 fps for smooth tracking.
            """,
            examples: [
                .init(phrase: "show spatial mode",  kind: .commandPhrase,
                      followUp: "opens diagnostics overlay"),
                .init(phrase: "hide spatial mode",  kind: .commandPhrase),
                .init(phrase: "raise your hand and pinch",  kind: .contextual,
                      followUp: "opens radial HUD"),
                .init(phrase: "hover on a HUD item for 1.5 s",  kind: .contextual,
                      followUp: "dwell-click — auto-fires"),
                .init(phrase: "pinch inside a panel and move",  kind: .contextual,
                      followUp: "pinch-to-drag overlay"),
                .init(phrase: "spread both hands",  kind: .contextual,
                      followUp: "resizes focused overlay"),
            ],
            limitations: [
                "Requires a camera with a clear view of your hand — built-in or external USB webcam.",
                "Accuracy drops in poor lighting or when the hand is partially off-screen.",
                "Two-hand gestures require both hands to be simultaneously visible to the same camera.",
                "The spatial layer runs on the primary camera; it shares the frame tap with the presence detector.",
            ],
            status: .enabled,
            searchTags: ["hand", "gesture", "pinch", "spatial", "cursor", "hud",
                         "drag", "throw", "spread", "resize", "dwell", "orb", "hover"])
    }
}

// MARK: - ConversationalHelpContributor

@MainActor
final class ConversationalHelpContributor: DocumentationContributor {
    let id = "help.conversational"
    func section() -> DocumentationSection? {
        DocumentationSection(
            id: id,
            category: .gettingStarted,
            title: "Asking Jarvis For Help",
            subtitle: "Ask \"how do I…\" or \"what can you do with X\" — answers come from this living manual, not from a hallucinating LLM.",
            bodyMarkdown: """
            The help system you're reading **is** the documentation system.  When you ask Jarvis \
            "how do I call someone" or "what can you do with Obsidian", Jarvis searches these \
            same sections and reads back the answer.

            Section status pills tell you what's working right now:

            * **enabled** — ready to use
            * **disabled** — turned off in Settings
            * **degraded** — partially working (e.g. provider configured but offline)
            * **not configured** — never set up
            * **informational** — pure reference, no on/off

            Toggle subsystems in Settings and re-open this overlay — the docs reflect the change immediately.
            """,
            examples: [
                .init(phrase: "show help"),
                .init(phrase: "what can you do"),
                .init(phrase: "teach me Jarvis"),
                .init(phrase: "help me understand"),
                .init(phrase: "how do I call someone"),
                .init(phrase: "how do I use vision"),
                .init(phrase: "how do I connect Android"),
            ],
            status: .informational,
            searchTags: ["help", "documentation", "manual", "guide", "how", "teach"])
    }
}

// MARK: - OrbColorReferenceContributor

@MainActor
final class OrbColorReferenceContributor: DocumentationContributor {
    let id = "help.orb_colors"
    func section() -> DocumentationSection? {
        DocumentationSection(
            id: id,
            category: .wakeAndListening,
            title: "Orb Color Reference",
            subtitle: "The orb shows Jarvis's listening state at a glance.",
            bodyMarkdown: """
            ## Orb Colors

            | Color | State | Meaning |
            |-------|-------|---------|
            | **Grey** | Idle / Muted | Not doing anything — listening is off or not started |
            | **Blue** | Wake-word armed | Passively listening for "Jarvis" |
            | **Cyan** | Actively listening | Microphone open, transcribing your command |
            | **Green** | In conversation | Command understood; follow-up window active |
            | **Purple** | Thinking | Processing command, routing to LLM or action |
            | **Orange** | Speaking | TTS output playing, or barge-in interrupt |
            | **Red** | Error | Microphone or speech recognition failure |

            ## State Transitions

            * **Blue → Cyan** — you say "Jarvis"; STT opens.
            * **Cyan → Purple** — final transcript received; routing begins.
            * **Purple → Orange** — response ready; TTS speaks.
            * **Orange → Cyan/Green** — TTS finishes; follow-up listening opens.
            * **Orange → Blue** — TTS finishes; no active session; returns to passive.
            * **Cyan → Green** — conversational mode; no wake word needed for follow-ups.
            * **Any → Red** — microphone loss, dictation disabled, or audio failure.
            * **Any → Grey** — user says "stop listening" / muted.

            ## Guarantees

            * The orb **always** returns to blue (wake-armed) after every command, overlay,
              silence, error, or cancelled speech — unless you explicitly mute it.
            * A safety watchdog checks every second and restarts the wake word if it stopped
              unexpectedly.
            * Overlays do **not** affect the microphone — the orb stays blue while any
              panel is open.

            ## Diagnostics

            Say **"developer mode"** to open the Debug HUD.  The HUD shows:
            * `orb` — current orb color name
            * `desired` — configured listening mode (disabled / wake-word only / persistent / conversation)
            * `actual` — instantaneous audio pipeline state
            * `lifecycle log` — last 5 state transitions with reasons
            * `watchdog` — restart count and last recovery time
            """,
            examples: [
                .init(phrase: "developer mode",    kind: .commandPhrase),
                .init(phrase: "are you listening", kind: .commandPhrase),
                .init(phrase: "stop listening",    kind: .commandPhrase),
                .init(phrase: "listen again",      kind: .commandPhrase),
            ],
            status: .informational,
            searchTags: ["orb", "color", "colour", "blue", "cyan", "green", "purple",
                         "orange", "red", "grey", "gray", "muted", "listening", "state", "hud"])
    }
}
