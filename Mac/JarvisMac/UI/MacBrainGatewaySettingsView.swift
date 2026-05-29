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

    @State private var pairingCountdown: Int = 0
    @State private var pairingTimer: Timer? = nil
    @State private var urlCopied = false
    @State private var pairingError: String? = nil

    private var diag: GatewayDiagnostics { controller.gatewayDiagnostics }
    @State private var authStore: GatewayAuthStore = GatewayAuthStore.shared

    var body: some View {
        Form {
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
                Text("Unified gateway on port \(controller.prefs.current.brainServerPort) serving Brain API, Windows sidecar, and Android WebSocket. Android connects to wss://…:\(controller.prefs.current.brainServerPort)/v1/android/ws.")
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
                        Text("\(controller.prefs.current.brainServerPort)")
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

            // ── Pairing ───────────────────────────────────────────────────
            Section {
                if let code = authStore.activePairingCode, !code.isExpired {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 16) {
                            // SECURITY (#14): the QR encodes ONLY connection coordinates
                            // and the one-time 6-digit pairing code — never the master
                            // gateway token. Android exchanges the code for a scoped
                            // device token over the wire; the master token stays in the
                            // Mac Keychain and is never displayed, copied, or QR-encoded.
                            let host = controller.state.tailscaleIP
                                ?? TailscaleService.findLocalIP()
                                ?? "127.0.0.1"
                            let port = controller.prefs.current.brainServerPort
                            let qrJSON = "{\"host\":\"\(host)\",\"port\":\(port),\"code\":\"\(code.code)\"}"
                            QRCodeView(content: qrJSON, size: 140)
                                .cornerRadius(8)

                            VStack(alignment: .leading, spacing: 6) {
                                Text(code.code)
                                    .font(.system(size: 36, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.green)
                                Text("Expires in \(pairingCountdown)s")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Text("Scan the QR code with the Android Jarvis app to pair, or type the 6-digit code manually. The code expires shortly and grants a scoped device token — it never exposes the master key.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Button("Generate Pairing Code") {
                        pairingError = nil
                        Task { await generateDaemonPairingCode() }
                    }
                    .buttonStyle(.borderless)
                    if let err = pairingError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    } else {
                        Text("Generates a one-time 6-digit code the Android app uses to receive a scoped device token.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: { Text("Pairing") }

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
        .onDisappear {
            pairingTimer?.invalidate()
            pairingTimer = nil
        }
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

    private func generateDaemonPairingCode() async {
        guard let url = URL(string: "http://127.0.0.1:8765/v1/android/pair/code") else { return }

        // Ensure a gateway token exists — first time setup
        let token = GatewayAuthStore.shared.gatewayToken ?? GatewayAuthStore.shared.regenerateGatewayToken()

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 5

        guard let (data, response) = try? await URLSession.shared.data(for: req) else {
            pairingError = "Could not reach daemon on port 8765. Is it running?"
            return
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            pairingError = "Daemon rejected request (wrong token?). Restart the daemon."
            return
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = json["code"] as? String,
              let expiresStr = json["expiresAt"] as? String,
              let expiresAt = ISO8601DateFormatter().date(from: expiresStr) else {
            pairingError = "Unexpected response from daemon."
            return
        }
        pairingError = nil
        let pairing = ActivePairingCode(code: code, expiresAt: expiresAt)
        authStore.setActivePairingCode(pairing)
        pairingCountdown = Int(expiresAt.timeIntervalSinceNow)
        startPairingTimer()
    }

    private func startPairingTimer() {
        pairingTimer?.invalidate()
        pairingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            if let code = authStore.activePairingCode {
                let remaining = Int(code.expiresAt.timeIntervalSinceNow)
                pairingCountdown = max(0, remaining)
                diag.pairingCodeActive = remaining > 0
                if remaining <= 0 {
                    pairingTimer?.invalidate()
                    pairingTimer = nil
                }
            } else {
                pairingTimer?.invalidate()
                pairingTimer = nil
                diag.pairingCodeActive = false
            }
        }
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
