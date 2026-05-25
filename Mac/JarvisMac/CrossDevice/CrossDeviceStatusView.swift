import SwiftUI
import Foundation

// MARK: - Model

struct ConnectedDevice: Identifiable {
    let id: String
    let name: String
    let platform: String
    let lastSeen: String
    let capabilities: [String]
}

// MARK: - ViewModel

@MainActor @Observable final class CrossDeviceViewModel {
    static let shared = CrossDeviceViewModel()

    var devices: [ConnectedDevice] = []
    var isDaemonConnected: Bool = false
    var watchdogEnabled: Bool = true

    private init() {}

    func refresh() {
        Task {
            do {
                guard let url = URL(string: "http://127.0.0.1:8765/v1/devices") else { return }
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    await MainActor.run { self.isDaemonConnected = false }
                    return
                }
                let parsed = json.compactMap { dict -> ConnectedDevice? in
                    guard let id = dict["id"] as? String else { return nil }
                    let name         = dict["name"]         as? String ?? id
                    let platform     = dict["platform"]     as? String ?? "unknown"
                    let lastSeen     = dict["lastSeen"]     as? String ?? "—"
                    let capabilities = dict["capabilities"] as? [String] ?? []
                    return ConnectedDevice(
                        id: id,
                        name: name,
                        platform: platform,
                        lastSeen: lastSeen,
                        capabilities: capabilities
                    )
                }
                await MainActor.run {
                    self.devices = parsed
                    self.isDaemonConnected = true
                }
            } catch {
                await MainActor.run {
                    self.isDaemonConnected = false
                }
            }
        }
    }
}

// MARK: - View

struct CrossDeviceStatusView: View {
    @State private var viewModel = CrossDeviceViewModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Daemon connection status
            HStack(spacing: 8) {
                Circle()
                    .fill(viewModel.isDaemonConnected ? Color.green : Color.red)
                    .frame(width: 10, height: 10)
                Text(viewModel.isDaemonConnected ? "Daemon connected" : "Daemon offline")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button("Refresh") { viewModel.refresh() }
                    .font(.caption)
                    .buttonStyle(.borderless)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
            )

            // Watchdog toggle
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Comm Watchdog")
                        .font(.subheadline.weight(.medium))
                    Text("Surfaces missed calls and unread messages")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: $viewModel.watchdogEnabled)
                    .labelsHidden()
                    .onChange(of: viewModel.watchdogEnabled) { _, enabled in
                        let envelope: [String: Any] = [
                            "id": UUID().uuidString,
                            "type": "context.update",
                            "sourceDeviceId": "mac",
                            "sourcePlatform": "mac",
                            "target": ["type": "broadcast"],
                            "timestamp": ISO8601DateFormatter().string(from: Date()),
                            "payload": ["watchdogEnabled": enabled]
                        ]
                        DaemonAppBridge.shared.send(envelope)
                    }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
            )

            // Connected devices list
            if viewModel.devices.isEmpty {
                Text("No connected devices")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 1) {
                    ForEach(viewModel.devices) { device in
                        DeviceRow(device: device)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(NSColor.controlBackgroundColor))
                )
            }
        }
        .padding()
        .onAppear { viewModel.refresh() }
    }
}

// MARK: - Device Row

private struct DeviceRow: View {
    let device: ConnectedDevice

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: platformIcon)
                .font(.system(size: 14))
                .foregroundColor(.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    platformBadge

                    Text("· \(device.lastSeen)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if !device.capabilities.isEmpty {
                Text(device.capabilities.prefix(2).joined(separator: ", "))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var platformIcon: String {
        switch device.platform.lowercased() {
        case "android": return "iphone"
        case "windows": return "desktopcomputer"
        case "mac":     return "laptopcomputer"
        default:        return "dot.radiowaves.left.and.right"
        }
    }

    private var platformBadge: some View {
        Text(device.platform.capitalized)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            .foregroundColor(.accentColor)
    }
}
