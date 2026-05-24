import SwiftUI

// MARK: - AndroidOverlayView

/// Displays Android phone events (calls, messages), bridge connection status,
/// device info, capabilities, and diagnostics.
struct AndroidOverlayView: View {

    let bridge: AndroidBridgeManager?
    let eventReceiver: AndroidEventReceiver?
    let state: AppState?

    // Backwards-compatible init when no event receiver is available
    init(bridge: AndroidBridgeManager?,
         eventReceiver: AndroidEventReceiver? = nil,
         state: AppState? = nil) {
        self.bridge = bridge
        self.eventReceiver = eventReceiver
        self.state = state
    }

    // Pull diagnostics from bridge; default to empty struct when nil
    private var diag: AndroidBridgeDiagnostics {
        bridge?.diagnostics ?? AndroidBridgeDiagnostics()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header strip ──────────────────────────────────────────────
            headerStrip
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

            Divider().opacity(0.3)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Phone events first (most useful)
                    if let receiver = eventReceiver, !receiver.recentEvents.isEmpty {
                        phoneEventsSection(receiver: receiver)
                    }
                    if let receiver = eventReceiver,
                       !receiver.pendingPermissions.isEmpty {
                        permissionsSection(receiver: receiver)
                    }
                    deviceSection
                    capabilitiesSection
                    diagnosticsSection
                    // Event stats
                    if let s = state, s.androidEventCount > 0 {
                        eventStatsSection(state: s)
                    }
                }
                .padding(20)
            }
        }
    }

    // MARK: - Header

    private var headerStrip: some View {
        HStack(spacing: 12) {
            Image(systemName: diag.isConnected
                  ? "antenna.radiowaves.left.and.right"
                  : "antenna.radiowaves.left.and.right.slash")
                .font(.title2)
                .foregroundColor(diag.isConnected ? .green : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(diag.isConnected ? "Connected" : "Offline")
                    .font(.headline)
                    .foregroundColor(diag.isConnected ? .green : .secondary)
                Text(diag.isConnected
                     ? (diag.deviceName.isEmpty ? "Android device" : diag.deviceName)
                     : "Open Jarvis on your phone")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Battery badge
            if diag.isConnected && diag.batteryLevel >= 0 {
                batteryBadge(level: diag.batteryLevel)
            }
        }
    }

    private func batteryBadge(level: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: batterySymbol(for: level))
                .font(.body)
                .foregroundColor(batteryColor(for: level))
            Text("\(level)%")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func batterySymbol(for level: Int) -> String {
        switch level {
        case 88...: return "battery.100"
        case 63...: return "battery.75"
        case 38...: return "battery.50"
        case 13...: return "battery.25"
        default:    return "battery.0"
        }
    }

    private func batteryColor(for level: Int) -> Color {
        level < 20 ? .red : level < 40 ? .orange : .green
    }

    // MARK: - Device info section

    private var deviceSection: some View {
        Group {
            sectionHeader("Device")

            infoRow("Device", diag.deviceName.isEmpty ? "—" : diag.deviceName)

            let heartbeatText: String = {
                guard let hb = diag.lastHeartbeat else { return "Never" }
                let secs = Int(-hb.timeIntervalSinceNow)
                if secs < 10 { return "Just now" }
                if secs < 60 { return "\(secs)s ago" }
                return "\(secs / 60)m ago"
            }()
            infoRow("Last heartbeat", heartbeatText)

            if diag.roundtripLatencyMs >= 0 {
                infoRow("Latency", "\(diag.roundtripLatencyMs) ms")
            }
        }
    }

    // MARK: - Capabilities section

    private var capabilitiesSection: some View {
        Group {
            sectionHeader("Capabilities")

            if diag.capabilities.isEmpty {
                Text(diag.isConnected ? "Syncing…" : "Connect phone to see capabilities")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                let known: [(String, String)] = [
                    (AndroidCapability.callContact,      "Call contacts"),
                    (AndroidCapability.sendSMS,          "Send SMS"),
                    (AndroidCapability.sendWhatsApp,     "Send WhatsApp"),
                    (AndroidCapability.findContact,      "Find contacts"),
                    (AndroidCapability.ringPhone,        "Ring / find phone"),
                    (AndroidCapability.phoneLocation,    "Phone location"),
                    (AndroidCapability.navigation,       "Navigation"),
                    (AndroidCapability.readNotifications,"Read notifications"),
                    (AndroidCapability.captureCamera,    "Phone camera"),
                ]
                ForEach(known, id: \.0) { cap, label in
                    capabilityRow(label: label, supported: diag.capabilities.contains(cap))
                }
            }
        }
    }

    private func capabilityRow(label: String, supported: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: supported ? "checkmark.circle.fill" : "xmark.circle")
                .font(.caption)
                .foregroundColor(supported ? .green : .secondary.opacity(0.5))
            Text(label)
                .font(.caption)
                .foregroundColor(supported ? .primary : .secondary)
            Spacer()
        }
        .padding(.vertical, 1)
    }

    // MARK: - Diagnostics section

    private var diagnosticsSection: some View {
        Group {
            sectionHeader("Diagnostics")

            if !diag.lastCommandId.isEmpty {
                infoRow("Last command", String(diag.lastCommandId.prefix(8)) + "…")
                infoRow("Last status", diag.lastCommandStatus)
            }

            if diag.authFailures > 0 {
                infoRow("Auth failures", "\(diag.authFailures)",
                        valueColor: .red)
            }

            if diag.timeouts > 0 {
                infoRow("Timeouts", "\(diag.timeouts)",
                        valueColor: .orange)
            }

            if let sync = diag.capabilitiesLastSync {
                let secs = Int(-sync.timeIntervalSinceNow)
                infoRow("Caps synced", secs < 60 ? "\(secs)s ago" : "\(secs/60)m ago")
            }

            if diag.authFailures == 0 && diag.timeouts == 0
                && diag.lastCommandId.isEmpty {
                Text(diag.isConnected ? "No commands sent yet." : "Waiting for phone.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Phone events section

    private func phoneEventsSection(receiver: AndroidEventReceiver) -> some View {
        Group {
            sectionHeader("Recent Activity")

            ForEach(receiver.recentEvents.prefix(8)) { record in
                phoneEventRow(record)
            }
        }
    }

    private func phoneEventRow(_ record: AndroidEventRecord) -> some View {
        HStack(spacing: 10) {
            Image(systemName: record.type.systemImage)
                .font(.system(size: 14))
                .foregroundColor(phoneEventColor(record.type))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(record.type.displayName)
                        .font(.caption)
                        .fontWeight(.medium)
                    if let sender = record.senderName {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text(sender)
                            .font(.caption)
                            .foregroundStyle(.primary)
                    } else if let app = record.appName {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text(app)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(relativeTime(record.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func phoneEventColor(_ type: AndroidEventType) -> Color {
        switch type {
        case .incomingCall, .callAnswered: return .green
        case .missedCall:                  return .red
        case .callEnded:                   return .secondary
        case .smsReceived:                 return .blue
        case .whatsAppReceived:            return .green
        case .notificationReceived:        return .orange
        case .batteryStatus:               return .yellow
        case .permissionRequired:          return .red
        default:                           return .secondary
        }
    }

    // MARK: - Permissions section

    private func permissionsSection(receiver: AndroidEventReceiver) -> some View {
        Group {
            sectionHeader("Permission Warnings")

            ForEach(receiver.pendingPermissions, id: \.name) { perm in
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.caption)
                        .foregroundColor(.red)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(perm.description)
                            .font(.caption)
                            .foregroundStyle(.primary)
                        Text("Open Jarvis on your phone to grant")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Event stats section

    private func eventStatsSection(state: AppState) -> some View {
        Group {
            sectionHeader("Event Stats")
            infoRow("Events received", "\(state.androidEventCount)")
            if state.androidEventDedupeSuppressed > 0 {
                infoRow("Deduped", "\(state.androidEventDedupeSuppressed)")
            }
            if !state.lastAndroidEventType.isEmpty {
                infoRow("Last event", state.lastAndroidEventType)
            }
        }
    }

    // MARK: - Helpers

    private func relativeTime(_ date: Date) -> String {
        let secs = Int(-date.timeIntervalSinceNow)
        if secs < 10  { return "Just now" }
        if secs < 60  { return "\(secs)s ago" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        return "\(secs / 3600)h ago"
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.secondary)
            .tracking(1.2)
            .padding(.bottom, 4)
    }

    private func infoRow(_ label: String, _ value: String,
                         valueColor: Color = .primary) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundColor(valueColor)
            Spacer()
        }
        .padding(.vertical, 1)
    }
}
