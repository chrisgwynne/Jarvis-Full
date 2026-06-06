import SwiftUI

// MARK: - ControlDockView

/// Floating bottom-centre control dock.
///
/// Hidden by default. Appears when:
///   - Mouse approaches the bottom edge
///   - Dashboard is open
///   - Hand tracking is active (spatial interaction)
///
/// Animation: opacity + translateY only. No bounce, no spring overshoot.
struct ControlDockView: View {
    let state: AppState
    let controller: JarvisController
    @Binding var isDashboardVisible: Bool

    @State private var isHoverActive = false

    private var shouldShow: Bool {
        isHoverActive || isDashboardVisible || state.phase == .listening
            || state.phase == .speaking || state.phase == .thinking
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Hover zone and dock content share the same container so that
            // moving the mouse from the invisible zone onto the dock pill
            // never triggers an onHover(false) — the cursor stays inside
            // the parent ZStack the whole time.
            ZStack(alignment: .bottom) {
                // Invisible detection zone — always present, always hittestable.
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: 160)
                    .contentShape(Rectangle())

                if shouldShow {
                    VStack(spacing: 10) {
                        ContextChipRow(state: state, controller: controller)
                        dockPill
                    }
                    .padding(.bottom, 20)
                    .transition(JarvisMotion.dock)
                }
            }
            .onHover { hovering in
                withAnimation(JarvisMotion.normalEase) { isHoverActive = hovering }
            }
            .animation(JarvisMotion.normalEase, value: shouldShow)
        }
    }

    // MARK: - Dock pill

    private var dockPill: some View {
        HStack(spacing: 2) {
            // Camera Vision
            DockButton(
                icon: "camera",
                help: "Camera Vision",
                isActive: controller.overlayManager.latestKind == .camera
            ) {
                controller.overlayManager.open(.camera)
            }

            // Mute / Unmute
            DockButton(
                icon: state.listeningEnabled ? "mic" : "mic.slash",
                help: state.listeningEnabled ? "Mute microphone" : "Unmute microphone",
                isActive: !state.listeningEnabled,
                activeColor: .orange
            ) {
                if state.listeningEnabled {
                    controller.disableListening(fromUI: true)
                } else {
                    controller.enableListening()
                }
            }
            .disabled(controller.prefs.current.emergencySafeMode)

            // News
            DockButton(
                icon: "newspaper",
                help: "News",
                isActive: controller.overlayManager.latestKind == .news
            ) {
                controller.overlayManager.open(.news)
            }

            dockDivider

            // Settings
            DockButton(icon: "gearshape", help: "Settings") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }

            // Command Centre
            DockButton(
                icon: "line.3.horizontal",
                help: "Command Centre",
                isActive: isDashboardVisible
            ) {
                withAnimation(JarvisMotion.normalEase) {
                    isDashboardVisible.toggle()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(dockBackground)
        .shadow(color: .black.opacity(0.45), radius: 28, x: 0, y: 8)
    }

    private var dockBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.09), lineWidth: 0.5)
            )
    }

    private var dockDivider: some View {
        Divider()
            .frame(height: 18)
            .opacity(0.25)
            .padding(.horizontal, 4)
    }
}

// MARK: - DockButton

private struct DockButton: View {
    let icon: String
    let help: String
    var isActive: Bool = false
    var activeColor: Color = .accentColor
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(
                    isActive
                        ? activeColor
                        : (isHovered ? Color.primary : Color.primary.opacity(0.65))
                )
                .frame(width: 38, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isActive
                              ? activeColor.opacity(0.12)
                              : (isHovered ? Color.white.opacity(0.07) : .clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { h in
            withAnimation(JarvisMotion.fastEase) { isHovered = h }
        }
    }
}

// MARK: - ContextChipRow

/// Contextual suggestion chips that appear above the dock.
/// Chips are generated from time of day, service availability, and recent state.
struct ContextChipRow: View {
    let state: AppState
    let controller: JarvisController

    private var chips: [ContextChip] { buildChips() }

    var body: some View {
        if !chips.isEmpty {
            HStack(spacing: 8) {
                ForEach(chips) { chip in
                    ContextChipButton(chip: chip) {
                        fire(chip.action)
                    }
                }
            }
        }
    }

    private func fire(_ text: String) {
        Task { await controller.handleTranscript(text) }
    }

    private func buildChips() -> [ContextChip] {
        let hour = Calendar.current.component(.hour, from: Date())
        var result: [ContextChip] = []

        // Morning briefing
        if hour >= 6 && hour < 11 {
            result.append(ContextChip(id: "briefing", label: "Morning Briefing",
                                      action: "give me a morning briefing"))
        }

        // Evening summary
        if hour >= 18 && hour < 23 {
            result.append(ContextChip(id: "evening", label: "Evening Summary",
                                      action: "give me an evening summary"))
        }

        // Calendar (always relevant)
        result.append(ContextChip(id: "calendar", label: "Today's Schedule",
                                   action: "what's on my calendar today"))

        // Tasks
        if controller.prefs.current.todoistAPIToken != nil {
            result.append(ContextChip(id: "tasks", label: "Today's Tasks", action: "show my tasks"))
        }

        // Home
        if !(controller.prefs.current.smartHomeBaseURL ?? "").isEmpty {
            result.append(ContextChip(id: "home", label: "Home Status", action: "show home panel"))
        }

        // Shopify orders
        if controller.prefs.current.shopifyAccessToken != nil {
            result.append(ContextChip(id: "orders", label: "Recent Orders",
                                       action: "check recent orders"))
        }

        return Array(result.prefix(4))
    }
}

private struct ContextChip: Identifiable {
    let id: String
    let label: String
    let action: String
}

private struct ContextChipButton: View {
    let chip: ContextChip
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(chip.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHovered ? Color.primary : Color.primary.opacity(0.75))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(isHovered
                              ? Color.white.opacity(0.12)
                              : Color.white.opacity(0.07))
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                        )
                )
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(JarvisMotion.fastEase) { isHovered = h }
        }
    }
}

