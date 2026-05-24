import SwiftUI

/// Single-screen Jarvis view. Orb sits front-and-centre when idle;
/// slides to a compact corner pip when overlay panels are open.
/// Developer diagnostics are available via the Debug HUD (⌘⇧D);
/// they are never a separate full-screen mode.
struct CommandCentreView: View {
    let state: AppState
    let controller: JarvisController

    private var hasOverlay: Bool {
        !controller.overlayManager.overlays.isEmpty
    }

    var body: some View {
        ZStack {
            // 1. Blueprint background — always visible
            BlueprintBackgroundView(
                phaseColor: state.phase.accentColor,
                ambientEnabled: state.ambientModeEnabled,
                attentionDimFactor: state.attentionState.ambientDimFactor,
                safeMode: state.safeMode
            )

            // 2. Stage — orb + transcript; orb animates to corner on overlay open
            JarvisStageView(state: state, hasOverlay: hasOverlay)

            // 3. Overlay panels (news, chat, notifications, …)
            OverlayHostView(state: state,
                            controller: controller,
                            manager: controller.overlayManager)

            // 3.5. Spatial interaction layer — ambient, spans the full stage.
            //      Always mounted; visible only when a hand is detected.
            //      allowsHitTesting(false) — never blocks mouse or keyboard.
            SpatialInteractionLayer(coordinator: controller.spatialCoordinator,
                                    hasOverlay: hasOverlay)
                .allowsHitTesting(false)

            // 3.6. Hand calibration overlay — shown over the full stage when
            //      the user triggers calibration from Settings → Gestures.
            //      CalibrationOverlayPresenter observes the coordinator so it
            //      re-renders when isCalibrating changes (CommandCentreView
            //      itself uses `let controller` and won't react to coordinator
            //      @Published changes directly).
            CalibrationOverlayPresenter(coordinator: controller.spatialCoordinator)

            // 4. File search overlay — bottom-centred, multi-result findFile
            if state.fileSearchOverlayVisible && !state.fileSearchResults.isEmpty {
                VStack {
                    Spacer()
                    FileSearchOverlayView(
                        results: state.fileSearchResults,
                        query: state.fileSearchQuery,
                        systemController: controller.systemController
                    ) {
                        withAnimation(.spring(duration: 0.25)) {
                            state.fileSearchOverlayVisible = false
                        }
                    }
                    .padding(.bottom, state.statusStripVisible ? 56 : 34)
                }
                .transition(.opacity)
                .animation(.spring(duration: 0.28, bounce: 0.12),
                           value: state.fileSearchOverlayVisible)
            }

            // 5. Toast — bottom-centred, auto-fades
            VStack {
                Spacer()
                CommandResultToast(message: state.toastMessage, icon: state.toastIcon)
                    .padding(.bottom, state.statusStripVisible ? 44 : 22)
                    .animation(.spring(duration: 0.28, bounce: 0.18),
                               value: state.toastMessage)
            }

            // 6. Status strip
            if state.statusStripVisible {
                VStack {
                    Spacer()
                    MinimalStatusStrip(state: state)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // 7. Debug HUD — bottom-trailing corner overlay
            if state.debugHUDVisible {
                DebugHUDView(state: state, controller: controller)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .bottomTrailing)
                    .padding(12)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            }

            // 8. Always-visible corner controls
            StageCornerControls(state: state, controller: controller)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: .topTrailing)
        }
        .frame(minWidth: 1100, minHeight: 720)
        .preferredColorScheme(.dark)
        .animation(.spring(duration: 0.45, bounce: 0.12), value: hasOverlay)
        .animation(.spring(duration: 0.25), value: state.debugHUDVisible)
        .animation(.spring(duration: 0.28), value: state.statusStripVisible)
    }
}

// MARK: - Stage

/// Positions the orb and transcript. Uses `GeometryReader` so the orb can
/// smoothly animate from its large centred state (no overlays) to a compact
/// 72-pt pip in the bottom-right corner (overlay open).
private struct JarvisStageView: View {
    let state: AppState
    let hasOverlay: Bool

    var body: some View {
        GeometryReader { geo in
            let orbSize: CGFloat = hasOverlay ? 72 : 340
            // Centre the orb slightly above the screen mid-point so the
            // transcript label fits below without crowding the bottom edge.
            let orbX: CGFloat = hasOverlay ? geo.size.width  - 52 : geo.size.width  / 2
            let orbY: CGFloat = hasOverlay ? geo.size.height - 52 : geo.size.height / 2 - 30

            ZStack {
                // Orb — position + size both animated
                OrbView(state: state)
                    .frame(width: orbSize, height: orbSize)
                    .position(x: orbX, y: orbY)
                    .animation(.spring(duration: 0.45, bounce: 0.15), value: hasOverlay)

                // Transcript / phase pill — hidden while overlays are open
                if !hasOverlay {
                    Group {
                        transcriptArea
                    }
                    // Centre horizontally; sit below the orb's lower edge
                    .frame(maxWidth: geo.size.width - 104)
                    .position(x: geo.size.width / 2,
                              y: orbY + 170 + 14 + 28)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.25), value: activeTranscript)
                }
            }
        }
    }

    // MARK: Transcript

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
                .transition(.opacity.combined(with: .move(edge: .bottom)))
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

// MARK: - Corner Controls

/// Always-visible icon buttons in the top-trailing corner.
/// Ear toggle, Debug HUD toggle, and status-strip toggle live here
/// regardless of whether any overlay is open.
private struct StageCornerControls: View {
    let state: AppState
    let controller: JarvisController

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            // Ear toggle — topmost so it's reachable even when muted
            cornerButton(state.listeningEnabled ? "ear" : "ear.slash",
                         activeIcon: "ear.fill",
                         active: state.listeningEnabled) {
                if state.listeningEnabled {
                    controller.disableListening()
                } else {
                    controller.enableListening()
                }
            }
            .help(state.listeningEnabled
                  ? "Listening enabled — click to mute"
                  : "Muted — click to resume listening")

            cornerButton("ant.circle",
                         activeIcon: "ant.circle.fill",
                         active: state.debugHUDVisible) {
                withAnimation { state.debugHUDVisible.toggle() }
            }
            .help("Debug HUD  (⌘⇧D)")
            .keyboardShortcut("d", modifiers: [.command, .shift])

            cornerButton("chart.bar.xaxis", active: state.statusStripVisible) {
                withAnimation { state.statusStripVisible.toggle() }
                controller.persistStatusStrip()
            }
            .help("Status strip")
        }
        .padding(.top, 14)
        .padding(.trailing, 16)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func cornerButton(_ icon: String,
                               activeIcon: String? = nil,
                               active: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: active ? (activeIcon ?? icon) : icon)
                .font(.callout)
                .foregroundStyle(active ? state.phase.accentColor : .secondary)
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.055))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.10)))
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - CalibrationOverlayPresenter

/// Thin wrapper that observes the coordinator so it re-renders when
/// `isCalibrating` changes — CommandCentreView uses `let controller` and
/// won't react to coordinator @Published changes on its own.
private struct CalibrationOverlayPresenter: View {
    @ObservedObject var coordinator: SpatialAmbientCoordinator

    var body: some View {
        if coordinator.isCalibrating {
            HandCalibrationView(coordinator: coordinator)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.20), value: coordinator.isCalibrating)
        }
    }
}
