import SwiftUI

// MARK: - SpatialInteractionLayer

/// Full-stage ambient spatial interaction layer.
///
/// Mounted directly in `CommandCentreView` as a transparent ZStack layer
/// that spans the entire Jarvis window. It is ALWAYS present — it just
/// fades in when a hand is detected and fades out when the hand leaves.
///
/// Does NOT block mouse events (`allowsHitTesting(false)` on all children).
/// Does NOT own a camera — it reads from the shared `SpatialAmbientCoordinator`.
/// Does NOT require a voice command to activate — spatial presence is ambient.
struct SpatialInteractionLayer: View {

    @ObservedObject var coordinator: SpatialAmbientCoordinator
    /// Whether any overlay panel is currently open — used to compute orb position.
    let hasOverlay: Bool

    private var layerOpacity: Double {
        coordinator.presenceState == .noHand ? 0.0 : 1.0
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // ── Orb hover ring ─────────────────────────────────────────────
                // Glowing ring appears around the Jarvis orb when the cursor is near.
                if coordinator.orbIsHovered {
                    OrbHoverRing()
                        .position(coordinator.physics.orbPosition)
                        .allowsHitTesting(false)
                }

                // ── Primary cursor ─────────────────────────────────────────────
                if coordinator.cursorState.isVisible {
                    // Confidence ring behind cursor (eligibility visualisation)
                    if coordinator.currentGesture == .handCandidate ||
                       coordinator.currentGesture == .handEligible ||
                       coordinator.currentGesture == .pointerActive {
                        GestureConfidenceRing(
                            eligibility: coordinator.cursorState.eligibilityScore,
                            intent:      coordinator.cursorState.intentScore
                        )
                        .position(coordinator.cursorState.position)
                        .allowsHitTesting(false)
                    }

                    // Pinch readiness ring (fills during pinchCandidate dwell)
                    if coordinator.currentGesture == .pinchCandidate {
                        PinchReadinessRing()
                            .position(coordinator.cursorState.position)
                            .allowsHitTesting(false)
                    }

                    // Suppressed indicator (orange pulse)
                    if coordinator.currentGesture == .suppressed {
                        SuppressedIndicator()
                            .position(coordinator.cursorState.position)
                            .allowsHitTesting(false)
                    }

                    // Main cursor
                    SpatialCursorView(
                        isPinching:    coordinator.cursorState.isPinching,
                        magneticScale: coordinator.cursorState.magneticScale,
                        isSuppressed:  coordinator.cursorState.isSuppressed
                    )
                    .position(coordinator.cursorState.position)
                    .allowsHitTesting(false)
                }

                // ── Secondary cursor (two-hand) ────────────────────────────────
                if coordinator.secondaryCursorState.isVisible {
                    SpatialCursorView(
                        isPinching:    coordinator.secondaryCursorState.isPinching,
                        magneticScale: coordinator.secondaryCursorState.magneticScale
                    )
                    .position(coordinator.secondaryCursorState.position)
                    .opacity(0.55)   // slightly dimmer than primary
                    .allowsHitTesting(false)
                }

                // ── Spread gesture indicator ───────────────────────────────────
                if coordinator.spreadGestureActive,
                   coordinator.cursorState.isVisible,
                   coordinator.secondaryCursorState.isVisible {
                    SpreadGestureIndicator(
                        from: coordinator.cursorState.position,
                        to:   coordinator.secondaryCursorState.position
                    )
                    .allowsHitTesting(false)
                }

                // ── Radial HUD menu ────────────────────────────────────────────
                if coordinator.isHUDOpen {
                    SpatialRadialHUD(
                        coordinator: coordinator,
                        viewSize:    geo.size
                    )
                    .allowsHitTesting(false)
                    .transition(
                        .scale(scale: 0.65).combined(with: .opacity)
                    )
                }
            }
            .onAppear {
                coordinator.viewSize = geo.size
                updateOrbPosition(size: geo.size)
                coordinator.physics.placeOrb(at: coordinator.orbRestPosition)
            }
            .onChange(of: geo.size) { _, newSize in
                coordinator.viewSize = newSize
                updateOrbPosition(size: newSize)
            }
            .onChange(of: hasOverlay) { _, _ in
                updateOrbPosition(size: geo.size)
            }
        }
        .opacity(layerOpacity)
        .animation(.easeInOut(duration: 0.40), value: coordinator.presenceState)
        .animation(.spring(response: 0.28, dampingFraction: 0.72),
                   value: coordinator.isHUDOpen)
        .animation(.easeInOut(duration: 0.25), value: coordinator.orbIsHovered)
    }

    // MARK: Orb position sync

    /// The orb rests at centre-stage when no overlay is open, or in the
    /// bottom-right corner pip position when overlays are active.
    private func updateOrbPosition(size: CGSize) {
        let pos: CGPoint = hasOverlay
            ? CGPoint(x: size.width - 52,    y: size.height - 52)
            : CGPoint(x: size.width * 0.5,   y: size.height * 0.42)
        coordinator.orbRestPosition = pos
    }
}

// MARK: - GestureConfidenceRing

/// Subtle ring behind the cursor that fills/dims with eligibility score.
/// Helps the user understand whether their hand is being "seen" well.
private struct GestureConfidenceRing: View {
    var eligibility: Float   // 0–1
    var intent:      Float   // 0–1

    var body: some View {
        ZStack {
            // Eligibility ring
            Circle()
                .strokeBorder(Color.cyan.opacity(Double(eligibility) * 0.28),
                              lineWidth: 1.5)
                .frame(width: 44, height: 44)

            // Intent ring (inner, brighter)
            Circle()
                .strokeBorder(Color.white.opacity(Double(intent) * 0.20),
                              lineWidth: 1)
                .frame(width: 34, height: 34)
        }
        .animation(.easeOut(duration: 0.12), value: eligibility)
        .animation(.easeOut(duration: 0.12), value: intent)
    }
}

// MARK: - PinchReadinessRing

/// Animated ring that pulses and fills as the pinch candidate dwell counts up.
private struct PinchReadinessRing: View {
    @State private var phase: Double = 0

    var body: some View {
        Circle()
            .strokeBorder(Color.yellow.opacity(0.55), lineWidth: 2)
            .frame(width: 32, height: 32)
            .scaleEffect(1.0 + phase * 0.18)
            .opacity(1.0 - phase * 0.4)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                    phase = 1
                }
            }
    }
}

// MARK: - SuppressedIndicator

/// Brief orange pulse shown when a hand is detected but suppressed.
private struct SuppressedIndicator: View {
    @State private var pulse = false

    var body: some View {
        Circle()
            .strokeBorder(Color.orange.opacity(0.60), lineWidth: 2)
            .frame(width: 38, height: 38)
            .scaleEffect(pulse ? 1.15 : 1.0)
            .opacity(pulse ? 0.4 : 0.75)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}

// MARK: - OrbHoverRing

/// Pulsing cyan glow ring that appears around the Jarvis orb when the
/// spatial cursor enters its hover radius.
private struct OrbHoverRing: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            // Outer ring
            Circle()
                .strokeBorder(Color.cyan.opacity(0.35), lineWidth: 2)
                .frame(width: 96, height: 96)
                .scaleEffect(pulse ? 1.10 : 1.0)

            // Middle ring
            Circle()
                .strokeBorder(Color.cyan.opacity(0.20), lineWidth: 1)
                .frame(width: 116, height: 116)
                .scaleEffect(pulse ? 0.96 : 1.04)

            // Inner fill glow
            Circle()
                .fill(Color.cyan.opacity(0.06))
                .frame(width: 80, height: 80)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

// MARK: - SpreadGestureIndicator

/// Visual connector line shown between the two cursors during a
/// two-hand spread gesture — indicates resize mode is active.
private struct SpreadGestureIndicator: View {
    let from: CGPoint
    let to:   CGPoint

    var body: some View {
        Canvas { ctx, _ in
            var path = Path()
            path.move(to: from)
            path.addLine(to: to)
            ctx.stroke(path,
                       with: .color(Color.cyan.opacity(0.40)),
                       style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
        }
    }
}

// MARK: - SpatialDiagnosticsOverlay

/// Read-only diagnostics card shown in the `.spatialHUD` overlay slot.
/// Opened via "show spatial mode" voice command or ⌘⇧S.
///
/// It does NOT run its own hand tracking — it reads from the shared
/// `SpatialAmbientCoordinator` that is already running passively.
struct SpatialDiagnosticsOverlay: View {

    @ObservedObject var coordinator: SpatialAmbientCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.3)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    stateSection
                    intentScoreSection
                    accidentalMotionSection
                    handConfidenceSection
                    cursorSection
                    faceSection
                    twoHandSection
                    resizeSection
                    cameraSection
                    calibrationSection
                    perfSection
                }
                .padding(20)
            }
        }
        .background(Color.black.opacity(0.88))
        .preferredColorScheme(.dark)
    }

    // MARK: Sub-views

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.cyan)
            Text("Spatial Diagnostics")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Spacer()
            presencePill
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var presencePill: some View {
        let (label, color) = presenceLabelColor
        return HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .shadow(color: color.opacity(0.8), radius: 4)
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .tracking(0.8)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.10)))
        .overlay(Capsule().strokeBorder(color.opacity(0.30)))
        .animation(.easeInOut(duration: 0.20), value: coordinator.presenceState)
    }

    private var presenceLabelColor: (String, Color) {
        switch coordinator.presenceState {
        case .noHand:       return ("No Hand",  .white.opacity(0.4))
        case .handDetected: return ("Tracking",  .cyan)
        case .pinchActive:  return ("Pinching",  .yellow)
        case .hudOpen:      return ("HUD Open",  .green)
        }
    }

    private var stateSection: some View {
        diagSection("Gesture State") {
            diagRow("Presence",   coordinator.presenceState.debugLabel)
            diagRow("Gesture",    coordinator.currentGesture.debugLabel,
                    color: coordinator.currentGesture.accentColor)
            diagRow("HUD open",   coordinator.isHUDOpen ? "Yes" : "No")
            diagRow("Drag",       coordinator.draggingOverlayID != nil ? "active" : "none")
            diagRow("Dwell",      coordinator.dwellItemIndex != nil
                      ? String(format: "%.0f%%", coordinator.dwellProgress * 100) : "—")
            diagRow("Enabled",    coordinator.isEnabled ? "Yes" : "No")
        }
    }

    private var intentScoreSection: some View {
        diagSection("Adaptive Intent Score") {
            diagRow("Eligibility",
                    String(format: "%.2f", coordinator.dbgEligibilityScore),
                    color: scoreColor(coordinator.dbgEligibilityScore))
            diagRow("Intent",
                    String(format: "%.2f", coordinator.dbgIntentScore),
                    color: scoreColor(coordinator.dbgIntentScore))
            diagRow("Gesture likelihood",
                    String(format: "%.2f", coordinator.dbgGestureLikelihood),
                    color: scoreColor(coordinator.dbgGestureLikelihood))
            diagRow("Suppression",
                    coordinator.dbgSuppressionReason,
                    color: coordinator.dbgSuppressionReason == "—" ? .white.opacity(0.4) : .orange)
        }
    }

    private var accidentalMotionSection: some View {
        diagSection("Accidental Motion") {
            diagRow("Detected",
                    coordinator.dbgIsAccidentalMotion ? "YES" : "no",
                    color: coordinator.dbgIsAccidentalMotion ? .orange : .white.opacity(0.4))
            diagRow("Confidence",
                    String(format: "%.2f", coordinator.dbgMotionConfidence),
                    color: coordinator.dbgMotionConfidence > 0.3 ? .orange : .white.opacity(0.5))
        }
    }

    private func scoreColor(_ v: Float) -> Color {
        if v >= 0.7 { return .green }
        if v >= 0.42 { return .cyan }
        if v >= 0.25 { return .yellow }
        return .orange
    }

    private var handConfidenceSection: some View {
        diagSection("Hands Detected") {
            diagRow("Count",         "\(coordinator.dbgHandCount)")
            diagRow("Primary conf",  String(format: "%.2f", coordinator.dbgPrimaryConf),
                    color: coordinator.dbgPrimaryConf >= SpatialInteractionConfig.shared.handConfidenceThreshold
                           ? .cyan : .orange)
            if coordinator.dbgHandCount > 1 {
                let secThresh = SpatialInteractionConfig.shared.secondHandConfidenceThreshold
                diagRow("Secondary conf", String(format: "%.2f", coordinator.dbgSecondaryConf),
                        color: coordinator.dbgSecondaryConf >= secThresh ? .cyan : .orange)
                diagRow("2nd stable frames", "\(coordinator.dbgSecondStableFrames) / \(SpatialInteractionConfig.shared.secondHandDwellFrames)")
                diagRow("2nd rejection",     coordinator.dbgSecondHandRejection,
                        color: coordinator.dbgSecondHandRejection == "—" ? .white.opacity(0.5) : .orange)
            }
            diagRow("Primary suppressed",  coordinator.dbgPrimaryFaceSuppressed ? "YES" : "no",
                    color: coordinator.dbgPrimaryFaceSuppressed ? .red : .white.opacity(0.5))
        }
    }

    private var cursorSection: some View {
        diagSection("Cursor") {
            let cs = coordinator.cursorState
            diagRow("Visible",  cs.isVisible  ? "Yes" : "No")
            diagRow("Pinching", cs.isPinching ? "Yes" : "No")
            diagRow("Raw pos",  String(format: "(%.0f, %.0f)",
                                       coordinator.dbgRawCursorPos.x,
                                       coordinator.dbgRawCursorPos.y))
            diagRow("Smoothed", String(format: "(%.0f, %.0f)",
                                       coordinator.dbgSmoothedCursorPos.x,
                                       coordinator.dbgSmoothedCursorPos.y))
            diagRow("Speed",    String(format: "%.0f pts/s", coordinator.dbgVelocityMagnitude),
                    color: coordinator.dbgVelocityMagnitude > SpatialInteractionConfig.shared.handStabilityMaxSpeedPts
                           ? .orange : .cyan)
            diagRow("Mag scale", String(format: "×%.2f", cs.magneticScale))
        }
    }

    private var faceSection: some View {
        diagSection("Face Rejection") {
            diagRow("Face detected",   coordinator.dbgFaceDetected ? "Yes" : "No",
                    color: coordinator.dbgFaceDetected ? .cyan : .white.opacity(0.4))
            diagRow("Primary suppressed", coordinator.dbgPrimaryFaceSuppressed ? "YES" : "no",
                    color: coordinator.dbgPrimaryFaceSuppressed ? .red : .white.opacity(0.4))
            diagRow("Secondary suppressed", coordinator.dbgSecondFaceSuppressed ? "YES" : "no",
                    color: coordinator.dbgSecondFaceSuppressed ? .red : .white.opacity(0.4))
            if coordinator.dbgPrimaryFaceSuppressed || coordinator.dbgSecondFaceSuppressed {
                diagRow("Reason", coordinator.dbgFaceSuppressionReason, color: .orange)
            }
            diagRow("Padding (norm)", String(format: "±%.2f", SpatialInteractionConfig.shared.facePaddingNorm))
        }
    }

    private var twoHandSection: some View {
        diagSection("Two-Hand") {
            let sc = coordinator.secondaryCursorState
            diagRow("Secondary visible", sc.isVisible ? "Yes" : "No")
            if sc.isVisible {
                diagRow("Secondary pos",
                        String(format: "(%.0f, %.0f)", sc.position.x, sc.position.y))
            }
        }
    }

    private var resizeSection: some View {
        diagSection("Resize Gate") {
            diagRow("Phase",  coordinator.dbgResizePhase,
                    color: coordinator.spreadGestureActive ? .green : .white.opacity(0.6))
            diagRow("Active", coordinator.spreadGestureActive ? "YES" : "no",
                    color: coordinator.spreadGestureActive ? .green : .white.opacity(0.4))
            diagRow("Reason", coordinator.dbgResizeReason)
        }
    }

    private var cameraSection: some View {
        diagSection("Camera") {
            diagRow("Source",     coordinator.cameraSource)
            diagRow("Confidence", String(format: "%.2f", coordinator.trackingConfidence))
            diagRow("Active",     coordinator.isTrackingActive ? "Yes" : "No")
            if let err = coordinator.lastError {
                diagRow("Error", err, color: .red.opacity(0.8))
            }
        }
    }

    private var calibrationSection: some View {
        diagSection("Calibration (Learned)") {
            diagRow("Frames tracked", "\(coordinator.dbgCalibFrames)")
            diagRow("Last adapted",   coordinator.dbgCalibAdaptedAt)
            diagRow("Pinch threshold", coordinator.dbgLearnedPinchDist)
            diagRow("Deadzone",        coordinator.dbgLearnedDeadzone)
            diagRow("Smoothing",       coordinator.dbgLearnedSmoothing)
            diagRow("Pointer sens",    coordinator.dbgLearnedPointerSens)
            diagRow("2nd hand dwell",  coordinator.dbgLearnedSecondDwell)
        }
    }

    private var perfSection: some View {
        diagSection("Performance") {
            let cfg = SpatialInteractionConfig.shared
            diagRow("Tracking FPS",   "\(coordinator.trackingFPS)")
            diagRow("Smoothing α",    String(format: "%.2f", cfg.smoothingAlpha))
            diagRow("Pointer sens",   String(format: "%.0f%%", cfg.pointerSensitivity * 100))
            diagRow("Drag sens",      String(format: "%.0f%%", cfg.dragSensitivity * 100))
            diagRow("Deadzone",       String(format: "%.0f pts", cfg.deadzonePts))
            diagRow("Max jump",       String(format: "%.0f pts", cfg.maxJumpPts))
        }
    }

    @ViewBuilder
    private func diagSection<Content: View>(_ title: String,
                                             @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.35))
                .tracking(1.5)
            VStack(alignment: .leading, spacing: 6) {
                content()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.white.opacity(0.07))))
        }
    }

    private func diagRow(_ key: String, _ value: String,
                          color: Color = .white.opacity(0.75)) -> some View {
        HStack {
            Text(key)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(color)
        }
    }
}

// MARK: - Debug label extensions

private extension SpatialPresenceState {
    var debugLabel: String {
        switch self {
        case .noHand:       return "noHand"
        case .handDetected: return "handDetected"
        case .pinchActive:  return "pinchActive"
        case .hudOpen:      return "hudOpen"
        }
    }
}

private extension SpatialGestureState {
    var debugLabel: String {
        switch self {
        case .disabled:       return "disabled"
        case .idle:           return "idle"
        case .handCandidate:  return "handCandidate"
        case .handEligible:   return "handEligible"
        case .pointerActive:  return "pointerActive"
        case .pinchCandidate: return "pinchCandidate"
        case .pinching:       return "pinching"
        case .pinchRelease:   return "pinchRelease"
        case .suppressed:     return "suppressed"
        case .cooldown:       return "cooldown"
        }
    }
    var accentColor: Color {
        switch self {
        case .disabled:       return .red.opacity(0.5)
        case .idle:           return .white.opacity(0.3)
        case .handCandidate:  return .white.opacity(0.5)
        case .handEligible:   return .white.opacity(0.7)
        case .pointerActive:  return .cyan
        case .pinchCandidate: return .yellow
        case .pinching:       return .orange
        case .pinchRelease:   return .green
        case .suppressed:     return .orange
        case .cooldown:       return .white.opacity(0.45)
        }
    }
}
