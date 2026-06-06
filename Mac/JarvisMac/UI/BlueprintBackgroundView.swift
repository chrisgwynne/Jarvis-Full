import SwiftUI
import OSLog

/// Dark architectural blueprint background: navy base, faint grid,
/// subtle radial glow behind the orb centre. Pure SwiftUI Canvas — no images.
///
/// CPU strategy (matches LightweightOrbView approach):
///   - Non-ambient:  FULLY PAUSED — static Canvas, zero scheduled GPU work.
///   - Ambient idle: CA-driven breathing animation via withAnimation(.repeatForever).
///                   Body called once; CA handles interpolation (~0% CPU).
///   - Ambient active / app in background: paused.
///
/// [RenderPerf] background cadence=... logged on each state transition.
struct BlueprintBackgroundView: View {
    let phaseColor: Color
    var ambientEnabled: Bool = false
    var attentionDimFactor: Double = 1.0
    var safeMode: Bool = false

    @Environment(\.scenePhase) private var scenePhase

    // CA-driven ambient pulse ring — set once, CA loops forever
    @State private var pulseScale: CGFloat = 1.0

    private let bgLog = Logger(subsystem: "com.jarvis.mac.JarvisMac", category: "render_perf")

    // Ambient is only animated when ambient mode is on AND app is in front.
    // Never animate when app is backgrounded (scenePhase != .active).
    private var isAmbientAnimating: Bool {
        ambientEnabled && !safeMode && scenePhase == .active && attentionDimFactor < 0.6
    }

    var body: some View {
        // The Canvas body is PURE STATIC — it only redraws when the view
        // is first laid out or `phaseColor`/`attentionDimFactor` changes.
        // The ambient pulse ring is a separate SwiftUI view driven by CA,
        // so the Canvas itself never has a repeating render loop.
        ZStack {
            staticCanvas

            // Phase-colour radial glow — only updates when phaseColor changes
            phaseGlow

            // Ambient pulse ring — CA animated, drawn as a SwiftUI view
            // so it composites on top of the cached Canvas without re-drawing it.
            if isAmbientAnimating {
                ambientPulseRing
                    .scaleEffect(pulseScale)    // ← CA driven
            }
        }
        .ignoresSafeArea()
        .onAppear      { startAmbientAnimation() }
        .onChange(of: isAmbientAnimating) { _, active in
            if active { startAmbientAnimation() } else { stopAmbientAnimation() }
        }
    }

    // MARK: - Static Canvas (rendered once, composited by GPU)

    private var staticCanvas: some View {
        Canvas { context, size in
            // 1. Medium-navy base
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(Color(red: 0.08, green: 0.16, blue: 0.30))
            )

            // 2. Soft overhead light gradient
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

            // 3. Fine grid
            drawGrid(context, size, spacing: 44,
                     color: .cyan, opacity: 0.080, lineWidth: 0.5)

            // 4. Coarser structural grid
            drawGrid(context, size, spacing: 176,
                     color: .cyan, opacity: 0.160, lineWidth: 0.6)

            // 5. Crosshair guides
            drawCrossHair(context, size)

            // 6. Concentric circle guides
            drawCircleGuides(context, size)

            // 7. Corner registration ticks
            drawCornerTicks(context, size)

            // 8. Vignette
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .radialGradient(
                    Gradient(stops: [
                        .init(color: .clear,               location: 0.0),
                        .init(color: .black.opacity(0.10), location: 0.75),
                        .init(color: .black.opacity(0.28), location: 1.0)
                    ]),
                    center: CGPoint(x: size.width / 2, y: size.height / 2),
                    startRadius: 0,
                    endRadius: hypot(size.width, size.height) * 0.55
                )
            )
        }
        .drawingGroup()  // cache the entire Canvas as a Metal texture
    }

    // MARK: - Phase colour glow (redraws only when phaseColor changes)

    private var phaseGlow: some View {
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
    }

    // MARK: - Ambient pulse ring (CA animated, separate from Canvas)

    private var ambientPulseRing: some View {
        // A thin cyan ring that breathes slowly — period ~8s.
        // The scale is applied via CA via withAnimation(.repeatForever)
        // so this view is never re-evaluated per animation frame.
        GeometryReader { geo in
            let base = min(geo.size.width, geo.size.height) * 0.44 * 1.35
            Circle()
                .stroke(Color.cyan.opacity(0.045 * max(0, 1 - attentionDimFactor + 0.3)),
                        lineWidth: 1.0)
                .frame(width: base * 2, height: base * 2)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }

    // MARK: - CA animation lifecycle

    private func startAmbientAnimation() {
        guard isAmbientAnimating else { stopAmbientAnimation(); return }
        pulseScale = 0.95   // reset without animation
        withAnimation(
            .easeInOut(duration: 4.0)   // 8s full cycle (4s each way)
            .repeatForever(autoreverses: true)
        ) {
            pulseScale = 1.20   // expand 20% — gentle breathing
        }
        bgLog.info("[RenderPerf] background cadence=CA_ambient_breath animationPaused=false")
    }

    private func stopAmbientAnimation() {
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) { pulseScale = 1.0 }
        bgLog.info("[RenderPerf] background cadence=static animationPaused=true reason=ambient_off_or_inactive")
    }

    // MARK: - Canvas drawing helpers

    private func drawGrid(_ ctx: GraphicsContext,
                          _ size: CGSize,
                          spacing: CGFloat,
                          color: Color = .white,
                          opacity: Double,
                          lineWidth: CGFloat) {
        var path = Path()
        var x: CGFloat = 0
        while x <= size.width  { path.move(to: CGPoint(x: x, y: 0));          path.addLine(to: CGPoint(x: x, y: size.height)); x += spacing }
        var y: CGFloat = 0
        while y <= size.height { path.move(to: CGPoint(x: 0, y: y));          path.addLine(to: CGPoint(x: size.width, y: y));  y += spacing }
        ctx.stroke(path, with: .color(color.opacity(opacity)), lineWidth: lineWidth)
    }

    private func drawCrossHair(_ ctx: GraphicsContext, _ size: CGSize) {
        let cx = size.width / 2; let cy = size.height / 2
        let reach = min(size.width, size.height) * 0.44
        var path = Path()
        path.move(to: CGPoint(x: cx - reach, y: cy)); path.addLine(to: CGPoint(x: cx + reach, y: cy))
        path.move(to: CGPoint(x: cx, y: cy - reach)); path.addLine(to: CGPoint(x: cx, y: cy + reach))
        ctx.stroke(path, with: .color(Color.cyan.opacity(0.12)), lineWidth: 0.6)
    }

    private func drawCircleGuides(_ ctx: GraphicsContext, _ size: CGSize) {
        let cx = size.width / 2; let cy = size.height / 2
        let base = min(size.width, size.height) * 0.44
        for (factor, opacity) in [(0.52, 0.10), (0.80, 0.06), (1.10, 0.035)] as [(Double, Double)] {
            let r = base * factor
            ctx.stroke(Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)),
                       with: .color(Color.cyan.opacity(opacity)), lineWidth: 0.6)
        }
    }

    private func drawCornerTicks(_ ctx: GraphicsContext, _ size: CGSize) {
        let pad: CGFloat = 28; let len: CGFloat = 22
        var path = Path()
        // TL
        path.move(to: CGPoint(x: pad, y: pad + len)); path.addLine(to: CGPoint(x: pad, y: pad)); path.addLine(to: CGPoint(x: pad + len, y: pad))
        // TR
        path.move(to: CGPoint(x: size.width - pad - len, y: pad)); path.addLine(to: CGPoint(x: size.width - pad, y: pad)); path.addLine(to: CGPoint(x: size.width - pad, y: pad + len))
        // BL
        path.move(to: CGPoint(x: pad, y: size.height - pad - len)); path.addLine(to: CGPoint(x: pad, y: size.height - pad)); path.addLine(to: CGPoint(x: pad + len, y: size.height - pad))
        // BR
        path.move(to: CGPoint(x: size.width - pad - len, y: size.height - pad)); path.addLine(to: CGPoint(x: size.width - pad, y: size.height - pad)); path.addLine(to: CGPoint(x: size.width - pad, y: size.height - pad - len))
        ctx.stroke(path, with: .color(Color.cyan.opacity(0.22)), lineWidth: 1.0)
    }
}
