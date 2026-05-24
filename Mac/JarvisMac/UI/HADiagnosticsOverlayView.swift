import SwiftUI

// MARK: - HADiagnosticsOverlayView

/// Developer / diagnostics overlay for the Home Assistant integration.
///
/// Surfaces: WebSocket connection state, entity counts, last event received,
/// active cooldown timers, motion → camera mappings, and any camera stream
/// errors. Auto-refreshes every 2 s via a `Timer`.
struct HADiagnosticsOverlayView: View {

    // MARK: - Inputs

    let entityRegistry: HAEntityRegistry
    let motionMapper:   HAMotionCameraMapper
    let isWSConnected:  Bool
    let lastEventText:  String
    let lastAlertText:  String

    // MARK: - State

    @State private var tick = false          // drives the 2-s refresh Timer
    @State private var refreshTimer: Timer?

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                connectionSection
                entityCountSection
                cooldownSection
                mappingsSection
            }
            .padding(16)
        }
        .onAppear  { startTimer() }
        .onDisappear { stopTimer() }
        .animation(.easeInOut(duration: 0.2), value: tick)
    }

    // MARK: - Connection

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Connection", systemImage: "antenna.radiowaves.left.and.right")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Circle()
                    .fill(isWSConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                    .shadow(color: isWSConnected ? .green.opacity(0.6) : .red.opacity(0.4),
                            radius: 4)
                Text(isWSConnected ? "WebSocket connected — subscribed to state_changed"
                                   : "WebSocket disconnected")
                    .font(.system(size: 12, design: .rounded))
            }

            if !lastEventText.isEmpty {
                row("Last event", lastEventText)
            }
            if !lastAlertText.isEmpty {
                row("Last alert", lastAlertText)
            }

            if let syncDate = entityRegistry.lastSyncDate {
                row("Entities synced", syncDate.formatted(.relative(presentation: .named)))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(.ultraThinMaterial))
    }

    // MARK: - Entity counts

    private var entityCountSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Entities", systemImage: "square.grid.2x2.fill")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                countPill(count: entityRegistry.cameraCount,
                          label: "Cameras",
                          icon: "camera.fill",
                          color: .cyan)
                countPill(count: entityRegistry.motionSensors.count,
                          label: "Motion",
                          icon: "figure.walk",
                          color: .orange)
                countPill(count: entityRegistry.doorbellSensors.count,
                          label: "Doorbells",
                          icon: "bell.fill",
                          color: .yellow)
            }

            if entityRegistry.cameras.isEmpty {
                Text("No cameras discovered — ensure HA is configured and entity sync has run.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(.ultraThinMaterial))
    }

    private func countPill(count: Int, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.caption2)
                Text("\(count)").font(.system(size: 16, weight: .bold, design: .rounded))
            }
            .foregroundStyle(count > 0 ? color : .secondary)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .frame(minWidth: 64)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(count > 0 ? 0.08 : 0.03)))
    }

    // MARK: - Cooldown state

    private var cooldownSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Cooldown State", systemImage: "timer")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)

            let globalDiag = motionMapper.globalDiagnostics
            cooldownRow(id: "Global HA alerts",
                        diag: globalDiag,
                        icon: "globe")

            ForEach(motionMapper.allEntityDiagnostics) { diag in
                cooldownRow(id: diag.id, diag: diag, icon: "sensor.fill")
            }

            if motionMapper.allEntityDiagnostics.isEmpty {
                Text("No motion mappings configured.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(.ultraThinMaterial))
    }

    private func cooldownRow(id: String,
                              diag: HAMotionCameraMapper.CooldownDiagnostics,
                              icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(id)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if diag.isInCooldown {
                    Text("cooling down — \(Int(diag.remainingSeconds))s remaining")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                } else {
                    Text(diag.lastAlertAt == nil
                         ? "never fired"
                         : "ready (last: \(diag.lastAlertAt!.formatted(.relative(presentation: .named))))")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Circle()
                .fill(diag.isInCooldown ? Color.orange : Color.green)
                .frame(width: 7, height: 7)
                .shadow(color: diag.isInCooldown ? .orange.opacity(0.5) : .green.opacity(0.5),
                        radius: 3)
        }
    }

    // MARK: - Mappings

    private var mappingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Motion → Camera Mappings", systemImage: "arrow.forward.circle.fill")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)

            if motionMapper.mappings.isEmpty {
                Text("No mappings configured. Add them in Settings → Home → Camera Alerts.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(motionMapper.mappings) { mapping in
                    mappingRow(mapping)
                    if mapping.id != motionMapper.mappings.last?.id {
                        Divider().opacity(0.4)
                    }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(.ultraThinMaterial))
    }

    private func mappingRow(_ mapping: HAMotionCameraMapping) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: mapping.isDoorbellMapping ? "bell.fill" : "figure.walk")
                    .font(.caption)
                    .foregroundStyle(mapping.enabled ? .yellow : .secondary)
                Text(mapping.motionSensorID)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(mapping.enabled ? .primary : .tertiary)
                Spacer()
                Text(mapping.enabled ? "ON" : "OFF")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(mapping.enabled ? .green : .secondary)
            }
            HStack(spacing: 6) {
                Image(systemName: "camera.fill")
                    .font(.caption2)
                    .foregroundStyle(.cyan.opacity(0.7))
                Text("→ \(mapping.cameraEntityID)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text("\"\(mapping.alertPhrase)\"")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("cooldown \(Int(mapping.cooldownSeconds))s")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
    }

    // MARK: - Auto-refresh

    private func startTimer() {
        stopTimer()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in tick.toggle() }
        }
    }

    private func stopTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}
