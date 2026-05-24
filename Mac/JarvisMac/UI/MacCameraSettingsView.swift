import SwiftUI

/// Camera server settings — embedded in the Brain API settings tab.
struct MacCameraSettingsView: View {
    let controller: JarvisController
    @State private var snapshotURL = ""
    @State private var streamURL   = ""

    private var prefs: PreferencesStore { controller.prefs }
    private var diag:  MacCameraDiagnostics { controller.cameraDiagnostics }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Enable ────────────────────────────────────────────────────────
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Enable Camera Server", isOn: Binding(
                        get:  { prefs.current.cameraServerEnabled },
                        set: { v in prefs.update { $0.cameraServerEnabled = v }
                               v ? controller.startBrainServer()
                                 : controller.stopBrainServer()
                        }))
                    .toggleStyle(.switch)

                    Text("Exposes /camera/health, /camera/snapshot, /camera/stream on the same port as the Brain API server.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(6)
            } label: { Label("Camera Server", systemImage: "camera.fill") }

            Spacer().frame(height: 12)

            // ── Status ────────────────────────────────────────────────────────
            GroupBox {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    statusRow("Server",     diag.statusLine,                prefs.current.cameraServerEnabled ? .green : .secondary)
                    statusRow("Permission", diag.permission,                permissionColor)
                    statusRow("Capturing",  diag.isCapturing ? "Yes" : "No", diag.isCapturing ? .green : .secondary)
                    statusRow("Viewers",    "\(diag.activeViewers)",         diag.activeViewers > 0 ? .orange : .secondary)
                    if let t = diag.lastFrameTime {
                        statusRow("Last Frame", relativeTime(t), .secondary)
                    }
                    if let err = diag.lastStreamError {
                        statusRow("Last Error", err, .red)
                    }
                }
                .padding(6)
            } label: { Label("Status", systemImage: "info.circle") }

            Spacer().frame(height: 12)

            // ── Capture Settings ─────────────────────────────────────────────
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("FPS limit")
                        Spacer()
                        Picker("", selection: Binding(
                            get:  { prefs.current.cameraFPS },
                            set: { v in prefs.update { $0.cameraFPS = v }; controller.restartBrainServer() }
                        )) {
                            Text("1 fps").tag(1)
                            Text("5 fps").tag(5)
                            Text("10 fps").tag(10)
                        }
                        .labelsHidden()
                        .frame(width: 90)
                    }
                    HStack {
                        Text("JPEG quality")
                        Spacer()
                        Picker("", selection: Binding(
                            get:  { prefs.current.cameraJPEGQuality },
                            set: { v in prefs.update { $0.cameraJPEGQuality = v }; controller.restartBrainServer() }
                        )) {
                            Text("Low").tag("low")
                            Text("Medium").tag("medium")
                            Text("High").tag("high")
                        }
                        .labelsHidden()
                        .frame(width: 90)
                    }
                    Toggle("Keep camera warm", isOn: Binding(
                        get:  { prefs.current.keepCameraWarm },
                        set: { v in prefs.update { $0.keepCameraWarm = v }; controller.restartBrainServer() }
                    ))
                    .toggleStyle(.checkbox)
                    Text("When enabled, AVCaptureSession stays running even after all viewers disconnect.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(6)
            } label: { Label("Capture", systemImage: "video.fill") }

            Spacer().frame(height: 12)

            // ── Auth ──────────────────────────────────────────────────────────
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Require token for camera routes", isOn: Binding(
                        get:  { prefs.current.cameraServerRequireToken },
                        set: { v in prefs.update { $0.cameraServerRequireToken = v }; controller.restartBrainServer() }
                    ))
                    .toggleStyle(.checkbox)
                    Text("Uses the same Bearer token as the Brain API. Disable only for local browser testing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(6)
            } label: { Label("Authentication", systemImage: "lock.fill") }

            Spacer().frame(height: 12)

            // ── URLs ──────────────────────────────────────────────────────────
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    urlRow("Health",   "http://<mac-ip>:\(prefs.current.brainServerPort)/camera/health")
                    urlRow("Snapshot", "http://<mac-ip>:\(prefs.current.brainServerPort)/camera/snapshot")
                    urlRow("Stream",   "http://<mac-ip>:\(prefs.current.brainServerPort)/camera/stream")
                }
                .padding(6)
            } label: { Label("Endpoints", systemImage: "link") }

            // ── Camera active indicator ───────────────────────────────────────
            if diag.activeViewers > 0 {
                Spacer().frame(height: 12)
                HStack(spacing: 6) {
                    Circle().fill(.orange).frame(width: 8, height: 8)
                    Text("Mac camera is being viewed (\(diag.activeViewers) active \(diag.activeViewers == 1 ? "viewer" : "viewers"))")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Helpers

    private var permissionColor: Color {
        switch diag.permission {
        case "granted":       return .green
        case "denied":        return .red
        default:              return .secondary
        }
    }

    @ViewBuilder
    private func statusRow(_ label: String, _ value: String, _ color: Color) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).foregroundStyle(color).gridColumnAlignment(.leading)
        }
    }

    @ViewBuilder
    private func urlRow(_ label: String, _ url: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
            Text(url)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let s = -date.timeIntervalSinceNow
        if s < 1 { return "just now" }
        if s < 60 { return "\(Int(s))s ago" }
        return "\(Int(s / 60))m ago"
    }
}
