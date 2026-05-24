import SwiftUI

// MARK: - OrbWidget

/// The primary floating interaction orb.
///
/// Visual states:
/// - Idle: translucent glass sphere with soft inner glow
/// - Hovered: subtle pulse, glow intensifies
/// - Pinched: orb compresses 8%, glow flares
/// - Dragging: shadow deepens, slight blur behind
struct OrbWidget: View {

    var isPinched:  Bool   = false
    var isHovered:  Bool   = false
    var isDragging: Bool   = false

    /// Base diameter in points.
    var diameter:   CGFloat = 88

    // MARK: Derived visuals

    private var scale: CGFloat {
        if isPinched  { return 0.92 }
        if isHovered  { return 1.04 }
        return 1.0
    }

    private var glowRadius: CGFloat {
        if isPinched  { return 28 }
        if isHovered  { return 18 }
        return 10
    }

    private var glowOpacity: Double {
        if isPinched  { return 0.9 }
        if isHovered  { return 0.65 }
        return 0.40
    }

    private var innerGlowOpacity: Double {
        if isPinched  { return 0.55 }
        if isHovered  { return 0.35 }
        return 0.18
    }

    var body: some View {
        ZStack {
            // ── Outer glow halo ────────────────────────────────────────────
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(glowOpacity * 0.6),
                            Color.cyan.opacity(glowOpacity * 0.3),
                            Color.clear,
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: diameter * 0.85
                    )
                )
                .frame(width: diameter * 1.7, height: diameter * 1.7)
                .blur(radius: glowRadius)
                .allowsHitTesting(false)

            // ── Glass body ────────────────────────────────────────────────
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(0.25),
                            Color.white.opacity(0.08),
                            Color.cyan.opacity(0.06),
                        ],
                        center: UnitPoint(x: 0.35, y: 0.30),
                        startRadius: 0,
                        endRadius: diameter * 0.55
                    )
                )
                .frame(width: diameter, height: diameter)
                .background(
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: diameter, height: diameter)
                )
                .overlay(
                    // Rim light — specular highlight at top-left
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.6),
                                    Color.white.opacity(0.1),
                                    Color.white.opacity(0.0),
                                ],
                                startPoint: UnitPoint(x: 0.2, y: 0.1),
                                endPoint:   UnitPoint(x: 0.8, y: 0.9)
                            ),
                            lineWidth: 1.2
                        )
                )
                // Inner highlight lens flare
                .overlay(
                    Ellipse()
                        .fill(Color.white.opacity(innerGlowOpacity))
                        .frame(width: diameter * 0.30, height: diameter * 0.18)
                        .offset(x: -diameter * 0.14, y: -diameter * 0.22)
                        .blur(radius: 4)
                        .allowsHitTesting(false)
                )
                // Drop shadow
                .shadow(
                    color: Color.cyan.opacity(isDragging ? 0.4 : 0.15),
                    radius: isDragging ? 30 : 12,
                    x: 0, y: isDragging ? 12 : 4
                )
                .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 6)

            // ── Jarvis monogram ───────────────────────────────────────────
            Text("J")
                .font(.system(size: diameter * 0.32, weight: .thin, design: .rounded))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.white.opacity(0.9), Color.cyan.opacity(0.7)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .shadow(color: .cyan.opacity(0.5), radius: 4)
        }
        .scaleEffect(scale)
        .animation(.spring(response: 0.22, dampingFraction: 0.65), value: scale)
        .animation(.easeInOut(duration: 0.15), value: glowOpacity)
    }
}

// MARK: - SpatialCursorView

/// The finger-tracking cursor — a soft glowing ring.
/// When suppressed, the ring turns orange to signal that the hand is
/// detected but not eligible to control UI.
struct SpatialCursorView: View {

    var isPinching:   Bool    = false
    var magneticScale: CGFloat = 1.0
    var isSuppressed: Bool    = false

    private var diameter: CGFloat { isPinching ? 18 : 24 }
    private var outerDiameter: CGFloat { diameter * 2.2 }

    private var ringColor: Color {
        isSuppressed ? .orange : .cyan
    }
    private var ringOpacity: Double { isSuppressed ? 0.55 : 0.5 }

    var body: some View {
        ZStack {
            // Soft outer halo
            Circle()
                .fill(Color.white.opacity(isSuppressed ? 0.04 : 0.06))
                .frame(width: outerDiameter * magneticScale,
                       height: outerDiameter * magneticScale)
                .blur(radius: 6)

            // Ring
            Circle()
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.85), ringColor.opacity(ringOpacity)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: isPinching ? 1.5 : 1.0
                )
                .frame(width: diameter, height: diameter)

            // Center dot
            Circle()
                .fill(Color.white.opacity(isPinching ? 0.9 : 0.5))
                .frame(width: isPinching ? 5 : 3, height: isPinching ? 5 : 3)
        }
        .scaleEffect(magneticScale)
        .animation(.spring(response: 0.20, dampingFraction: 0.7), value: isPinching)
        .animation(.easeOut(duration: 0.12), value: magneticScale)
        .animation(.easeInOut(duration: 0.25), value: isSuppressed)
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color.black
        VStack(spacing: 40) {
            OrbWidget()
            OrbWidget(isHovered: true)
            OrbWidget(isPinched: true)
        }
    }
    .frame(width: 300, height: 400)
}
