import SwiftUI
import Foundation

// MARK: - Model

struct CommPrompt: Identifiable {
    let id: UUID
    let channelIcon: String
    let channelColor: Color
    let promptText: String
    let eventId: String
    let contactName: String
    let channel: String
    let receivedAt: Date
}

// MARK: - Actions

enum CommPromptAction: String, CaseIterable {
    case callBack      = "call_back"
    case reply         = "reply"
    case summarise     = "summarise"
    case remindLater   = "remind_later"
    case dismiss       = "dismiss"
}

// MARK: - Coordinator

@MainActor @Observable final class CommWatchdogCoordinator {
    static let shared = CommWatchdogCoordinator()

    var pendingPrompts: [CommPrompt] = []

    private init() {}

    func handle(_ payload: [String: Any]) {
        let eventId      = payload["eventId"]      as? String ?? UUID().uuidString
        let contactName  = payload["contactName"]  as? String ?? "Unknown"
        let channel      = payload["channel"]      as? String ?? "sms"
        let promptText   = payload["promptText"]   as? String ?? ""

        let (icon, color): (String, Color) = {
            switch channel.lowercased() {
            case "phone":
                return ("phone.arrow.down.fill", .red)
            case "sms":
                return ("message.fill", .blue)
            case "whatsapp", "whatsapp_business":
                return ("message.badge.filled.fill", .green)
            default:
                return ("message.fill", .blue)
            }
        }()

        let prompt = CommPrompt(
            id: UUID(),
            channelIcon: icon,
            channelColor: color,
            promptText: promptText,
            eventId: eventId,
            contactName: contactName,
            channel: channel,
            receivedAt: Date()
        )

        // Cap at 5 pending prompts — drop oldest if over limit
        if pendingPrompts.count >= 5 {
            pendingPrompts.removeFirst()
        }
        pendingPrompts.append(prompt)
    }

    func dismiss(id: UUID) {
        pendingPrompts.removeAll { $0.id == id }
    }

    func sendAction(for prompt: CommPrompt, action: CommPromptAction, via bridge: DaemonAppBridge) {
        let requestId = UUID().uuidString
        let envelope: [String: Any] = [
            "id": UUID().uuidString,
            "type": "comm.action.request",
            "sourceDeviceId": "mac",
            "sourcePlatform": "mac",
            "target": ["type": "android"],
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "correlationId": requestId,
            "payload": [
                "requestId": requestId,
                "eventId": prompt.eventId,
                "contactName": prompt.contactName,
                "channel": prompt.channel,
                "action": action.rawValue,
                "requiresConfirmation": true
            ] as [String: Any]
        ]
        bridge.send(envelope)
    }
}

// MARK: - Overlay View

struct CommWatchdogOverlayView: View {
    @State private var coordinator = CommWatchdogCoordinator.shared

    var body: some View {
        VStack(spacing: 10) {
            ForEach(coordinator.pendingPrompts) { prompt in
                CommPromptCard(prompt: prompt)
            }
        }
        .padding()
    }
}

// MARK: - Card View

struct CommPromptCard: View {
    let prompt: CommPrompt
    @State private var coordinator = CommWatchdogCoordinator.shared
    @Environment(\.daemonBridge) private var bridge

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header row
            HStack(spacing: 8) {
                Image(systemName: prompt.channelIcon)
                    .foregroundColor(prompt.channelColor)
                    .font(.system(size: 16, weight: .semibold))

                Text(prompt.contactName)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                Text(prompt.receivedAt, style: .relative)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            // Prompt text
            Text(prompt.promptText)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            // Action buttons
            HStack(spacing: 6) {
                actionButton("Call back", systemImage: "phone.fill") {
                    coordinator.sendAction(for: prompt, action: .callBack, via: DaemonAppBridge.shared)
                    coordinator.dismiss(id: prompt.id)
                }

                actionButton("Reply", systemImage: "arrowshape.turn.up.left.fill") {
                    coordinator.sendAction(for: prompt, action: .reply, via: DaemonAppBridge.shared)
                    coordinator.dismiss(id: prompt.id)
                }

                actionButton("Summarise", systemImage: "text.bubble.fill") {
                    coordinator.sendAction(for: prompt, action: .summarise, via: DaemonAppBridge.shared)
                    coordinator.dismiss(id: prompt.id)
                }

                actionButton("Remind later", systemImage: "clock.fill") {
                    coordinator.sendAction(for: prompt, action: .remindLater, via: DaemonAppBridge.shared)
                    coordinator.dismiss(id: prompt.id)
                }

                Spacer()

                Button {
                    coordinator.dismiss(id: prompt.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 18))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(NSColor.windowBackgroundColor))
                .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(prompt.channelColor.opacity(0.3), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func actionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                .foregroundColor(.accentColor)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Environment key for bridge (convenience)

private struct DaemonBridgeKey: EnvironmentKey {
    static let defaultValue: DaemonAppBridge = DaemonAppBridge.shared
}

extension EnvironmentValues {
    var daemonBridge: DaemonAppBridge {
        get { self[DaemonBridgeKey.self] }
        set { self[DaemonBridgeKey.self] = newValue }
    }
}
