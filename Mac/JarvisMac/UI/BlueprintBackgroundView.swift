import SwiftUI

/// Dark architectural blueprint background: navy base, faint grid,
/// subtle radial glow behind the orb centre. Pure SwiftUI Canvas — no images.
/// Ambient mode adds a slow breathing pulse ring and slightly animated glow.
struct BlueprintBackgroundView: View {
    let phaseColor: Color
    var ambientEnabled: Bool = false
    var attentionDimFactor: Double = 1.0  // 0–1, from AttentionState.ambientDimFactor
    /// When true the ambient pulse is reduced to ~10 fps; non-ambient is
    /// fully paused (static Canvas, zero scheduled GPU work).
    var safeMode: Bool = false

    // Slow breathing animation for ambient mode
    @State private var breathPhase: Double = 0

    // Ambient interval: 10 fps in safe mode, 15 fps otherwise.
    // Non-ambient: fully paused — the background is purely static.
    private var timelineSchedule: AnimationTimelineSchedule {
        ambientEnabled
            ? .animation(minimumInterval: safeMode ? 1.0 / 10.0 : 1.0 / 15.0)
            : .animation(minimumInterval: 60.0, paused: true)
    }

    var body: some View {
        TimelineView(timelineSchedule) { ctx in
            let t = ambientEnabled ? ctx.date.timeIntervalSinceReferenceDate : 0
            Canvas { context, size in
                // 1. Medium-navy base. Reads clearly as blue, dark enough
                //    that cyan grid lines and the orb still pop on top.
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .color(Color(red: 0.08, green: 0.16, blue: 0.30))
                )

                // 2. Soft horizontal lightening at the upper third —
                //    suggests an overhead light source on the blueprint.
                let lift = LinearGradient(
                    colors: [
                        Color.white.opacity(0.045),
                        Color.white.opacity(0.015),
                        .clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .linearGradient(
                        Gradient(stops: [
                            .init(color: Color.white.opacity(0.05), location: 0.0),
                            .init(color: Color.white.opacity(0.02), location: 0.35),
                            .init(color: .clear,                    location: 0.85)
                        ]),
                        startPoint: CGPoint(x: size.width / 2, y: 0),
                        endPoint:   CGPoint(x: size.width / 2, y: size.height)
                    )
                )
                _ = lift

                // 3. Fine grid (visible against medium blue).
                drawGrid(context, size, spacing: 44,
                         color: .cyan, opacity: 0.080, lineWidth: 0.5)

                // 4. Coarser structural grid every 4 cells.
                drawGrid(context, size, spacing: 176,
                         color: .cyan, opacity: 0.160, lineWidth: 0.6)

                // 5. Crosshair guides through centre.
                drawCrossHair(context, size)

                // 6. Concentric circle guides.
                drawCircleGuides(context, size)

                // 7. Subtle corner ticks — small registration marks that
                //    push the "drafted blueprint" feel without clutter.
                drawCornerTicks(context, size)

                // 8. Vignette: slight darkening into the corners so the
                //    centre reads as the focal point.
                let vig = Path(CGRect(origin: .zero, size: size))
                context.fill(
                    vig,
                    with: .radialGradient(
                        Gradient(stops: [
                            .init(color: .clear,                   location: 0.0),
                            .init(color: .black.opacity(0.10),     location: 0.75),
                            .init(color: .black.opacity(0.28),     location: 1.0)
                        ]),
                        center: CGPoint(x: size.width / 2, y: size.height / 2),
                        startRadius: 0,
                        endRadius: hypot(size.width, size.height) * 0.55
                    )
                )

                // 9. Ambient pulse ring (only in ambient mode when idle/away).
                if ambientEnabled && attentionDimFactor < 0.6 {
                    drawAmbientPulse(context, size, time: t)
                }
            }
            .overlay(
                // Radial phase-colour glow at centre (lifts the orb area).
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: phaseColor.opacity(0.14 * attentionDimFactor), location: 0.0),
                        .init(color: phaseColor.opacity(0.06 * attentionDimFactor), location: 0.35),
                        .init(color: .clear, location: 0.65)
                    ]),
                    center: .center,
                    startRadius: 0,
                    endRadius: 650
                )
                .blendMode(.screen)
            )
        }
        .ignoresSafeArea()
    }

    // MARK: - Canvas helpers

    private func drawGrid(_ ctx: GraphicsContext,
                          _ size: CGSize,
                          spacing: CGFloat,
                          color: Color = .white,
                          opacity: Double,
                          lineWidth: CGFloat) {
        var path = Path()

        var x: CGFloat = 0
        while x <= size.width {
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            x += spacing
        }

        var y: CGFloat = 0
        while y <= size.height {
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            y += spacing
        }

        ctx.stroke(path, with: .color(color.opacity(opacity)), lineWidth: lineWidth)
    }

    private func drawCrossHair(_ ctx: GraphicsContext, _ size: CGSize) {
        let cx = size.width / 2
        let cy = size.height / 2
        let reach = min(size.width, size.height) * 0.44

        var path = Path()
        path.move(to: CGPoint(x: cx - reach, y: cy))
        path.addLine(to: CGPoint(x: cx + reach, y: cy))
        path.move(to: CGPoint(x: cx, y: cy - reach))
        path.addLine(to: CGPoint(x: cx, y: cy + reach))

        ctx.stroke(path, with: .color(Color.cyan.opacity(0.12)), lineWidth: 0.6)
    }

    private func drawCircleGuides(_ ctx: GraphicsContext, _ size: CGSize) {
        let cx = size.width / 2
        let cy = size.height / 2
        let base = min(size.width, size.height) * 0.44

        for (factor, opacity) in [(0.52, 0.10), (0.80, 0.06), (1.10, 0.035)] as [(Double, Double)] {
            let r = base * factor
            let circle = Path(ellipseIn: CGRect(x: cx - r, y: cy - r,
                                                width: r * 2, height: r * 2))
            ctx.stroke(circle, with: .color(Color.cyan.opacity(opacity)), lineWidth: 0.6)
        }
    }

    /// Small L-shaped registration ticks in each corner — classic
    /// blueprint/HUD touch, very low contrast.
    private func drawCornerTicks(_ ctx: GraphicsContext, _ size: CGSize) {
        let pad: CGFloat = 28
        let len: CGFloat = 22
        let stroke = GraphicsContext.Shading.color(Color.cyan.opacity(0.22))

        var path = Path()
        // TL
        path.move(to: CGPoint(x: pad,       y: pad + len))
        path.addLine(to: CGPoint(x: pad,    y: pad))
        path.addLine(to: CGPoint(x: pad+len, y: pad))
        // TR
        path.move(to: CGPoint(x: size.width - pad - len, y: pad))
        path.addLine(to: CGPoint(x: size.width - pad,    y: pad))
        path.addLine(to: CGPoint(x: size.width - pad,    y: pad + len))
        // BL
        path.move(to: CGPoint(x: pad,       y: size.height - pad - len))
        path.addLine(to: CGPoint(x: pad,    y: size.height - pad))
        path.addLine(to: CGPoint(x: pad+len, y: size.height - pad))
        // BR
        path.move(to: CGPoint(x: size.width - pad - len, y: size.height - pad))
        path.addLine(to: CGPoint(x: size.width - pad,    y: size.height - pad))
        path.addLine(to: CGPoint(x: size.width - pad,    y: size.height - pad - len))

        ctx.stroke(path, with: stroke, lineWidth: 1.0)
    }

    /// Slow expanding ring that breathes when the system is ambient-idle.
    private func drawAmbientPulse(_ ctx: GraphicsContext, _ size: CGSize, time t: Double) {
        let cx = size.width / 2
        let cy = size.height / 2
        let base = min(size.width, size.height) * 0.44
        // Very slow breath: period ~8s
        let breath = (sin(t * 0.8) + 1) / 2
        let r = base * (1.15 + 0.20 * breath)
        let opacity = 0.035 * (1 - attentionDimFactor + 0.3)
        let ring = Path(ellipseIn: CGRect(x: cx - r, y: cy - r,
                                          width: r * 2, height: r * 2))
        ctx.stroke(ring, with: .color(Color.cyan.opacity(opacity)), lineWidth: 1.0)
    }
}
