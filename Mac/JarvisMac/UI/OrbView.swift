import SwiftUI

/// Animated orb that reflects assistant phase. Each phase has a distinct
/// colour, pulse frequency, and orbiting-dot speed so the user can tell
/// at a glance whether Jarvis is idle, armed for wake word, listening,
/// thinking, speaking, or recovering from a barge-in.
struct OrbView: View {
    let state: AppState

    var body: some View {
        let mode = mode(for: state.phase)
        TimelineView(.animation(minimumInterval: animationInterval,
                                paused: isAnimationPaused)) { context in
            Canvas { ctx, size in
                draw(into: ctx,
                     size: size,
                     time: context.date.timeIntervalSinceReferenceDate,
                     mode: mode)
            }
            .animation(.easeInOut(duration: 0.25), value: state.phase)
        }
        .accessibilityHidden(true)
    }

    /// Target frame interval. Drops to 10 fps in safe mode during active
    /// phases; 15 fps in normal idle; 30 fps when fully active.
    private var animationInterval: Double {
        if state.safeMode {
            // Active phases still need some motion so the user knows Jarvis
            // is alive, but half the normal rate is plenty.
            switch state.phase {
            case .idle, .muted:
                return 1.0 / 8.0     // 8 fps — nearly static in safe+idle
            default:
                return 1.0 / 10.0    // 10 fps — visible motion in safe+active
            }
        } else {
            switch state.phase {
            case .idle, .muted:
                return 1.0 / 15.0    // 15 fps — gentle idle pulse
            default:
                return 1.0 / 30.0    // 30 fps — smooth active animation
            }
        }
    }

    /// Fully pause the timeline in safe mode when idle — the orb is a
    /// static shape and consumes zero GPU until the phase changes.
    private var isAnimationPaused: Bool {
        state.safeMode && (state.phase == .idle || state.phase == .muted)
    }

    private func mode(for phase: AssistantPhase) -> OrbMode {
        switch phase {
        case .idle:                      return .idle
        case .wakeListening:             return .armed
        case .listening:                 return .listening
        case .conversationalListening:   return .conversational
        case .awaitingResponse:          return .conversational // same as follow-up, slightly calmer
        case .thinking:                  return .thinking
        case .speaking:                  return .speaking
        case .bargedIn:                  return .bargedIn
        case .muted:                     return .idle  // dim, low energy
        case .error:                     return .error
        }
    }

    private func draw(into ctx: GraphicsContext,
                      size: CGSize,
                      time t: Double,
                      mode: OrbMode) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let baseRadius = min(size.width, size.height) * 0.32
        let breath = (sin(t * mode.frequency) + 1) / 2
        let pulse = 0.08 + 0.10 * breath
        let radius = baseRadius * (1 + pulse * mode.amplitude)

        // Outer halo rings
        for i in 0..<4 {
            let f = CGFloat(i + 1)
            let r = radius * (1 + f * 0.16)
            let opacity = 0.20 / f
            let path = Path(ellipseIn: CGRect(x: center.x - r,
                                              y: center.y - r,
                                              width: r * 2,
                                              height: r * 2))
            ctx.stroke(path,
                       with: .color(mode.color.opacity(opacity)),
                       lineWidth: 1.5)
        }

        // Core
        let core = Path(ellipseIn: CGRect(x: center.x - radius,
                                          y: center.y - radius,
                                          width: radius * 2,
                                          height: radius * 2))
        ctx.fill(core, with: .radialGradient(
            Gradient(colors: [
                mode.color.opacity(0.95),
                mode.color.opacity(0.10),
                mode.color.opacity(0.0)
            ]),
            center: center,
            startRadius: 0,
            endRadius: radius
        ))

        // Inner glint (small bright dot)
        let glint = Path(ellipseIn: CGRect(x: center.x - 4,
                                           y: center.y - 4,
                                           width: 8, height: 8))
        ctx.fill(glint, with: .color(mode.color.opacity(0.85)))

        // Orbiting dots
        let dotCount = mode.dotCount
        for i in 0..<dotCount {
            let angle = t * mode.orbitSpeed + Double(i) * (2 * .pi / Double(dotCount))
            let r = radius * 1.4
            let p = CGPoint(x: center.x + cos(angle) * r,
                            y: center.y + sin(angle) * r)
            let dot = Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3,
                                             width: 6, height: 6))
            ctx.fill(dot, with: .color(mode.color.opacity(0.85)))
        }
    }
}

private struct OrbMode {
    let color: Color
    let frequency: Double
    let amplitude: Double
    let orbitSpeed: Double
    let dotCount: Int

    // Color semantics (matches OrbColorReference in help documentation):
    // gray   = idle / disabled / muted — not doing anything
    // blue   = wake word armed — passive listening for "Jarvis"
    // cyan   = actively recording / transcribing a command
    // green  = in-conversation / command understood, awaiting follow-up
    // purple = thinking / LLM processing
    // orange = speaking TTS output (also barge-in interruption)
    // red    = error / microphone unavailable — something is wrong
    static let idle             = OrbMode(color: .gray,    frequency: 1.4, amplitude: 0.20, orbitSpeed: 0.30, dotCount: 4)
    static let armed            = OrbMode(color: .blue,    frequency: 2.0, amplitude: 0.55, orbitSpeed: 0.80, dotCount: 8)
    static let listening        = OrbMode(color: .cyan,    frequency: 6.0, amplitude: 1.20, orbitSpeed: 2.20, dotCount: 8)
    static let conversational   = OrbMode(color: .green,   frequency: 3.5, amplitude: 0.65, orbitSpeed: 1.10, dotCount: 6)
    static let thinking         = OrbMode(color: .purple,  frequency: 3.0, amplitude: 0.70, orbitSpeed: 3.50, dotCount: 12)
    static let speaking         = OrbMode(color: .orange,  frequency: 4.5, amplitude: 0.90, orbitSpeed: 1.60, dotCount: 8)
    static let bargedIn         = OrbMode(color: .orange,  frequency: 8.0, amplitude: 1.40, orbitSpeed: 2.80, dotCount: 6)
    static let error            = OrbMode(color: .red,     frequency: 2.5, amplitude: 0.50, orbitSpeed: 0.30, dotCount: 3)
}
