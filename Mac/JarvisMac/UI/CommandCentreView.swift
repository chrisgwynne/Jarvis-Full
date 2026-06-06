import SwiftUI

/// Single-screen Jarvis view. Orb sits front-and-centre when idle;
/// slides to a compact corner pip when overlay panels are open.
///
/// Visual hierarchy (back to front):
///   1. Blueprint background
///   2. Stage (orb + transcript)
///   3. Overlay panels
///   4. Spatial interaction layer
///   5. Calibration overlay
///   6. File search overlay
///   7. Toast notifications
///   8. Command dashboard (from dock ☰)
///   9. Control dock (bottom-centre, hover to show)
///   10. Debug HUD (developer only, ⌘⇧D)
struct CommandCentreView: View {
    let state: AppState
    let controller: JarvisController

    @State private var isDashboardVisible = false

    private var hasOverlay: Bool {
        !controller.overlayManager.overlays.isEmpty
    }

    var body: some View {
        ZStack {
            // 1. Background
            BlueprintBackgroundView(
                phaseColor: state.phase.accentColor,
                ambientEnabled: state.ambientModeEnabled,
                attentionDimFactor: state.attentionState.ambientDimFactor,
                safeMode: state.safeMode
            )

            // 2. Stage — orb + transcript
            JarvisStageView(state: state, hasOverlay: hasOverlay,
                            useLightweightOrb: controller.prefs.current.useLightweightOrb)

            // 3. Overlay panels
            OverlayHostView(state: state,
                            controller: controller,
                            manager: controller.overlayManager)

            // 4. Spatial interaction layer (non-blocking)
            SpatialInteractionLayer(coordinator: controller.spatialCoordinator,
                                    hasOverlay: hasOverlay)
                .allowsHitTesting(false)

            // 5. Hand calibration
            CalibrationOverlayPresenter(coordinator: controller.spatialCoordinator)

            // 6. File search overlay
            if state.fileSearchOverlayVisible && !state.fileSearchResults.isEmpty {
                VStack {
                    Spacer()
                    FileSearchOverlayView(
                        results: state.fileSearchResults,
                        query: state.fileSearchQuery,
                        systemController: controller.systemController
                    ) {
                        withAnimation(JarvisMotion.normalEase) {
                            state.fileSearchOverlayVisible = false
                        }
                    }
                    .padding(.bottom, 96)
                }
                .transition(JarvisMotion.panel)
                .animation(JarvisMotion.normalEase, value: state.fileSearchOverlayVisible)
            }

            // 7. Toast — auto-fades, bottom-centre
            VStack {
                Spacer()
                CommandResultToast(message: state.toastMessage, icon: state.toastIcon)
                    .padding(.bottom, 96)
            }

            // 8. Command dashboard — slides up from bottom
            if isDashboardVisible {
                CommandDashboardView(state: state,
                                     controller: controller,
                                     isVisible: $isDashboardVisible)
                    .transition(JarvisMotion.panel)
            }

            // 9. Control dock — hover-reveal, bottom-centre
            ControlDockView(state: state,
                            controller: controller,
                            isDashboardVisible: $isDashboardVisible)

            // 10. Debug HUD — developer only, ⌘⇧D to toggle
            if state.debugHUDVisible {
                DebugHUDView(state: state, controller: controller)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .bottomTrailing)
                    .padding(12)
                    .transition(JarvisMotion.panel)
            }

            // 11. Safe Degraded Mode banner — top of screen, dismissable
            if state.safeModeActive {
                VStack {
                    SafeModeBanner(reason: state.safeModeReason) {
                        SelfMonitor.shared.exitSafeDegradedMode()
                    }
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(JarvisMotion.normalEase, value: state.safeModeActive)
            }
        }
        .frame(minWidth: 1100, minHeight: 720)
        .preferredColorScheme(.dark)
        .animation(JarvisMotion.layout, value: hasOverlay)
        .animation(JarvisMotion.normalEase, value: state.debugHUDVisible)
        .animation(JarvisMotion.normalEase, value: isDashboardVisible)
        // ⌘⇧D still toggles the debug HUD for developers
        .onKeyPress(.init("d"), phases: .down) { event in
            if event.modifiers.contains(.command) && event.modifiers.contains(.shift) {
                withAnimation(JarvisMotion.normalEase) { state.debugHUDVisible.toggle() }
                return .handled
            }
            return .ignored
        }
    }
}

// MARK: - Stage

/// Positions the orb and transcript. Uses `GeometryReader` so the orb can
/// smoothly animate from its large centred state (no overlays) to a compact
/// 72-pt pip in the bottom-right corner (overlay open).
private struct JarvisStageView: View {
    let state: AppState
    let hasOverlay: Bool
    var useLightweightOrb: Bool = true

    var body: some View {
        GeometryReader { geo in
            let orbSize: CGFloat = hasOverlay ? 72 : 340
            let orbX: CGFloat = hasOverlay ? geo.size.width - 52 : geo.size.width / 2
            let orbY: CGFloat = hasOverlay ? geo.size.height - 52 : geo.size.height / 2 - 30

            ZStack {
                OrbView(state: state, useLightweightOrb: useLightweightOrb)
                    .frame(width: orbSize, height: orbSize)
                    .position(x: orbX, y: orbY)
                    .animation(JarvisMotion.layout, value: hasOverlay)

                if !hasOverlay {
                    Group { transcriptArea }
                        .frame(maxWidth: geo.size.width - 104)
                        .position(x: geo.size.width / 2,
                                  y: orbY + 170 + 14 + 28)
                        .transition(.opacity)
                        .animation(JarvisMotion.normalEase, value: activeTranscript)
                }
            }
        }
    }

    @ViewBuilder
    private var transcriptArea: some View {
        let line = activeTranscript
        if !line.isEmpty {
            Text(line)
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.82))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 52)
                .transition(.opacity.combined(with: .offset(y: 4)))
        } else {
            phasePill
                .transition(.opacity)
        }
    }

    private var phasePill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(state.phase.accentColor)
                .frame(width: 6, height: 6)
                .shadow(color: state.phase.accentColor.opacity(0.8), radius: 4)
            Text(state.phase.shortLabel)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .tracking(1.5)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(
            Capsule()
                .fill(state.phase.accentColor.opacity(0.08))
                .overlay(Capsule().strokeBorder(state.phase.accentColor.opacity(0.22)))
        )
    }

    private var activeTranscript: String {
        switch state.phase {
        case .listening, .conversationalListening:
            return state.partialTranscript
        case .thinking:
            return state.lastFinalTranscript.isEmpty ? "" : "\"\(state.lastFinalTranscript)\""
        case .speaking:
            return state.lastSpoken
        case .error:
            return state.lastError ?? ""
        default:
            return ""
        }
    }
}

// MARK: - CalibrationOverlayPresenter

private struct CalibrationOverlayPresenter: View {
    @ObservedObject var coordinator: SpatialAmbientCoordinator

    var body: some View {
        if coordinator.isCalibrating {
            HandCalibrationView(coordinator: coordinator)
                .transition(.opacity)
                .animation(JarvisMotion.normalEase, value: coordinator.isCalibrating)
        }
    }
}

// MARK: - SafeModeBanner

private struct SafeModeBanner: View {
    let reason: String
    let onDismiss: () -> Void
    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 14))
                Text("⚠️ Jarvis Safe Mode Active")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
                Spacer()
                Button("Details") { withAnimation(.easeInOut) { isExpanded.toggle() } }
                    .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
                Button("Exit Safe Mode") { onDismiss() }
                    .buttonStyle(.bordered).controlSize(.small).tint(.orange)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if isExpanded {
                Text(reason.isEmpty ? "Non-essential subsystems have been paused to prevent a crash." : reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color.black.opacity(0.72))
        .overlay(Rectangle().fill(Color.orange.opacity(0.30)).frame(height: 1), alignment: .bottom)
    }
}
