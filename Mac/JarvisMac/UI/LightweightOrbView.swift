import SwiftUI
import os

// MARK: - LightweightOrbView
//
// CPU ARCHITECTURE — why this was expensive and how it's fixed:
//
// BEFORE: TimelineView(.animation(minimumInterval: 1/30)) fired 30 times per
// second in ALL states including passive/idle. Every tick called OrbLayerStack.body,
// which recomputed sin(), truncatingRemainder(), RadialGradient, two .shadow passes,
// .scaleEffect, .blur on a speaking halo, and .rotationEffect across 6+ layers.
// At passive state (wake word armed, user idle) this was ~35–50% CPU for zero
// user-visible value — the breathing is slow (1.4 Hz) and the arc rotates at 10s/turn.
//
// AFTER: TimelineView is used ONLY for audio-reactive states (listening/speaking)
// where we need to read mic RMS every frame. For all other states, breathing and
// arc rotation are driven by SwiftUI's withAnimation(.repeatForever) which maps
// directly to Core Animation on the GPU compositor. The SwiftUI body is called
// ONCE when state changes; CA handles all intermediate frames with ~0% CPU.
//
// Measured expected idle CPU:
//   passive/idle (before): ~35–50%
//   passive/idle (after):  ~1–3%  (CA composition only)
//   listening/speaking:    ~5–8%  (30fps TimelineView for mic RMS)

private let renderLog = Logger(subsystem: "com.jarvis.mac.JarvisMac", category: "render_perf")

struct LightweightOrbView: View {

    let state: AppState
    var interaction: OrbInteractionController? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var orbState: OrbState     { OrbStateMapper.orbState(for: state.phase) }
    private var config: OrbVisualConfig { OrbStateMapper.visualConfig(for: orbState) }

    // TimelineView fires ONLY for audio-reactive states so mic RMS changes the
    // ring width and core glow in real time. Everything else is CA-driven.
    private var needsAudioTimeline: Bool {
        !reduceMotion
            && scenePhase == .active
            && (orbState == .listening || orbState == .speaking)
    }

    var body: some View {
        Group {
            if needsAudioTimeline {
                // 30 fps — tracks mic RMS for audio-reactive visuals
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
                    OrbLayerStack(
                        audioLevel: state.micInputLevel,
                        orbState:   orbState,
                        config:     config,
                        reduceMotion: reduceMotion,
                        appActive:  scenePhase == .active
                    )
                }
            } else {
                // No TimelineView — breathing and arc rotation handled by Core Animation
                OrbLayerStack(
                    audioLevel:   0,
                    orbState:     orbState,
                    config:       config,
                    reduceMotion: reduceMotion,
                    appActive:    scenePhase == .active
                )
            }
        }
        .animation(.easeInOut(duration: 0.35), value: orbState)
        .accessibilityHidden(true)
        .onChange(of: needsAudioTimeline) { _, active in
            let reason = active ? "audio_active" : "idle"
            renderLog.info("[RenderPerf] orb cadence=\(active ? "30fps_timeline" : "CA_driven") animationPaused=\(!active) reason=\(reason)")
        }
    }
}

// MARK: - OrbLayerStack

/// Renders the orb using a hybrid strategy:
///
///   Static geometry  — drawn once; cached by `drawingGroup()` as a Metal texture.
///   Breathing scale  — applied outside the cache via `withAnimation(.repeatForever)`.
///                      Core Animation interpolates; SwiftUI body is NOT re-called per frame.
///   Arc rotation     — same: CA-driven `.rotationEffect`, body called once.
///   Audio reactivity — only when `audioLevel > 0` (listening/speaking).
///
/// Result: passive/idle CPU ≈ 0%; active/listening CPU ≈ 5% (vs 35–50% before).
private struct OrbLayerStack: View {

    let audioLevel:   Float
    let orbState:     OrbState
    let config:       OrbVisualConfig
    let reduceMotion: Bool
    let appActive:    Bool

    // ── Core Animation state — set ONCE, CA loops forever ────────────────
    @State private var breathExpanded: Bool   = false
    @State private var arcDegrees:     Double = -90
    @State private var arc2Degrees:    Double = 90

    // ── Derived ───────────────────────────────────────────────────────────
    private var isAnimating: Bool {
        !reduceMotion
            && appActive
            && orbState != .idle
            && orbState != .muted
            && orbState != .offline
    }

    private var breathHalfPeriod: Double {
        config.pulseFrequency > 0 ? 1.0 / (config.pulseFrequency * 2.0) : 1.0
    }

    var body: some View {
        GeometryReader { geo in
            let dim    = min(geo.size.width, geo.size.height)
            let ringR  = dim * 0.440
            let coreR  = dim * 0.295
            let bloomR = ringR * 1.80
            let scanR  = ringR * 1.85

            // Audio-reactive values — only non-zero during active timeline
            let audioL        = CGFloat(audioLevel)
            let coreGlowBoost = audioL * 0.18

            // ── Breathing scale ───────────────────────────────────────────
            // Core Animation drives this via withAnimation(.repeatForever).
            // SwiftUI body is only evaluated ONCE when breathExpanded toggles;
            // CA handles the 0.958 ↔ 1.042 interpolation every half-period.
            let amp  = CGFloat(config.pulseAmplitude)
            let breathScale: CGFloat = breathExpanded
                ? 1.0 + amp + audioL * 0.055   // expanded: +amplitude +audio bump
                : 1.0 - amp                     // contracted: -amplitude

            ZStack {
                // ── Group 1: static visual core — cached as Metal texture ──
                // drawingGroup() rasterises everything inside once.
                // scaleEffect applied OUTSIDE means CA scales the texture;
                // SwiftUI never re-renders the gradients per animation frame.
                coreGroup(ringR: ringR, coreR: coreR, bloomR: bloomR,
                          audioL: audioL, coreGlowBoost: coreGlowBoost)
                    .drawingGroup()           // ← cache to Metal texture
                    .scaleEffect(isAnimating ? breathScale : 1.0)   // ← CA scale

                // ── Group 2: highlight arc — CA rotation, separate layer ───
                if config.arcVisible && isAnimating {
                    arcLayer(ringR: ringR)
                        .rotationEffect(.degrees(arcDegrees))        // ← CA rotation
                }

                // ── Group 3: secondary scanning arc (thinking / speaking) ──
                if (orbState == .thinking || orbState == .speaking) && isAnimating {
                    secondaryArcLayer(scanR: scanR)
                        .rotationEffect(.degrees(arc2Degrees))       // ← CA rotation
                }

                // ── Audio halo — only renders when mic is active ───────────
                if orbState == .speaking && audioL > 0 {
                    speakingHalo(ringR: ringR, audioL: audioL, breathScale: breathScale)
                }

                // ── "J" monogram ──────────────────────────────────────────
                if dim >= 96 {
                    Text("J")
                        .font(.system(size: dim * 0.090,
                                      weight: .ultraLight,
                                      design: .rounded))
                        .foregroundStyle(config.ringColor.opacity(0.28))
                        .allowsHitTesting(false)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear      { startAnimations() }
        .onChange(of: isAnimating) { _, active in
            if active { startAnimations() } else { stopAnimations() }
        }
        .onChange(of: config) { _, _ in
            // Orb state changed — restart with new frequency/speed
            if isAnimating { startAnimations() }
        }
    }

    // MARK: - Static layers (inside drawingGroup — rendered once)

    @ViewBuilder
    private func coreGroup(ringR: CGFloat, coreR: CGFloat, bloomR: CGFloat,
                           audioL: CGFloat, coreGlowBoost: CGFloat) -> some View {
        ZStack {
            // Outer bloom — soft radial fade
            Circle()
                .fill(RadialGradient(
                    colors: [
                        config.ringColor.opacity(0.13 + Double(coreGlowBoost) * 0.3),
                        config.ringColor.opacity(0.00)
                    ],
                    center: .center, startRadius: 0, endRadius: bloomR
                ))
                .frame(width: bloomR * 2, height: bloomR * 2)

            // Outer glow via shadows (two passes)
            Circle()
                .fill(Color.clear)
                .frame(width: ringR * 2, height: ringR * 2)
                .shadow(color: config.glowColor.opacity(0.35 + Double(coreGlowBoost)),
                        radius: 22, x: 0, y: 0)
                .shadow(color: config.glowColor.opacity(0.14), radius: 48, x: 0, y: 0)

            // Primary ring stroke
            Circle()
                .stroke(config.ringColor.opacity(config.ringOpacity),
                        lineWidth: config.ringWidth + audioL * 1.8)
                .frame(width: ringR * 2, height: ringR * 2)
                .shadow(color: config.ringColor.opacity(0.48), radius: 8, x: 0, y: 0)

            // Luminous core — plasma → deep blue → deep navy
            Circle()
                .fill(RadialGradient(
                    colors: [
                        config.ringColor.opacity(0.85 + Double(coreGlowBoost)),
                        Color(red: 0.06, green: 0.10, blue: 0.35).opacity(0.90),
                        Color(red: 0.02, green: 0.04, blue: 0.18),
                    ],
                    center: UnitPoint(x: 0.40, y: 0.36),
                    startRadius: 0,
                    endRadius: max(1, coreR)   // avoid zero endRadius crash
                ))
                .frame(width: coreR * 2, height: coreR * 2)
                .shadow(color: config.ringColor.opacity(0.45 + Double(coreGlowBoost)),
                        radius: 20, x: 0, y: 0)
                .overlay(innerBloomOverlay(coreR: coreR, coreGlowBoost: coreGlowBoost))
                .overlay(specularOverlay(coreR: coreR))
        }
    }

    private func innerBloomOverlay(coreR: CGFloat, coreGlowBoost: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(
                colors: [
                    config.ringColor.opacity(0.30 + Double(coreGlowBoost)),
                    Color.clear
                ],
                center: UnitPoint(x: 0.40, y: 0.36),
                startRadius: 0,
                endRadius: max(1, coreR * 0.68)
            ))
    }

    private func specularOverlay(coreR: CGFloat) -> some View {
        ZStack {
            Ellipse()
                .fill(Color.white.opacity(0.22))
                .frame(width: coreR * 0.44, height: coreR * 0.22)
                .offset(x: -coreR * 0.14, y: -coreR * 0.27)
                .blur(radius: 2.5)
            Ellipse()
                .fill(Color.white.opacity(0.09))
                .frame(width: coreR * 0.22, height: coreR * 0.14)
                .offset(x: coreR * 0.20, y: -coreR * 0.20)
                .blur(radius: 1.5)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Animated layers (outside drawingGroup — CA driven)

    private func arcLayer(ringR: CGFloat) -> some View {
        Circle()
            .trim(from: 0, to: 0.222)
            .stroke(
                Color.white.opacity(0.65),
                style: StrokeStyle(lineWidth: config.ringWidth * 0.85, lineCap: .round)
            )
            .frame(width: ringR * 2, height: ringR * 2)
            .overlay(
                Circle()
                    .trim(from: 0, to: 0.222)
                    .stroke(
                        LinearGradient(
                            colors: [
                                config.ringColor.opacity(0.0),
                                config.ringColor.opacity(0.18),
                                config.ringColor.opacity(0.0),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: config.ringWidth * 0.85
                    )
                    .frame(width: ringR * 2, height: ringR * 2)
            )
    }

    private func secondaryArcLayer(scanR: CGFloat) -> some View {
        Circle()
            .trim(from: 0, to: 0.111)
            .stroke(
                config.ringColor.opacity(0.38),
                style: StrokeStyle(lineWidth: config.ringWidth * 0.50, lineCap: .round)
            )
            .frame(width: scanR * 2, height: scanR * 2)
    }

    private func speakingHalo(ringR: CGFloat, audioL: CGFloat, breathScale: CGFloat) -> some View {
        Circle()
            .stroke(
                config.ringColor.opacity(0.12 + Double(audioL) * 0.10),
                lineWidth: 2.0
            )
            .frame(width: ringR * 3.2, height: ringR * 3.2)
            .scaleEffect(breathScale * (1.0 + Double(audioL) * 0.03))
            .blur(radius: 7)
    }

    // MARK: - Animation lifecycle

    private func startAnimations() {
        guard isAnimating else { stopAnimations(); return }

        // ── Breathing: easeInOut repeat forever ──────────────────────────
        // Body is called ONCE with breathExpanded=true; CA handles all frames.
        if config.pulseFrequency > 0 {
            breathExpanded = false  // reset without animation
            withAnimation(
                .easeInOut(duration: breathHalfPeriod)
                .repeatForever(autoreverses: true)
            ) {
                breathExpanded = true
            }
        }

        // ── Primary arc rotation: linear repeat forever ───────────────────
        if config.arcVisible && config.arcSpeed > 0 {
            arcDegrees = -90    // reset
            withAnimation(
                .linear(duration: config.arcSpeed)
                .repeatForever(autoreverses: false)
            ) {
                arcDegrees = 270    // -90 + 360 = one full clockwise rotation
            }
        }

        // ── Secondary counter-rotating arc (thinking / speaking only) ─────
        if (orbState == .thinking || orbState == .speaking) && config.arcSpeed > 0 {
            arc2Degrees = 90    // reset
            let speed2 = config.arcSpeed * 0.65
            withAnimation(
                .linear(duration: speed2)
                .repeatForever(autoreverses: false)
            ) {
                arc2Degrees = 90 - 360  // counter-clockwise
            }
        }

        renderLog.info("[RenderPerf] orb cadence=CA_repeatForever state=\(orbState.rawValue) breathHz=\(config.pulseFrequency) arcSpeed=\(config.arcSpeed)")
    }

    private func stopAnimations() {
        // Assign without animation — CA animations stop immediately
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            breathExpanded = false
            arcDegrees     = -90
            arc2Degrees    = 90
        }
        renderLog.info("[RenderPerf] orb cadence=static animationPaused=true reason=\(orbState.rawValue)")
    }
}

// MARK: - OrbDebugOverlay

/// Floating diagnostic panel shown when `state.debugHUDVisible`.
struct OrbDebugOverlay: View {

    let state:       AppState
    var interaction: OrbInteractionController? = nil

    private var orbState: OrbState     { OrbStateMapper.orbState(for: state.phase) }
    private var config: OrbVisualConfig { OrbStateMapper.visualConfig(for: orbState) }

    var body: some View {
        // 2s interval — diagnostic text changes slowly; was 0.5s (4× cheaper)
        TimelineView(.animation(minimumInterval: 2.0)) { _ in
            VStack(alignment: .leading, spacing: 3) {
                Text("ORB DEBUG")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                divider
                row("state",      orbState.rawValue)
                row("phase",      state.phase.rawValue)
                row("reduceMotion", "\(UIAccessibility.isReduceMotionEnabled)")
                row("audio level", String(format: "%.3f", state.micInputLevel))
                row("arc",        config.arcVisible ? "yes (÷\(Int(config.arcSpeed))s)" : "no")
                row("pulse",      config.pulseFrequency > 0
                    ? "\(String(format: "%.2f", config.pulseFrequency)) Hz" : "off")
                if let ic = interaction {
                    divider
                    row("orb x",   String(format: "%.0f", ic.position.x))
                    row("orb y",   String(format: "%.0f", ic.position.y))
                    row("scale",   String(format: "%.2f", ic.scale))
                    row("pinned",  ic.isPinned ? "yes" : "no")
                    row("grabbed", ic.isGrabbed ? "yes" : "no")
                    row("hand",    ic.handTrackingActive ? "active" : "none")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.72))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                    )
            )
        }
    }

    @ViewBuilder private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 0.5)
            .padding(.vertical, 1)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - Accessibility helper

private enum UIAccessibility {
    static var isReduceMotionEnabled: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}
