import SwiftUI

/// Settings tab for the Mac Brain HTTP server.
/// Lets the user enable/disable the server, configure the port, manage the
/// auth token, and view live diagnostics.
struct MacBrainSettingsView: View {
    let controller: JarvisController

    private var diag: BrainDiagnostics { controller.brainDiagnostics }

    var body: some View {
        Form {
            // ── Enable ─────────────────────────────────────────────────────
            Section {
                Toggle("Enable Mac Brain server",
                       isOn: Binding(
                           get: { controller.prefs.current.brainServerEnabled },
                           set: { v in
                               controller.prefs.update { $0.brainServerEnabled = v }
                               if v { controller.startBrainServer() }
                               else { controller.stopBrainServer() }
                           }
                       ))
                Text("Exposes GET /brain/health, POST /brain/context, and POST /brain/interactions on the local network. Android Jarvis connects to this as its memory and context source.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Mac Brain HTTP API") }

            // ── Status ─────────────────────────────────────────────────────
            Section {
                HStack(spacing: 10) {
                    Circle()
                        .fill(diag.isRunning ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                    Text(diag.statusLine)
                        .font(.system(.body, design: .monospaced))
                }
                if controller.prefs.current.brainServerEnabled {
                    LabeledContent("Requests served") {
                        Text("\(diag.requestsServed)")
                            .foregroundStyle(.secondary)
                    }
                    if diag.unauthorizedAttempts > 0 {
                        LabeledContent("Unauthorized attempts") {
                            Text("\(diag.unauthorizedAttempts)")
                                .foregroundStyle(.orange)
                        }
                    }
                    if let contextAt = diag.lastContextAt {
                        LabeledContent("Last context request") {
                            Text(contextAt, style: .relative)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: { Text("Status") }

            // ── Port ───────────────────────────────────────────────────────
            Section {
                LabeledContent("Port") {
                    HStack(spacing: 6) {
                        Stepper(value: Binding(
                            get: { Int(controller.prefs.current.brainServerPort) },
                            set: { v in
                                let p = UInt16(clamping: v)
                                controller.prefs.update { $0.brainServerPort = p }
                                if controller.prefs.current.brainServerEnabled {
                                    controller.restartBrainServer()
                                }
                            }
                        ), in: 1024...65535, step: 1) {
                            Text("\(controller.prefs.current.brainServerPort)")
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 55, alignment: .trailing)
                                .monospacedDigit()
                        }
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
                Text("On: only the local machine can connect. Off: any device on the same Wi-Fi or Tailscale network can connect (recommended for Android).")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Network") }

            // ── Camera Server ─────────────────────────────────────────────
            Section {
                MacCameraSettingsView(controller: controller)
            } header: { Text("Camera Streaming") }

            // ── Distributed diagnostics ────────────────────────────────────
            Section {
                DistributedDiagnosticsView()
                    .frame(maxWidth: .infinity, minHeight: 520)
            } header: { Text("Distributed Diagnostics") }
        }
        .formStyle(.grouped)
    }
}
