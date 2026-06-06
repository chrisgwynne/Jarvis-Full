import SwiftUI

// MARK: - DaemonControlView
//
// Shows the Brain daemon connection status in five independent layers:
//   1. Process (launchctl + HTTP /health)
//   2. HTTP health (/health endpoint)
//   3. WebSocket bridge (DaemonAppBridge.connectionStatus)
//   4. Database (AppState.brainDegraded)
//   5. Brain (overall)
//
// Never shows contradictory states ("daemon online / bridge offline").
// Each layer is independent — one can fail without the others.

struct DaemonControlView: View {
    @ObservedObject var manager: DaemonManager
    var appState: AppState? = nil

    @State private var connectedDevices: [DaemonClient.DaemonDeviceInfo] = []
    @State private var devicesFetchFailed: Bool = false
    @State private var devicesRefreshTimer: Timer?
    @State private var routerDiagnostics: [String: Any] = [:]
    @State private var routerRefreshTimer: Timer?

    var body: some View {
        Group {
            Section {
                // ── Layered status ────────────────────────────────────────
                connectionLayers

                // ── Reconnect / action banner ────────────────────────────
                connectionBanner

                // ── Daemon controls ──────────────────────────────────────
                if manager.isInstalled { daemonControls } else { installButton }

                Text("The daemon runs as a LaunchAgent on port \(String(manager.portNumber)) and stays active even when Jarvis is closed.")
                    .font(.caption).foregroundStyle(.secondary)

            } header: { Label("Brain Daemon", systemImage: "cpu") }

            Section {
                ConnectedDevicesSection(devices: connectedDevices, fetchFailed: devicesFetchFailed)
            } header: { Text("Connected Devices") }

            Section {
                RouterStatusSection(
                    diagnostics: routerDiagnostics,
                    macAppConnected: DaemonAppBridge.shared.isConnected
                )
            } header: { Text("Message Router") }
        }
        .onAppear  { manager.startPolling(); refreshAll() }
        .onDisappear { manager.stopPolling(); stopTimers() }
    }

    // MARK: - Connection layer rows

    @ViewBuilder
    private var connectionLayers: some View {
        let bridge = DaemonAppBridge.shared
        let brainDeg = appState?.brainDegraded ?? false

        // 1. Process
        layerRow("Process",
                 value: processLabel,
                 dot: processDot)

        // 2. HTTP health
        layerRow("HTTP health",
                 value: manager.status == .running    ? "ok"
                      : manager.status == .unhealthy  ? "unreachable"
                      : "—",
                 dot: manager.status == .running ? .green : .orange)

        // 3. WebSocket bridge — the authoritative connection state
        layerRow("Mac bridge (WS)",
                 value: bridge.connectionStatus.shortLabel,
                 dot: bridge.isConnected ? .green
                    : bridge.connectionStatus == .connecting ? .yellow
                    : .red)

        // 4. Database
        layerRow("Database",
                 value: brainDeg ? (appState?.brainDegradedReason ?? "degraded") : "ok",
                 dot: brainDeg ? .orange : .green)

        // 5. Overall Brain
        let brainOnline = bridge.isConnected && !brainDeg
        layerRow("Brain",
                 value: brainOnline ? "online" : (bridge.isConnected ? "degraded" : "offline"),
                 dot: brainOnline ? .green : (bridge.isConnected ? .orange : .red))
    }

    private func layerRow(_ label: String, value: String, dot: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(dot).frame(width: 7, height: 7)
            Text(label)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Connection banner

    @ViewBuilder
    private var connectionBanner: some View {
        let bridge = DaemonAppBridge.shared
        if !bridge.isConnected {
            VStack(alignment: .leading, spacing: 6) {
                Label(bridge.connectionStatus == .notConfigured
                      ? "Brain Daemon URL not configured"
                      : bridge.connectionStatus.shortLabel,
                      systemImage: bridge.connectionStatus == .notConfigured
                      ? "gear" : "wifi.slash")
                    .font(.callout).fontWeight(.semibold)
                    .foregroundStyle(bridge.connectionStatus == .notConfigured ? Color.secondary : Color.orange)

                if bridge.reconnectAttempts > 0 {
                    Text("Reconnecting automatically — attempt \(bridge.reconnectAttempts)")
                        .font(.caption).foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    if manager.status == .running || manager.status == .unhealthy {
                        Button("Reconnect Now") {
                            DaemonAppBridge.shared.resetAndReconnect()
                        }
                        .buttonStyle(.borderedProminent).tint(.indigo)
                    } else if manager.isInstalled {
                        Button("Start Daemon") { manager.start() }
                            .buttonStyle(.borderedProminent).tint(.blue)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08))
            .cornerRadius(8)
        }
    }

    // MARK: - Controls

    private var daemonControls: some View {
        HStack(spacing: 8) {
            Button("Start")   { manager.start()   }.disabled(manager.status == .running)
            Button("Stop")    { manager.stop()    }.disabled(manager.status != .running && manager.status != .unhealthy)
            Button("Restart") { manager.restart() }
            Button("Uninstall") { manager.uninstall() }.foregroundStyle(.red)
            Spacer()
            Button("Open Logs") { manager.openLogs() }
        }
        .buttonStyle(.bordered)
    }

    private var installButton: some View {
        Button("Install Daemon") { manager.install() }
            .buttonStyle(.borderedProminent)
    }

    // MARK: - Process status helpers

    private var processLabel: String {
        switch manager.status {
        case .running:      return "running"
        case .stopped:      return "stopped"
        case .crashed:      return "crashed"
        case .unhealthy:    return "running (unhealthy)"
        case .notInstalled: return "not installed"
        case .unknown:      return "checking…"
        }
    }

    private var processDot: Color {
        switch manager.status {
        case .running:              return .green
        case .unhealthy:            return .orange
        case .crashed:              return .red
        case .stopped, .notInstalled, .unknown: return .secondary
        }
    }

    // MARK: - Data refresh

    private func refreshAll() {
        Task { await refreshDevices() }
        Task { await refreshRouterDiagnostics() }
        devicesRefreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in await refreshDevices() }
        }
        routerRefreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            Task { @MainActor in await refreshRouterDiagnostics() }
        }
    }

    private func stopTimers() {
        devicesRefreshTimer?.invalidate(); devicesRefreshTimer = nil
        routerRefreshTimer?.invalidate();  routerRefreshTimer  = nil
    }

    private func refreshDevices() async {
        if let devices = await DaemonClient.shared.fetchDevices() {
            connectedDevices = devices; devicesFetchFailed = false
        } else {
            devicesFetchFailed = true
        }
    }

    private func refreshRouterDiagnostics() async {
        if let diag = await DaemonClient.shared.fetchRouterDiagnostics() {
            routerDiagnostics = diag
        }
    }
}

// MARK: - DaemonManager port extension

extension DaemonManager {
    var portNumber: Int { 8765 }  // never localised
}

// MARK: - ConnectedDevicesSection

private struct ConnectedDevicesSection: View {
    let devices: [DaemonClient.DaemonDeviceInfo]
    let fetchFailed: Bool

    var body: some View {
        if fetchFailed {
            Text("Cannot reach daemon — bridge offline")
                .foregroundStyle(.secondary).italic()
        } else if devices.isEmpty {
            Text("No devices connected").foregroundStyle(.secondary).italic()
        } else {
            ForEach(devices) { device in
                HStack(spacing: 8) {
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

    private func platformLabel(_ p: String?) -> String {
        switch p?.lowercased() { case "android": return "Android"; case "windows": return "Windows"; default: return "Device" }
    }
    private func platformColor(_ p: String?) -> Color {
        switch p?.lowercased() { case "android": return .green; case "windows": return .blue; default: return .secondary }
    }
    private func relativeTime(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        guard let d = f.date(from: iso) else { return iso }
        let diff = Date().timeIntervalSince(d)
        if diff < 60   { return "\(Int(diff))s ago" }
        if diff < 3600 { return "\(Int(diff/60))m ago" }
        return "\(Int(diff/3600))h ago"
    }
}

// MARK: - RouterStatusSection

private struct RouterStatusSection: View {
    let diagnostics: [String: Any]
    let macAppConnected: Bool   // actual WS connection, not HTTP health

    var body: some View {
        if diagnostics.isEmpty {
            Text("Router data unavailable").foregroundStyle(.secondary).italic()
        } else {
            row("Mac bridge",      macAppConnected ? "connected" : "disconnected",
                color: macAppConnected ? Color.green : Color.red)
            row("Android devices", "\(diagnostics["connectedAndroidClients"] as? Int ?? 0)")
            row("Windows devices", "\(diagnostics["connectedWindowsClients"] as? Int ?? 0)")
            row("Queue depth",     "\(diagnostics["offlineQueueDepth"] as? Int ?? 0)")
            row("Routed messages", "\(diagnostics["routedMessageCount"] as? Int ?? 0)")
            let t = diagnostics["lastMessageType"] as? String ?? ""
            row("Last type", t.isEmpty ? "—" : t)
        }
    }

    private func row(_ label: String, _ value: String, color: Color = .secondary) -> some View {
        LabeledContent(label) {
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(color)
        }
    }
}
