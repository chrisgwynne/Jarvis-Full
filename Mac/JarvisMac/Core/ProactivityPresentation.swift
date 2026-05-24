import SwiftUI

// MARK: - Urgency style

/// Controls how prominently the UI presents a proactive signal.
enum ProactivityUrgencyStyle {
    case ambient    // quiet — no animation, tray badge only
    case standard   // normal toast + tray entry
    case prominent  // animated header accent
    case critical   // full-attention overlay open immediately
}

// MARK: - Action button

/// A labelled action the user can take on a proactive signal.
struct ProactivityAction: Identifiable {
    let id: String
    let label: String
    let systemImage: String
    let isPrimary: Bool
}

// MARK: - Presentation

/// Everything the UI layer needs to present a proactive signal:
/// which overlay to open, what to speak, how to highlight, and what
/// action buttons to offer. Built by `ProactivityPresentation.make(from:decision:)`.
struct ProactivityPresentation {

    // MARK: Core

    /// The signal this presentation is for.
    let signal: ProactivitySignal

    /// Text Jarvis should speak when this presentation fires.
    let spokenText: String

    /// Which overlay to open (or focus) for this signal.
    let overlayKind: OverlayKind

    // MARK: Navigation

    /// Item ID the target overlay should scroll to / highlight.
    /// For `.news` this is the `NewsArticle.id`.
    let highlightItemID: String?

    // MARK: Behaviour flags

    /// `true` → open the overlay immediately (critical / urgent).
    /// `false` → add to tray; user opens manually.
    let autoOpenOverlay: Bool

    /// `true` → bring overlay to front even if already open.
    let autoFocusOverlay: Bool

    // MARK: Presentation style

    let urgencyStyle: ProactivityUrgencyStyle

    /// Buttons shown in the proactive alert overlay or compact banner.
    let actionButtons: [ProactivityAction]

    // MARK: - Factory

    /// Build a presentation from a signal + the engine's decision.
    static func make(from signal: ProactivitySignal,
                     decision: ProactivityDecision) -> ProactivityPresentation {

        // Use signal's explicit overlay kind if provided; otherwise fall back to source default.
        let overlayKind = signal.overlayKind ?? signal.source.preferredOverlayKind

        // Open overlay automatically for urgent/critical; queue quietly for others.
        let autoOpen  = (decision == .speakNow)
        let autoFocus = autoOpen

        let urgency: ProactivityUrgencyStyle
        switch signal.priority {
        case .critical: urgency = .critical
        case .urgent:   urgency = .prominent
        case .high:     urgency = .standard
        default:        urgency = .ambient
        }

        let spoken = signal.spokenText
            ?? "\(signal.source.displayName): \(signal.title)"

        // Standard action set — overlays and tray views use these as guidance.
        var buttons: [ProactivityAction] = [
            .init(id: "open",    label: "Open",
                  systemImage: "arrow.up.forward.app", isPrimary: true),
            .init(id: "dismiss", label: "Dismiss",
                  systemImage: "xmark",                isPrimary: false),
            .init(id: "mute",   label: "Mute source",
                  systemImage: "speaker.slash.fill",   isPrimary: false),
        ]
        if signal.suggestedAction != nil {
            buttons.insert(
                .init(id: "action", label: "View",
                      systemImage: "eye.fill", isPrimary: false),
                at: 1
            )
        }

        return ProactivityPresentation(
            signal:          signal,
            spokenText:      spoken,
            overlayKind:     overlayKind,
            highlightItemID: signal.sourceArticleID,
            autoOpenOverlay: autoOpen,
            autoFocusOverlay: autoFocus,
            urgencyStyle:    urgency,
            actionButtons:   buttons
        )
    }
}
