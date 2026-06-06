import SwiftUI
import CoreImage.CIFilterBuiltins

/// Settings view for the unified Mac Brain Gateway (port 8765).
/// Replaces MacBrainSettingsView in Developer > Brain API sub-tab.
/// Also surfaced in Integrations for Android pairing.
///
/// NOTE: The gateway master token (gatewayToken in Keychain) is kept for internal
/// auth validation only. It is never shown, copied, or rotated from this UI.
/// Windows pairs via 6-digit pairing code → device token (hidden). Android likewise.
struct MacBrainGatewaySettingsView: View {
    let controller: JarvisController

    @State private var urlCopied = false

    private var diag: GatewayDiagnostics { controller.gatewayDiagnostics }
    @State private var authStore: GatewayAuthStore = GatewayAuthStore.shared

    var body: some View {
        Form {
            // ── Daemon URL ────────────────────────────────────────────────
            // Simple: enter the URL, connect. No pairing codes, no tokens.
            Section {
                LabeledContent("Brain Daemon URL") {
                    TextField("http://127.0.0.1:8765",
                              text: Binding(
                                get: { controller.prefs.current.daemonBaseURL },
                                set: { v in controller.prefs.update { $0.daemonBaseURL = v } }
                              ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit {
                        let url = controller.prefs.current.daemonBaseURL
                        DaemonAppBridge.shared.connect(baseURL: url)
                    }
                }
                Text("The app derives health, version, and WebSocket URLs from this base URL. Use http://127.0.0.1:8765 for local daemon, or http://192.168.x.x:8765 for LAN access.")
                    .font(.caption).foregroundStyle(.secondary)

                // Live connection status
                HStack(spacing: 8) {
                    let bridge = DaemonAppBridge.shared
                    Circle()
                        .fill(bridge.isConnected ? Color.green
                              : bridge.connectionStatus == .connecting ? Color.yellow
                              : Color.red)
                        .frame(width: 8, height: 8)
                    Text(bridge.connectionStatus.shortLabel)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(2)
                    Spacer()
                    if !bridge.isConnected {
                        Button("Connect") {
                            DaemonAppBridge.shared.connect(
                                baseURL: controller.prefs.current.daemonBaseURL)
                        }
                        .buttonStyle(.bordered)
                    }
                }

            } header: { Text("Connection") }

            // ── Brain Daemon (LaunchAgent) ────────────────────────────────
            DaemonControlView(manager: DaemonManager.shared, appState: controller.state)

            // ── Mac Brain Gateway Enable ───────────────────────────────────
            Section {
                Toggle("Enable Mac Brain Gateway",
                       isOn: Binding(
                           get: { controller.prefs.current.brainServerEnabled },
                           set: { v in
                               controller.prefs.update { $0.brainServerEnabled = v }
                               if v { controller.startBrainServer() }
                               else { controller.stopBrainServer() }
                           }
                       ))
                // Legacy mode warning — shown when daemon is not enabled
                if !controller.prefs.current.daemonEnabled {
                    Label("Legacy mode: Brain API owned by Mac app. Enable Daemon to move gateway out of process.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                // Port formatted with String() — never use \(UInt16) in Text, which applies
                // locale number formatting and produces "8,765" instead of "8765".
                Text("Unified gateway on port \(String(controller.prefs.current.brainServerPort)) serving Brain API, Windows sidecar, and Android WebSocket. Android connects to wss://…:\(String(controller.prefs.current.brainServerPort))/v1/android/ws.")
                    .font(.caption).foregroundStyle(.secondary)

                // Status indicator
                HStack(spacing: 8) {
                    Circle()
                        .fill(diag.isRunning ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                    Text(diag.statusLine)
                        .font(.system(.body, design: .monospaced))
                    Spacer()
                    if diag.isRunning {
                        Text(String(format: "up %.0fs", diag.uptimeSeconds))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: { Text("Mac Brain Gateway") }

            // ── Network ───────────────────────────────────────────────────
            Section {
                LabeledContent("Port") {
                    Stepper(value: Binding(
                        get: { Int(controller.prefs.current.brainServerPort) },
                        set: { v in
                            let p = UInt16(clamping: v)
                            controller.prefs.update { $0.brainServerPort = p }
                            if controller.prefs.current.brainServerEnabled {
                                controller.restartBrainServer()
                            }
                        }
                    ), in: 1024...65535) {
                        // Use String() not \() — prevents locale-based thousands separator
                        Text(String(controller.prefs.current.brainServerPort))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Toggle("Bind to localhost only",
                       isOn: Binding(
                           get: { controller.prefs.current.brainServerBindLocalOnly },
                           set: { v in
                               controller.prefs.update { $0.brainServerBindLocalOnly = v }
                               if controller.prefs.current.brainServerEnabled {
                                   controller.restartBrainServer()
                               }
                           }
                       ))
                Text("Off: reachable over Wi-Fi and Tailscale (recommended for Android). On: loopback only.")
                    .font(.caption).foregroundStyle(.secondary)

                // Android WebSocket URL
                let androidURL = androidWebSocketURL
                LabeledContent("Android WebSocket URL") {
                    HStack(spacing: 4) {
                        Text(androidURL)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(androidURL, forType: .string)
                            urlCopied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { urlCopied = false }
                        } label: {
                            Image(systemName: urlCopied ? "checkmark" : "doc.on.doc")
                        }.buttonStyle(.borderless)
                    }
                }

                // Tailscale
                if controller.state.tailscaleConnected {
                    LabeledContent("Tailscale IP") {
                        Text(controller.state.tailscaleIP ?? "—")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.green)
                    }
                } else {
                    LabeledContent("Tailscale") {
                        Text("Not connected")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: { Text("Network") }

            // ── Paired Devices ────────────────────────────────────────────
            Section {
                let active = authStore.pairedDevices.filter { !$0.isRevoked }
                if active.isEmpty {
                    Text("No paired devices")
                        .foregroundStyle(.secondary).italic()
                } else {
                    ForEach(active) { device in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name).font(.body)
                                Text("Last seen: \(device.lastSeenAt, style: .relative) ago")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(device.capabilities.joined(separator: ", "))
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Button("Revoke") {
                                authStore.revokeDevice(id: device.id)
                            }
                            .buttonStyle(.borderless).foregroundStyle(.red).font(.caption)
                        }
                        .padding(.vertical, 2)
                    }
                }
                let revoked = authStore.pairedDevices.filter { $0.isRevoked }
                if !revoked.isEmpty {
                    DisclosureGroup("Revoked (\(revoked.count))") {
                        ForEach(revoked) { device in
                            HStack {
                                Text(device.name).foregroundStyle(.secondary)
                                Spacer()
                                Button("Remove") { authStore.removeDevice(id: device.id) }
                                    .buttonStyle(.borderless).font(.caption)
                            }
                        }
                    }
                }
            } header: { Text("Paired Devices") }

            // ── Connection info for Android / Windows ─────────────────────
            // No pairing needed. Clients enter the daemon URL and connect directly.
            Section {
                let host = controller.state.tailscaleIP
                    ?? TailscaleService.findLocalIP()
                    ?? "127.0.0.1"
                let port = controller.prefs.current.brainServerPort
                LabeledContent("Android / Windows URL") {
                    // Port displayed as plain string — no locale formatting
                    Text("ws://\(host):\(String(port))/v1/client/ws")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text("On Android or Windows, enter the Brain Daemon URL: http://\(host):\(String(port)). The client connects immediately — no pairing code required.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Client Connection") }

            // ── Diagnostics ───────────────────────────────────────────────
            Section {
                Group {
                    LabeledContent("Bind address") { Text(diag.gatewayBindAddress).foregroundStyle(.secondary).monospaced() }
                    LabeledContent("Auth enabled") { Text(diag.gatewayAuthEnabled ? "Yes" : "No").foregroundStyle(.secondary) }
                    LabeledContent("Android devices") { Text("\(diag.connectedAndroidDevices)").foregroundStyle(.secondary) }
                    LabeledContent("WS clients") { Text("\(diag.activeWebSocketClients)").foregroundStyle(.secondary) }
                    LabeledContent("Requests served") { Text("\(diag.requestsServed)").foregroundStyle(.secondary) }
                }
                Group {
                    LabeledContent("Rejected (HTTP)") { Text("\(diag.rejectedUnauthenticatedRequests)").foregroundStyle(diag.rejectedUnauthenticatedRequests > 0 ? .orange : .secondary) }
                    LabeledContent("Rejected (WS)") { Text("\(diag.rejectedUnauthenticatedWebSockets)").foregroundStyle(diag.rejectedUnauthenticatedWebSockets > 0 ? .orange : .secondary) }
                    LabeledContent("Token rotations") { Text("\(diag.tokenRotationCount)").foregroundStyle(.secondary) }
                    if let lastAndroid = diag.lastAndroidSeenAt {
                        LabeledContent("Last Android seen") { Text(lastAndroid, style: .relative).foregroundStyle(.secondary) }
                    }
                    if let lastCtx = diag.lastContextAt {
                        LabeledContent("Last context request") { Text(lastCtx, style: .relative).foregroundStyle(.secondary) }
                    }
                    LabeledContent("Pairing code active") { Text(diag.pairingCodeActive ? "Yes" : "No").foregroundStyle(.secondary) }
                }
            } header: { Text("Diagnostics") }

            // ── Camera Server ─────────────────────────────────────────────
            Section {
                MacCameraSettingsView(controller: controller)
            } header: { Text("Camera Streaming") }

            // ── Remote Requests (Phase 4 daemon bridge) ───────────────────
            Section {
                Toggle("Speak remote replies on Mac",
                       isOn: Binding(
                           get: { controller.prefs.current.speakRemoteRepliesOnMac },
                           set: { v in controller.prefs.update { $0.speakRemoteRepliesOnMac = v } }
                       ))
                Toggle("Show remote activity in Mac UI",
                       isOn: Binding(
                           get: { controller.prefs.current.showRemoteActivityInMacUI },
                           set: { v in controller.prefs.update { $0.showRemoteActivityInMacUI = v } }
                       ))
                Toggle("Allow remote devices to trigger tools",
                       isOn: Binding(
                           get: { controller.prefs.current.allowRemoteDevicesToTriggerTools },
                           set: { v in controller.prefs.update { $0.allowRemoteDevicesToTriggerTools = v } }
                       ))

                Group {
                    LabeledContent("Received") {
                        Text("\(controller.state.remoteTranscriptReceivedCount)").foregroundStyle(.secondary)
                    }
                    LabeledContent("Handled") {
                        Text("\(controller.state.remoteTranscriptHandledCount)").foregroundStyle(.secondary)
                    }
                    LabeledContent("Rejected") {
                        Text("\(controller.state.remoteTranscriptRejectedCount)")
                            .foregroundStyle(controller.state.remoteTranscriptRejectedCount > 0 ? .orange : .secondary)
                    }
                    LabeledContent("Replies sent") {
                        Text("\(controller.state.remoteReplySentCount)").foregroundStyle(.secondary)
                    }
                    LabeledContent("Errors") {
                        Text("\(controller.state.remoteBrainErrorCount)")
                            .foregroundStyle(controller.state.remoteBrainErrorCount > 0 ? .red : .secondary)
                    }
                }
                if !controller.state.lastRemoteDevice.isEmpty {
                    LabeledContent("Last device") {
                        Text(controller.state.lastRemoteDevice).foregroundStyle(.secondary).monospaced()
                    }
                }
                if let lastAt = controller.state.lastRemoteTranscriptAt {
                    LabeledContent("Last transcript") {
                        Text(lastAt, style: .relative).foregroundStyle(.secondary)
                    }
                }
                if let lastReply = controller.state.lastRemoteReplyAt {
                    LabeledContent("Last reply") {
                        Text(lastReply, style: .relative).foregroundStyle(.secondary)
                    }
                }
                if !controller.state.lastRemoteActivityText.isEmpty {
                    LabeledContent("Last activity") {
                        Text(controller.state.lastRemoteActivityText)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            } header: { Text("Remote Requests") }

            // Legacy port toggle removed — external WebSocket hosting is owned by JarvisBrainDaemon.
        }
        .formStyle(.grouped)
    }

    // MARK: - Helpers

    private var androidWebSocketURL: String {
        let port = controller.prefs.current.brainServerPort
        if let ip = controller.state.tailscaleIP {
            return "wss://\(ip):\(port)/v1/android/ws"
        }
        if let lan = TailscaleService.findLocalIP() {
            return "wss://\(lan):\(port)/v1/android/ws"
        }
        return "wss://<your-ip>:\(port)/v1/android/ws"
    }

}

// MARK: - QR Code

private struct QRCodeView: View {
    let content: String
    let size: CGFloat

    var body: some View {
        if let img = generateQR() {
            Image(nsImage: img)
                .interpolation(.none)
                .resizable()
                .frame(width: size, height: size)
        } else {
            Color.secondary.opacity(0.2)
                .frame(width: size, height: size)
        }
    }

    private func generateQR() -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(content.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}
