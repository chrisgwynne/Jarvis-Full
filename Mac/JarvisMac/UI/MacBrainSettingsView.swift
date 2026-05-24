import SwiftUI

/// Settings tab for the Mac Brain HTTP server.
/// Lets the user enable/disable the server, configure the port, manage the
/// auth token, and view live diagnostics.
struct MacBrainSettingsView: View {
    let controller: JarvisController

    @State private var tokenDraft: String = ""
    @State private var tokenCopied = false
    @State private var tokenRegenConfirm = false

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

            // ── Auth token ─────────────────────────────────────────────────
            Section {
                LabeledContent("Bearer token") {
                    HStack(spacing: 6) {
                        SecureField("Not configured", text: $tokenDraft)
                            .onAppear {
                                tokenDraft = Keychain.get(KeychainAccount.brainServerToken) ?? ""
                            }
                            .onChange(of: tokenDraft) { _, v in
                                let trimmed = v.trimmingCharacters(in: .whitespaces)
                                if trimmed.isEmpty {
                                    Keychain.remove(KeychainAccount.brainServerToken)
                                } else {
                                    Keychain.set(trimmed, for: KeychainAccount.brainServerToken)
                                }
                            }

                        Button {
                            let tok = Keychain.get(KeychainAccount.brainServerToken) ?? ""
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(tok, forType: .string)
                            tokenCopied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { tokenCopied = false }
                        } label: {
                            Image(systemName: tokenCopied ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .disabled((Keychain.get(KeychainAccount.brainServerToken) ?? "").isEmpty)

                        Button("Regenerate") { tokenRegenConfirm = true }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.orange)
                    }
                }

                Text("Set in Android Jarvis settings as the Brain token. Leave empty to disable authentication (not recommended on a shared network).")
                    .font(.caption).foregroundStyle(.secondary)

                Button("Generate random token") {
                    let newToken = UUID().uuidString + "-" + UUID().uuidString
                    Keychain.set(newToken, for: KeychainAccount.brainServerToken)
                    tokenDraft = newToken
                }
                .buttonStyle(.borderless)
                .font(.caption)
            } header: { Text("Authentication") }

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
        .confirmationDialog("Regenerate token?",
                           isPresented: $tokenRegenConfirm,
                           titleVisibility: .visible) {
            Button("Regenerate", role: .destructive) {
                let newToken = UUID().uuidString + "-" + UUID().uuidString
                Keychain.set(newToken, for: KeychainAccount.brainServerToken)
                tokenDraft = newToken
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The old token will stop working immediately. Update Android Jarvis settings with the new token.")
        }
    }
}
