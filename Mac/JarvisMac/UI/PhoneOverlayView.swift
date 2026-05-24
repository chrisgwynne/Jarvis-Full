import SwiftUI

// MARK: - PhoneOverlayView

/// Dedicated overlay for Phase-1 remote call control.
///
/// Shows the live call state (ringing / active / ended) streamed from the
/// Android phone via `AppState`, and presents contextual action buttons that
/// send `AndroidCapability` commands back over the WebSocket bridge.
///
/// **No Mac audio is involved.** Audio stays on the Android phone / Bluetooth
/// headset / speakerphone. This overlay is purely a control surface.
struct PhoneOverlayView: View {

    let bridge: AndroidBridgeManager?
    let receiver: AndroidEventReceiver?
    let state: AppState?

    // ── Local UI state ────────────────────────────────────────────────────

    /// Tracks which button the user last tapped so we can show a brief spinner.
    @State private var pendingCommand: String? = nil
    /// Whether speakerphone is currently on (local optimistic state).
    @State private var isSpeakerOn: Bool = false
    /// Pulse animation driver for the "ringing" indicator.
    @State private var isPulsing: Bool = false

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerStrip
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

            Divider().opacity(0.3)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    activeCallSection
                    recentCallsSection
                }
                .padding(20)
            }
        }
    }

    // MARK: - Header strip

    private var headerStrip: some View {
        HStack(spacing: 12) {
            Image(systemName: headerIcon)
                .font(.title2)
                .foregroundColor(headerColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(.headline)
                    .foregroundColor(headerColor)
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Connection badge — read from @Observable AppState so the
            // badge auto-updates without requiring the overlay to be closed
            // and reopened (AndroidBridgeManager is not @Observable).
            if state?.androidBridgeConnected == true {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                    Text("Connected")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.secondary.opacity(0.4))
                        .frame(width: 6, height: 6)
                    Text("Offline")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var headerIcon: String {
        switch callState {
        case "ringing": return "phone.fill.arrow.down.left"
        case "active":  return "phone.connection.fill"
        case "ended":   return "phone.down.fill"
        default:        return "phone.fill"
        }
    }

    private var headerColor: Color {
        switch callState {
        case "ringing": return .green
        case "active":  return .green
        case "ended":   return .secondary
        default:        return .secondary
        }
    }

    private var headerTitle: String {
        switch callState {
        case "ringing": return "Incoming call"
        case "active":  return "Call in progress"
        case "ended":   return "Call ended"
        default:        return "Phone"
        }
    }

    private var headerSubtitle: String {
        switch callState {
        case "ringing": return callerName
        case "active":  return callerName
        case "ended":   return "Last call: \(callerName)"
        default:
            return state?.androidBridgeConnected == true ? "No active call" : "Open Jarvis on your phone"
        }
    }

    // MARK: - Active call section

    @ViewBuilder
    private var activeCallSection: some View {
        if callState == "ringing" {
            ringingCard
        } else if callState == "active" {
            activeCard
        } else if callState == "ended" {
            endedCard
        } else {
            idleCard
        }
    }

    // ── Ringing card ──────────────────────────────────────────────────────

    private var ringingCard: some View {
        VStack(spacing: 16) {
            // Caller avatar + pulse
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.15))
                    .frame(width: 80, height: 80)
                    .scaleEffect(isPulsing ? 1.15 : 1.0)
                    .opacity(isPulsing ? 0.6 : 1.0)
                    .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                               value: isPulsing)

                Circle()
                    .fill(Color.green.opacity(0.25))
                    .frame(width: 64, height: 64)

                Image(systemName: "phone.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.green)
            }
            .onAppear { isPulsing = true }

            Text(callerName)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)

            Text("Ringing…")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Action buttons
            HStack(spacing: 20) {
                callButton(
                    label: "Answer",
                    icon: "phone.fill",
                    color: .green,
                    command: AndroidCapability.answerCall
                )
                callButton(
                    label: "Decline",
                    icon: "phone.down.fill",
                    color: .red,
                    command: AndroidCapability.declineCall
                )
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // ── Active call card ──────────────────────────────────────────────────

    private var activeCard: some View {
        VStack(spacing: 16) {
            Circle()
                .fill(Color.green.opacity(0.2))
                .frame(width: 64, height: 64)
                .overlay {
                    Image(systemName: "phone.connection.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.green)
                }

            Text(callerName)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)

            // Elapsed timer
            if let startTime = state?.activeCallStartTime {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(elapsedString(from: startTime, to: context.date))
                        .font(.system(size: 28, weight: .light).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Active")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Action buttons
            HStack(spacing: 20) {
                callButton(
                    label: isSpeakerOn ? "Speaker Off" : "Speaker",
                    icon: isSpeakerOn ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    color: isSpeakerOn ? .orange : .blue,
                    command: isSpeakerOn ? AndroidCapability.speakerphoneOff : AndroidCapability.speakerphoneOn
                )
                callButton(
                    label: "Hang Up",
                    icon: "phone.down.fill",
                    color: .red,
                    command: AndroidCapability.endCall
                )
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // ── Ended card ────────────────────────────────────────────────────────

    private var endedCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "phone.down.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Call ended")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                if !callerName.isEmpty {
                    Text(callerName)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    // ── Idle card ─────────────────────────────────────────────────────────

    private var idleCard: some View {
        VStack(alignment: .center, spacing: 8) {
            Image(systemName: "phone")
                .font(.system(size: 32))
                .foregroundStyle(.secondary.opacity(0.4))
            Text("No active call")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Say \"answer it\", \"decline it\", or \"hang up\"")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    // MARK: - Recent calls section

    @ViewBuilder
    private var recentCallsSection: some View {
        let callTypes: [AndroidEventType] = [.incomingCall, .missedCall, .callAnswered, .callEnded]
        let events = receiver?.recentEvents.filter { callTypes.contains($0.type) } ?? []

        if !events.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("Recent Calls")

                ForEach(events.prefix(6)) { record in
                    recentCallRow(record)
                }
            }
        }
    }

    private func recentCallRow(_ record: AndroidEventRecord) -> some View {
        HStack(spacing: 10) {
            Image(systemName: record.type.systemImage)
                .font(.system(size: 13))
                .foregroundColor(callTypeColor(record.type))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(record.senderName ?? "Unknown caller")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                Text(record.type.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(relativeTime(record.timestamp))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private func callTypeColor(_ type: AndroidEventType) -> Color {
        switch type {
        case .incomingCall, .callAnswered: return .green
        case .missedCall:                  return .red
        case .callEnded:                   return .secondary
        default:                           return .secondary
        }
    }

    // MARK: - Reusable call button

    private func callButton(label: String, icon: String, color: Color, command: String) -> some View {
        let isPending = pendingCommand == command
        return Button {
            sendCommand(command)
            // Toggle speaker local state optimistically
            if command == AndroidCapability.speakerphoneOn  { isSpeakerOn = true  }
            if command == AndroidCapability.speakerphoneOff { isSpeakerOn = false }
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(color)
                        .frame(width: 52, height: 52)
                    if isPending {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 20))
                            .foregroundColor(.white)
                    }
                }
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
        .disabled(isPending || state?.androidBridgeConnected != true)
    }

    // MARK: - Command dispatch

    private func sendCommand(_ command: String) {
        guard state?.androidBridgeConnected == true else { return }
        pendingCommand = command
        Task {
            _ = await bridge?.sendToAndroid(command: command)
            await MainActor.run { pendingCommand = nil }
        }
    }

    // MARK: - Helpers

    private var callState: String { state?.activeCallState ?? "" }
    private var callerName: String {
        let n = state?.activeCallerName ?? ""
        return n.isEmpty ? "Unknown caller" : n
    }

    private func elapsedString(from start: Date, to now: Date) -> String {
        let secs = max(0, Int(now.timeIntervalSince(start)))
        let h = secs / 3600
        let m = (secs % 3600) / 60
        let s = secs % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    private func relativeTime(_ date: Date) -> String {
        let secs = max(0, Int(-date.timeIntervalSinceNow))
        if secs < 60  { return "Just now" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        return "\(secs / 3600)h ago"
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.secondary)
            .tracking(1.2)
            .padding(.bottom, 2)
    }
}
