import SwiftUI
import CoreGraphics

// MARK: - Target Bracket (animated corner brackets, POI style)

struct TargetBracketView: View {
    let target: TrackedTarget
    let frameSize: CGSize
    @State private var animationPhase: CGFloat = 0
    @State private var lockPhase: CGFloat = 0
    @State private var appeared: Bool = false

    private var rect: CGRect {
        CGRect(
            x: target.bounds.minX * frameSize.width,
            y: target.bounds.minY * frameSize.height,
            width: target.bounds.width * frameSize.width,
            height: target.bounds.height * frameSize.height
        )
    }

    private var bracketColor: Color { target.threatLevel.color }
    private var bracketOpacity: Double { target.isGhost ? 0.35 : (appeared ? 0.92 : 0.0) }
    private var cornerLen: CGFloat { min(rect.width, rect.height) * 0.22 }
    private var lineWidth: CGFloat { 1.5 }

    var body: some View {
        ZStack {
            // Bracket corners
            BracketShape(cornerLength: cornerLen, inset: 0)
                .stroke(bracketColor, lineWidth: lineWidth)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .opacity(bracketOpacity)

            // Inner pulse ring when threat > normal
            if target.threatLevel > .normal && !target.isGhost {
                Circle()
                    .stroke(bracketColor, lineWidth: 0.5)
                    .frame(width: min(rect.width, rect.height) * 0.5)
                    .position(x: rect.midX, y: rect.midY)
                    .opacity(0.4 + 0.3 * sin(animationPhase * Double.pi * 2))
            }

            // Label block
            VStack(alignment: .leading, spacing: 1) {
                Text(target.trackLabel)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(bracketColor)
                if VisionSettings.shared.showConfidenceValues {
                    Text(String(format: "%.0f%%", target.confidence * 100))
                        .font(.system(size: 8, weight: .regular, design: .monospaced))
                        .foregroundStyle(bracketColor.opacity(0.7))
                }
                Text(target.cls.label)
                    .font(.system(size: 8, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(.black.opacity(0.55))
            .position(x: rect.minX + rect.width * 0.5,
                      y: rect.maxY + 10)
            .opacity(bracketOpacity)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.25)) { appeared = true }
        }
        .animation(.linear(duration: 1.5).repeatForever(autoreverses: false), value: animationPhase)
        .onAppear {
            animationPhase = 1.0
        }
    }
}

// MARK: - BracketShape — four L-shaped corner brackets

private struct BracketShape: Shape {
    let cornerLength: CGFloat
    let inset: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = rect.insetBy(dx: inset, dy: inset)
        let cl = min(cornerLength, min(r.width, r.height) * 0.4)

        // Top-left
        p.move(to: CGPoint(x: r.minX, y: r.minY + cl))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + cl, y: r.minY))
        // Top-right
        p.move(to: CGPoint(x: r.maxX - cl, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + cl))
        // Bottom-right
        p.move(to: CGPoint(x: r.maxX, y: r.maxY - cl))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - cl, y: r.maxY))
        // Bottom-left
        p.move(to: CGPoint(x: r.minX + cl, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - cl))

        return p
    }
}

// MARK: - Scanline Overlay

struct ScanlineOverlay: View {
    var spacing: CGFloat = 3.5
    var opacity: Double = 0.045
    @State private var scrollOffset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                ctx.opacity = opacity
                var y: CGFloat = scrollOffset.truncatingRemainder(dividingBy: spacing * 2)
                while y < size.height {
                    ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.black))
                    y += spacing
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear {
            withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) {
                scrollOffset = 100
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Grid Overlay

struct GridOverlay: View {
    var columns: Int = 8
    var rows: Int = 6
    var color: Color = .cyan
    var opacity: Double = 0.06

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                ctx.opacity = opacity
                let cw = size.width / CGFloat(columns)
                let rh = size.height / CGFloat(rows)
                for i in 0...columns {
                    let x = CGFloat(i) * cw
                    ctx.stroke(Path { p in
                        p.move(to: CGPoint(x: x, y: 0))
                        p.addLine(to: CGPoint(x: x, y: size.height))
                    }, with: .color(color), lineWidth: 0.5)
                }
                for j in 0...rows {
                    let y = CGFloat(j) * rh
                    ctx.stroke(Path { p in
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: size.width, y: y))
                    }, with: .color(color), lineWidth: 0.5)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - VHS Noise (subtle static texture)

struct VHSNoiseOverlay: View {
    @State private var noisePhase: CGFloat = 0
    var intensity: Double = 0.03

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08)) { _ in
            Canvas { ctx, size in
                ctx.opacity = intensity
                // Draw sparse random pixels
                let step: CGFloat = 4
                var y: CGFloat = 0
                while y < size.height {
                    var x: CGFloat = CGFloat.random(in: 0..<step)
                    while x < size.width {
                        let brightness = CGFloat.random(in: 0.3...1.0)
                        ctx.fill(
                            Path(CGRect(x: x, y: y, width: 1, height: 1)),
                            with: .color(Color(white: Double(brightness)))
                        )
                        x += step + CGFloat.random(in: 0..<(step * 3))
                    }
                    y += step
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Target Lock Animation

struct TargetLockView: View {
    let color: Color
    @State private var rotation: Double = 0
    @State private var scale: CGFloat = 1.4
    @State private var opacity: Double = 0

    var body: some View {
        ZStack {
            // Rotating ring segments
            ForEach(0..<4, id: \.self) { i in
                Arc(startAngle: .degrees(Double(i) * 90), endAngle: .degrees(Double(i) * 90 + 60))
                    .stroke(color, lineWidth: 2)
                    .rotationEffect(.degrees(rotation))
            }
            // Cross-hair
            CrossHairShape()
                .stroke(color.opacity(0.7), lineWidth: 1)
                .frame(width: 24, height: 24)
        }
        .frame(width: 48, height: 48)
        .scaleEffect(scale)
        .opacity(opacity)
        .onAppear {
            withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                rotation = 360
            }
            withAnimation(.easeOut(duration: 0.3)) {
                scale = 1.0
                opacity = 1.0
            }
        }
    }
}

private struct Arc: Shape {
    var startAngle: Angle
    var endAngle: Angle

    func path(in rect: CGRect) -> Path {
        Path { p in
            p.addArc(center: CGPoint(x: rect.midX, y: rect.midY),
                     radius: min(rect.width, rect.height) / 2,
                     startAngle: startAngle,
                     endAngle: endAngle,
                     clockwise: false)
        }
    }
}

private struct CrossHairShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.midY - 4))
            p.move(to: CGPoint(x: rect.midX, y: rect.midY + 4))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            p.move(to: CGPoint(x: rect.minX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.midX - 4, y: rect.midY))
            p.move(to: CGPoint(x: rect.midX + 4, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
    }
}

// MARK: - HUD Timestamp

struct HUDTimestampView: View {
    @State private var now = Date()
    let cameraName: String
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 8) {
            Text("●")
                .foregroundStyle(.red)
                .font(.system(size: 8))
            Text("REC")
                .foregroundStyle(.red)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
            Text(cameraName.uppercased())
                .foregroundStyle(.white.opacity(0.8))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
            Spacer()
            Text(now.formatted(.dateTime.hour().minute().second()))
                .foregroundStyle(.white.opacity(0.7))
                .font(.system(size: 9, weight: .regular, design: .monospaced))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.black.opacity(0.6))
        .onReceive(timer) { _ in now = Date() }
    }
}

// MARK: - Threat Status Bar

struct ThreatStatusBar: View {
    let threatLevel: ThreatLevel
    let targetCount: Int
    @State private var pulse: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            // Threat indicator
            HStack(spacing: 4) {
                Circle()
                    .fill(threatLevel.color)
                    .frame(width: 8, height: 8)
                    .opacity(pulse ? 1.0 : 0.4)
                Text(threatLevel.systemLabel)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(threatLevel.color)
            }
            .animation(.easeInOut(duration: 0.6).repeatForever(), value: pulse)
            .onAppear { pulse = true }

            Divider()
                .frame(height: 12)
                .background(.white.opacity(0.2))

            Text("\(targetCount) TARGET\(targetCount == 1 ? "" : "S")")
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))

            Spacer()

            Text("JARVIS VISION ACTIVE")
                .font(.system(size: 9, weight: .regular, design: .monospaced))
                .foregroundStyle(.cyan.opacity(0.6))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.black.opacity(0.75))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(threatLevel.color.opacity(0.5))
                .frame(height: 1)
        }
    }
}

// MARK: - Velocity Vector Overlay

struct VelocityVectorView: View {
    let target: TrackedTarget
    let frameSize: CGSize

    var body: some View {
        let cx = target.bounds.midX * frameSize.width
        let cy = target.bounds.midY * frameSize.height
        let magnitude = sqrt(target.velocity.dx * target.velocity.dx + target.velocity.dy * target.velocity.dy)
        guard magnitude > 0.02 else { return AnyView(EmptyView()) }

        let scale: CGFloat = 60
        let dx = target.velocity.dx * scale
        let dy = target.velocity.dy * scale

        return AnyView(
            Canvas { ctx, _ in
                ctx.opacity = 0.7
                ctx.stroke(
                    Path { p in
                        p.move(to: CGPoint(x: cx, y: cy))
                        p.addLine(to: CGPoint(x: cx + dx, y: cy + dy))
                    },
                    with: .color(target.threatLevel.color),
                    lineWidth: 1.5
                )
            }
            .allowsHitTesting(false)
        )
    }
}
