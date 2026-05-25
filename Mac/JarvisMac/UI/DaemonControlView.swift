import SwiftUI

/// Embedded Settings panel showing JarvisBrainDaemon status and lifecycle controls.
struct DaemonControlView: View {
    @ObservedObject var manager: DaemonManager
    /// AppState for daemon-unavailable banner. Optional so legacy call-sites that
    /// haven't wired AppState yet continue to compile (banner is simply hidden).
    var appState: AppState? = nil
    @State private var connectedDevices: [DaemonClient.DaemonDeviceInfo] = []
    @State private var devicesFetchFailed: Bool = false
    @State private var devicesRefreshTimer: Timer?
    @State private var routerDiagnostics: [String: Any] = [:]
    @State private var routerRefreshTimer: Timer?

    var body: some View {
        Group {
            Section {
                // Status indicator row
                HStack(spacing: 8) {
                    if manager.status != .notInstalled {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                    }
                    Text(statusLabel)
                        .font(.system(.body, design: .monospaced))
                    Spacer()
                    if manager.status == .running {
                        Text(String(format: "up %.0fs", manager.daemonUptimeSeconds))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                // Unhealthy warning
                if manager.status == .unhealthy {
                    Label("Process running but gateway unreachable — port may not be bound.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }

                // Limited local mode banner — shown when daemon is enabled but unreachable
                if appState?.daemonUnavailable == true {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Jarvis daemon unavailable", systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).fontWeight(.semibold).foregroundStyle(.orange)
                        Text("Jarvis is running in limited local mode until the daemon reconnects.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.12))
                    .cornerRadius(8)

                    Button("Reconnect") {
                        // Triggers a reconnect attempt via DaemonManager
                        manager.pollStatus()
                    }
                    .buttonStyle(.bordered)
                }

                // Port ownership row
                LabeledContent("Port status") {
                    Text(manager.portOwner.description)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(manager.portOwner.isConflict ? .red : .secondary)
                }

                // Port conflict warning
                if manager.portOwner.isConflict {
                    Label("Port 8765 is in use by another process. Stop it before starting the daemon.", systemImage: "exclamationmark.octagon")
                        .font(.caption).foregroundStyle(.red)
                }

                // launchctl error
                if !manager.lastLaunchctlError.isEmpty {
                    LabeledContent("launchctl") {
                        Text(manager.lastLaunchctlError)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.orange)
                    }
                }

                // Gateway URL
                LabeledContent("Gateway URL") {
                    Text(manager.gatewayURL)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                // Last heartbeat
                if let hb = manager.lastHeartbeat {
                    LabeledContent("Last heartbeat") {
                        Text(hb, style: .time)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                // Controls
                HStack(spacing: 8) {
                    if !manager.isInstalled {
                        Button("Install") { manager.install() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Start")   { manager.start()   }
                            .disabled(manager.status == .running)
                        Button("Stop")    { manager.stop()    }
                            .disabled(manager.status != .running && manager.status != .unhealthy)
                        Button("Restart") { manager.restart() }
                        Button("Uninstall") { manager.uninstall() }
                            .foregroundStyle(.red)
                    }
                    Spacer()
                    Button("Open Logs") { manager.openLogs() }
                }
                .buttonStyle(.bordered)

                Text("The daemon owns port 8765 so Android/Windows can connect even when the Jarvis app is closed. Install once — it starts at login automatically.")
                    .font(.caption).foregroundStyle(.secondary)

            } header: {
                Label("Brain Daemon", systemImage: "cpu")
            }

            // Connected devices section (Task 6b)
            Section {
                ConnectedDevicesSection(devices: connectedDevices, fetchFailed: devicesFetchFailed)
            } header: {
                Text("Connected Devices")
            }

            // Router status section (Phase 3)
            Section {
                RouterStatusSection(diagnostics: routerDiagnostics, macAppConnected: manager.status == .running)
            } header: {
                Text("Message Router")
            }
        }
        .onAppear {
            manager.startPolling()
            Task { await refreshDevices() }
            Task { await refreshRouterDiagnostics() }
            devicesRefreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
                Task { @MainActor in await refreshDevices() }
            }
            routerRefreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
                Task { @MainActor in await refreshRouterDiagnostics() }
            }
        }
        .onDisappear {
            manager.stopPolling()
            devicesRefreshTimer?.invalidate()
            devicesRefreshTimer = nil
            routerRefreshTimer?.invalidate()
            routerRefreshTimer = nil
        }
    }

    private func refreshDevices() async {
        if let devices = await DaemonClient.shared.fetchDevices() {
            connectedDevices = devices
            devicesFetchFailed = false
        } else {
            devicesFetchFailed = true
        }
    }

    private func refreshRouterDiagnostics() async {
        if let diag = await DaemonClient.shared.fetchRouterDiagnostics() {
            routerDiagnostics = diag
        }
    }

    private var statusColor: Color {
        switch manager.status {
        case .running:      return .green
        case .stopped:      return .gray
        case .crashed:      return .red
        case .unhealthy:    return .orange
        case .notInstalled: return .gray
        case .unknown:      return .yellow
        }
    }

    private var statusLabel: String {
        switch manager.status {
        case .running:      return "Running"
        case .stopped:      return "Stopped"
        case .crashed:      return "Crashed"
        case .unhealthy:    return "Unhealthy"
        case .notInstalled: return "Not installed"
        case .unknown:      return "Checking…"
        }
    }
}

// MARK: - Connected Devices Section (Task 6b)

private struct ConnectedDevicesSection: View {
    let devices: [DaemonClient.DaemonDeviceInfo]
    let fetchFailed: Bool

    var body: some View {
        if fetchFailed {
            Text("Daemon offline")
                .foregroundStyle(.secondary).italic()
        } else if devices.isEmpty {
            Text("No devices connected")
                .foregroundStyle(.secondary).italic()
        } else {
            ForEach(devices) { device in
                HStack(spacing: 8) {
                    // Platform badge
                    Text(platformLabel(device.platform))
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(platformColor(device.platform).opacity(0.15))
                        .foregroundStyle(platformColor(device.platform))
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.name).font(.body)
                        if let seen = device.lastSeenAt {
                            Text("Last seen: \(relativeTime(seen))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if device.isRevoked == true {
                        Text("Revoked").font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func platformLabel(_ platform: String?) -> String {
        switch platform?.lowercased() {
        case "android": return "Android"
        case "windows": return "Windows"
        default:        return "Device"
        }
    }

    private func platformColor(_ platform: String?) -> Color {
        switch platform?.lowercased() {
        case "android": return .green
        case "windows": return .blue
        default:        return .secondary
        }
    }

    private func relativeTime(_ isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: isoString) else { return isoString }
        let diff = Date().timeIntervalSince(date)
        if diff < 60   { return "\(Int(diff))s ago" }
        if diff < 3600 { return "\(Int(diff/60))m ago" }
        return "\(Int(diff/3600))h ago"
    }
}

// MARK: - Router Status Section (Phase 3)

private struct RouterStatusSection: View {
    let diagnostics: [String: Any]
    let macAppConnected: Bool

    var body: some View {
        if diagnostics.isEmpty {
            Text("Daemon offline or router data unavailable")
                .foregroundStyle(.secondary).italic()
        } else {
            LabeledContent("Mac app connected") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(macAppConnected ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(macAppConnected ? "Yes" : "No")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent("Android devices") {
                Text("\(diagnostics["connectedAndroidClients"] as? Int ?? 0)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Windows devices") {
                Text("\(diagnostics["connectedWindowsClients"] as? Int ?? 0)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Offline queue depth") {
                Text("\(diagnostics["offlineQueueDepth"] as? Int ?? 0)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Last message type") {
                Text((diagnostics["lastMessageType"] as? String ?? "—").isEmpty
                     ? "—" : diagnostics["lastMessageType"] as? String ?? "—")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Routed messages") {
                Text("\(diagnostics["routedMessageCount"] as? Int ?? 0)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
