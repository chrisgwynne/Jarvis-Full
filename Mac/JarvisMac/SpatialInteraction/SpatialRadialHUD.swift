import SwiftUI

// MARK: - SpatialRadialHUD

/// Cinematic radial HUD that appears when the user pinches in space.
///
/// Items are arranged in a 180° semicircle above the pinch anchor.
/// Each item animates in with a staggered spring pop.
/// The item nearest the fingertip highlights dynamically in cyan.
/// Hovering on an item for 1.5 s triggers it automatically (dwell-click).
///
/// The item set is contextual — when an overlay is focused the menu shows
/// overlay management actions (pin, expand, close) instead of navigation.
///
/// Layout geometry (with 6 items, radius = 110 pt):
///
///          [2]   [3]
///       [1]         [4]
///     [0]             [5]
///            ✦   ← anchor (pinch point)
///
struct SpatialRadialHUD: View {

    @ObservedObject var coordinator: SpatialAmbientCoordinator
    let viewSize: CGSize

    /// Contextual item array — changes when an overlay is focused.
    private var items: [SpatialHUDAction] { coordinator.currentHUDItems }

    var body: some View {
        ZStack {
            // ── Ambient scrim ──────────────────────────────────────────────
            RadialGradient(
                colors: [Color.black.opacity(0.22), Color.clear],
                center: UnitPoint(
                    x: coordinator.hudAnchor.x / max(viewSize.width,  1),
                    y: coordinator.hudAnchor.y / max(viewSize.height, 1)
                ),
                startRadius: 0,
                endRadius: 200
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            // ── Anchor dot ────────────────────────────────────────────────
            Circle()
                .fill(Color.white.opacity(0.25))
                .frame(width: 8, height: 8)
                .shadow(color: .cyan.opacity(0.8), radius: 6)
                .position(coordinator.hudAnchor)
                .allowsHitTesting(false)

            // ── Arc connector lines ───────────────────────────────────────
            HUDArcLines(anchor: coordinator.hudAnchor, count: items.count,
                        coordinator: coordinator)
                .allowsHitTesting(false)

            // ── Action chips ──────────────────────────────────────────────
            ForEach(Array(items.enumerated()), id: \.offset) { index, action in
                let raw = coordinator.radialItemPosition(
                    index:  index,
                    anchor: coordinator.hudAnchor,
                    count:  items.count
                )
                let pos = CGPoint(
                    x: raw.x.clamped(to: 52...(viewSize.width  - 52)),
                    y: raw.y.clamped(to: 52...(viewSize.height - 52))
                )
                let highlighted   = coordinator.highlightedItemIndex == index
                let isDwelling    = coordinator.dwellItemIndex == index
                let dwellProgress = isDwelling ? coordinator.dwellProgress : 0

                SpatialHUDChip(action: action,
                               isHighlighted: highlighted,
                               dwellProgress: dwellProgress)
                    .position(pos)
                    .transition(
                        .scale(scale: 0.4, anchor: .init(
                            x: coordinator.hudAnchor.x / max(viewSize.width,  1),
                            y: coordinator.hudAnchor.y / max(viewSize.height, 1)
                        ))
                        .combined(with: .opacity)
                    )
                    .animation(
                        .spring(response: 0.30, dampingFraction: 0.65)
                            .delay(Double(index) * 0.038),
                        value: coordinator.isHUDOpen
                    )
            }
        }
    }
}

// MARK: - HUDArcLines

private struct HUDArcLines: View {
    let anchor:      CGPoint
    let count:       Int
    let coordinator: SpatialAmbientCoordinator

    var body: some View {
        Canvas { ctx, size in
            for i in 0..<count {
                let chipPos = coordinator.radialItemPosition(
                    index: i, anchor: anchor, count: count)
                let highlighted = coordinator.highlightedItemIndex == i
                var path = Path()
                path.move(to: anchor)
                path.addLine(to: chipPos)
                ctx.stroke(
                    path,
                    with: .color(highlighted
                                 ? Color.cyan.opacity(0.50)
                                 : Color.white.opacity(0.12)),
                    style: StrokeStyle(lineWidth: highlighted ? 1.0 : 0.5,
                                       dash: highlighted ? [] : [4, 6])
                )
            }
        }
    }
}

// MARK: - SpatialHUDChip

/// Individual radial HUD action chip.
///
/// Visual states:
/// - Default:     dim glass circle, light icon
/// - Highlighted: cyan glow, icon brightens, scales up 1.18×
/// - Dwelling:    circular progress arc fills over 1.5 s, then auto-fires
struct SpatialHUDChip: View {
    let action: SpatialHUDAction
    var isHighlighted: Bool = false
    var dwellProgress:  Double = 0   // 0…1; > 0 shows the dwell arc

    private var scale: CGFloat    { isHighlighted ? 1.18 : 1.0 }
    private var glowRadius: CGFloat { isHighlighted ? 16 : 0 }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                // Background glass circle
                Circle()
                    .fill(
                        isHighlighted
                            ? Color.cyan.opacity(0.22)
                            : Color.white.opacity(0.06)
                    )
                    .frame(width: 54, height: 54)
                    .overlay(
                        Circle()
                            .strokeBorder(
                                isHighlighted
                                    ? Color.cyan.opacity(0.90)
                                    : Color.white.opacity(0.16),
                                lineWidth: 1.2
                            )
                    )

                // Dwell progress arc — sweeps around the outside of the chip
                if dwellProgress > 0 {
                    Circle()
                        .trim(from: 0, to: dwellProgress)
                        .stroke(
                            Color.cyan,
                            style: StrokeStyle(lineWidth: 3, lineCap: .round)
                        )
                        .frame(width: 62, height: 62)
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.05), value: dwellProgress)
                }

                // Icon
                Image(systemName: action.systemImage)
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(
                        isHighlighted ? Color.cyan : Color.white.opacity(0.72)
                    )
            }
            .shadow(color: isHighlighted ? Color.cyan.opacity(0.60) : .clear,
                    radius: glowRadius)

            // Label
            Text(action.label)
                .font(.system(size: 10,
                              weight: isHighlighted ? .semibold : .regular,
                              design: .rounded))
                .foregroundStyle(
                    isHighlighted ? Color.cyan : Color.white.opacity(0.50)
                )
        }
        .scaleEffect(scale)
        .animation(.spring(response: 0.22, dampingFraction: 0.65), value: isHighlighted)
    }
}

// MARK: - Comparable clamped helper

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Preview

#Preview("Spatial Radial HUD") {
    ZStack {
        Color.black
        Text("Raise your hand and pinch to open the HUD")
            .font(.system(size: 14, design: .rounded))
            .foregroundStyle(.white.opacity(0.35))
    }
    .frame(width: 800, height: 600)
}
