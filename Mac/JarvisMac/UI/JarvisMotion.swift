import SwiftUI

/// Unified motion constants. Every animation in Jarvis uses one of these values
/// so the interface speaks one visual language.
///
/// Rules:
///   - Use only opacity, translation, and small scale changes
///   - No bounce, no spring overshoot, no elastic effects
///   - Nothing slower than 350ms. Nothing faster than 100ms.
///   - Animations occur only on state changes — never continuously
enum JarvisMotion {

    // MARK: - Durations

    static let fast:   Double = 0.12
    static let normal: Double = 0.20
    static let slow:   Double = 0.35

    // MARK: - Animations

    static var fastEase:   Animation { .easeOut(duration: fast) }
    static var normalEase: Animation { .easeOut(duration: normal) }
    static var slowEase:   Animation { .easeOut(duration: slow) }

    /// Large structural layout changes (orb pip expansion, overlay open/close).
    static var layout: Animation { .easeInOut(duration: 0.30) }

    /// Orb colour/state — slight ease-in-out so the colour blends, not cuts.
    static var orbState: Animation { .easeInOut(duration: 0.35) }

    // MARK: - Standard transitions

    /// ALL overlays, panels, and floating views use this exact transition.
    /// Entry: fade in + slide up 8pt. Exit: fade out + slide down 8pt.
    static var panel: AnyTransition {
        .opacity.combined(with: .offset(y: 8))
    }

    /// Dock reveal: opacity + larger upward slide.
    static var dock: AnyTransition {
        .opacity.combined(with: .offset(y: 20))
    }

    /// Toast: fade + tiny upward nudge.
    static var toast: AnyTransition {
        .opacity.combined(with: .offset(y: 6))
    }
}
