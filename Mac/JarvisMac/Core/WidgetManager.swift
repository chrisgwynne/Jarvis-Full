import Foundation

// MARK: - Widget Kind

/// Every card in the widget grid corresponds to one kind.
/// `modeDefault` determines which modes show it open by default.
enum WidgetKind: String, CaseIterable, Identifiable {

    // Assistant
    case voiceStatus    = "voice_status"
    case transcript     = "transcript"

    // Vision / camera
    case camera         = "camera"
    case vision         = "vision"

    // System / home
    case systemStatus   = "system_status"
    case homeAssistant  = "home_assistant"
    case context        = "context"
    case androidLink    = "android_link"

    // Developer
    case speechEngine   = "speech_engine"
    case wakeWord       = "wake_word"
    case audioDevice    = "audio_device"
    case latency        = "latency"
    case debugLogs      = "debug_logs"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .voiceStatus:  return "Voice Status"
        case .transcript:   return "Transcript"
        case .camera:       return "Camera"
        case .vision:       return "Vision"
        case .systemStatus: return "System"
        case .homeAssistant:return "Home Assistant"
        case .context:      return "Context"
        case .androidLink:  return "Android"
        case .speechEngine: return "Speech Engine"
        case .wakeWord:     return "Wake Word"
        case .audioDevice:  return "Audio Device"
        case .latency:      return "Latency"
        case .debugLogs:    return "Logs"
        }
    }

    var systemImage: String {
        switch self {
        case .voiceStatus:  return "waveform"
        case .transcript:   return "text.bubble.fill"
        case .camera:       return "camera.fill"
        case .vision:       return "eye.fill"
        case .systemStatus: return "cpu.fill"
        case .homeAssistant:return "house.fill"
        case .context:      return "brain.head.profile"
        case .androidLink:  return "antenna.radiowaves.left.and.right"
        case .speechEngine: return "waveform.badge.magnifyingglass"
        case .wakeWord:     return "ear.fill"
        case .audioDevice:  return "mic.fill"
        case .latency:      return "timer"
        case .debugLogs:    return "doc.text.fill"
        }
    }

    /// Which UI modes show this widget by default (can be overridden by user).
    var defaultModes: Set<UIMode> {
        switch self {
        // Developer-only widgets
        case .speechEngine, .wakeWord, .audioDevice, .latency, .debugLogs:
            return [.developer]
        // Workspace + developer
        case .voiceStatus, .transcript, .systemStatus, .androidLink:
            return [.dashboard, .developer]
        // All modes except orb
        case .camera, .vision, .homeAssistant, .context:
            return [.dashboard, .developer]
        }
    }

    /// Whether this is a developer-only widget.
    var isDeveloperOnly: Bool {
        defaultModes == [.developer]
    }
}

// MARK: - WidgetManager

/// Tracks which widgets are open in the current session.
/// Applies sensible defaults when the UIMode changes.
/// Persists open/closed state to UserDefaults between launches.
@Observable
@MainActor
final class WidgetManager {

    // MARK: - State

    /// Set of open widget kinds (by rawValue for Codable simplicity).
    private(set) var openWidgets: Set<String> = []

    // MARK: - Init

    init(mode: UIMode = .orb) {
        loadSaved()
        // If nothing is saved, apply defaults for the given mode.
        if openWidgets.isEmpty { applyDefaults(for: mode) }
    }

    // MARK: - Queries

    func isOpen(_ kind: WidgetKind) -> Bool {
        openWidgets.contains(kind.rawValue)
    }

    var openKinds: [WidgetKind] {
        WidgetKind.allCases.filter { isOpen($0) }
    }

    /// Widgets visible for a given mode (open AND default for mode, or explicitly opened).
    func visibleWidgets(for mode: UIMode) -> [WidgetKind] {
        WidgetKind.allCases.filter { kind in
            guard isOpen(kind) else { return false }
            // In developer mode show everything that's open.
            if mode == .developer { return true }
            // In other modes, hide developer-only widgets even if "open".
            return !kind.isDeveloperOnly
        }
    }

    // MARK: - Mutations

    func open(_ kind: WidgetKind) {
        openWidgets.insert(kind.rawValue)
        save()
    }

    func close(_ kind: WidgetKind) {
        openWidgets.remove(kind.rawValue)
        save()
    }

    func toggle(_ kind: WidgetKind) {
        if isOpen(kind) { close(kind) } else { open(kind) }
    }

    /// Re-apply defaults for a mode — called when UIMode changes.
    func applyDefaults(for mode: UIMode) {
        switch mode {
        case .orb:
            // Orb mode: close all widgets (pure minimal experience).
            openWidgets.removeAll()
        case .dashboard:
            // Workspace: open non-developer widgets.
            openWidgets = Set(WidgetKind.allCases
                .filter { !$0.isDeveloperOnly }
                .map(\.rawValue))
        case .developer:
            // Developer: open everything.
            openWidgets = Set(WidgetKind.allCases.map(\.rawValue))
        }
        save()
    }

    func resetToDefaults(for mode: UIMode) {
        applyDefaults(for: mode)
    }

    // MARK: - Persistence

    private let persistenceKey = "WidgetManager.openWidgets"

    private func save() {
        UserDefaults.standard.set(Array(openWidgets), forKey: persistenceKey)
    }

    private func loadSaved() {
        if let saved = UserDefaults.standard.stringArray(forKey: persistenceKey) {
            openWidgets = Set(saved)
        }
    }
}
