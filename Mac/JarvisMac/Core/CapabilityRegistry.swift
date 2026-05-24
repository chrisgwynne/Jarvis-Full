import Foundation

/// Structured registry of Jarvis's built-in capabilities.
///
/// `FastResponseRouter` and `ConversationalAnswerService` use this to build
/// "what can you do" answers without hardcoding strings in multiple places.
/// The registry is pure data — capabilities are not toggled at runtime, they
/// simply reflect what is compiled in.
struct CapabilityRegistry {

    struct Capability: Identifiable {
        let id: String
        let name: String
        let description: String
        let examplePhrase: String
    }

    // MARK: - Static list

    static let all: [Capability] = [
        Capability(id: "voice_control",
                   name: "Voice Control",
                   description: "Control Jarvis hands-free using natural speech",
                   examplePhrase: "Jarvis, show news"),
        Capability(id: "app_launch",
                   name: "App Launching",
                   description: "Open any Mac application by name",
                   examplePhrase: "open Safari"),
        Capability(id: "news",
                   name: "News & Live Channels",
                   description: "Browse headlines and watch live news channels",
                   examplePhrase: "watch Bloomberg"),
        Capability(id: "camera",
                   name: "Camera & Presence",
                   description: "See through the camera and detect presence",
                   examplePhrase: "is anyone there"),
        Capability(id: "memory",
                   name: "Memory & Search",
                   description: "Store and recall facts and conversation history",
                   examplePhrase: "remember my coffee order is a flat white"),
        Capability(id: "screen",
                   name: "Screen Awareness",
                   description: "Read and summarise the current screen content",
                   examplePhrase: "what am I looking at"),
        Capability(id: "home",
                   name: "Smart Home",
                   description: "Control Home Assistant lights, switches, and devices",
                   examplePhrase: "turn off the lights"),
        Capability(id: "llm",
                   name: "AI Reasoning",
                   description: "Answer open-ended questions and summarise content",
                   examplePhrase: "summarise the news"),
        Capability(id: "overlays",
                   name: "Overlay System",
                   description: "Show information panels layered over your desktop",
                   examplePhrase: "show memory"),
        Capability(id: "timeline",
                   name: "Activity Timeline",
                   description: "Review what you've been working on",
                   examplePhrase: "what was I doing earlier"),
    ]

    // MARK: - Spoken summaries

    /// Short spoken answer for "what can you do" — one sentence per theme.
    @MainActor
    func spokenSummary(state: AppState, prefs: Preferences) -> String {
        var actions: [String] = []
        actions.append("open apps and browse news")
        actions.append("search and save memories")
        actions.append("read your screen")
        if state.cameraStatus.isHealthy { actions.append("watch the camera") }
        if !(prefs.smartHomeBaseURL ?? "").isEmpty { actions.append("control smart home") }
        actions.append("and answer questions with AI")

        let list = actions.dropLast().joined(separator: ", ") + ", " + (actions.last ?? "")
        return "I can \(list). Say 'show news', 'watch Bloomberg', or 'show memory' to get started."
    }

    /// Compact one-liner for LLM context injection (token budget aware).
    @MainActor
    func compactSummary(state: AppState, prefs: Preferences) -> String {
        var parts = ["voice commands, overlays, news, memory, screen awareness, app launching"]
        if state.cameraStatus.isHealthy         { parts.append("camera + presence") }
        if !(prefs.smartHomeBaseURL ?? "").isEmpty { parts.append("Home Assistant") }
        return parts.joined(separator: "; ")
    }
}
