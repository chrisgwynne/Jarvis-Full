import Foundation
import CryptoKit

// MARK: - Event type

/// Classifies each phone/device event broadcast from the Android Jarvis app.
enum AndroidEventType: String, Codable, CaseIterable {
    case incomingCall         = "incoming_call"
    case missedCall           = "missed_call"
    case callAnswered         = "call_answered"
    case callEnded            = "call_ended"
    case smsReceived          = "sms_received"
    case whatsAppReceived     = "whatsapp_received"
    case notificationReceived = "notification_received"
    case batteryStatus        = "battery_status"
    case permissionRequired   = "permission_required"
    case heartbeat            = "heartbeat"
    case unknown              = "unknown"

    var displayName: String {
        switch self {
        case .incomingCall:         return "Incoming call"
        case .missedCall:           return "Missed call"
        case .callAnswered:         return "Call answered"
        case .callEnded:            return "Call ended"
        case .smsReceived:          return "SMS"
        case .whatsAppReceived:     return "WhatsApp"
        case .notificationReceived: return "Notification"
        case .batteryStatus:        return "Battery"
        case .permissionRequired:   return "Permission needed"
        case .heartbeat:            return "Heartbeat"
        case .unknown:              return "Event"
        }
    }

    var systemImage: String {
        switch self {
        case .incomingCall, .callAnswered: return "phone.fill"
        case .missedCall:                  return "phone.down.fill"
        case .callEnded:                   return "phone.fill.arrow.down.left"
        case .smsReceived:                 return "message.fill"
        case .whatsAppReceived:            return "bubble.left.fill"
        case .notificationReceived:        return "bell.fill"
        case .batteryStatus:               return "battery.50"
        case .permissionRequired:          return "exclamationmark.shield.fill"
        case .heartbeat:                   return "heart.fill"
        case .unknown:                     return "questionmark.circle"
        }
    }

    /// True for event types that carry a sender identity.
    var hasSender: Bool {
        switch self {
        case .incomingCall, .missedCall, .callAnswered, .callEnded,
             .smsReceived, .whatsAppReceived:
            return true
        default:
            return false
        }
    }
}

// MARK: - AndroidPhoneEvent

/// A phone/device event broadcast from the Android Jarvis app.
///
/// Decoded from the WS frame payload. All fields are optional to
/// handle partial implementations on the Android side gracefully.
///
/// **Privacy notes:**
///  - `senderNumber` (raw E.164) is NEVER written to logs.
///  - `messageBody` is only included when `messagePreviewEnabled` is `true`.
struct AndroidPhoneEvent: Decodable {

    // ── Identity ─────────────────────────────────────────────────────────
    /// UUID from Android. Used as the primary deduplication key.
    let eventId: String
    /// Discriminator for the event payload structure.
    let type: AndroidEventType
    /// When the event occurred on the device.
    let timestamp: Date

    // ── Caller / sender ──────────────────────────────────────────────────
    /// Resolved contact display name, or `nil` if not in contacts.
    let senderName: String?
    /// Raw phone number — private, never logged.
    let senderNumber: String?
    /// Android contact ID, for precise re-dial via `call_contact` with `contactId`.
    let contactId: String?
    /// Group / conversation title when the message arrived in a group
    /// chat (WhatsApp / SMS-group / RCS).  Nil for direct messages.
    /// Mac uses this to say "You've had a WhatsApp in Family Group from
    /// Cath" instead of just "You've had a WhatsApp from Cath".
    let groupName: String?

    // ── Message content ──────────────────────────────────────────────────
    /// SMS or WhatsApp body. `nil` when user has disabled preview sharing.
    let messageBody: String?
    /// Whether the Android app is configured to send message previews.
    let messagePreviewEnabled: Bool

    // ── Notification fields ──────────────────────────────────────────────
    let appName: String?
    let appPackage: String?
    let notificationTitle: String?
    let notificationBody: String?

    // ── Call ─────────────────────────────────────────────────────────────
    /// TelecomManager call state string: "ringing" | "active" | "held" | "disconnected"
    let callState: String?
    let callDurationSeconds: Int?

    // ── Battery ──────────────────────────────────────────────────────────
    let batteryLevel: Int?
    let isCharging: Bool?

    // ── Permission ───────────────────────────────────────────────────────
    let permissionName: String?
    let permissionDescription: String?

    // MARK: - Coding keys

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case type, timestamp
        case senderName = "sender_name"
        case senderNumber = "sender_number"
        case contactId = "contact_id"
        case groupName = "group_name"
        case messageBody = "message_body"
        case messagePreviewEnabled = "message_preview_enabled"
        case appName = "app_name"
        case appPackage = "app_package"
        case notificationTitle = "notification_title"
        case notificationBody = "notification_body"
        case callState = "call_state"
        case callDurationSeconds = "call_duration_seconds"
        case batteryLevel = "battery_level"
        case isCharging = "is_charging"
        case permissionName = "permission_name"
        case permissionDescription = "permission_description"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        eventId = (try? c.decodeIfPresent(String.self, forKey: .eventId)) ?? UUID().uuidString
        type    = (try? c.decode(AndroidEventType.self, forKey: .type)) ?? .unknown

        // Timestamp: try ISO-8601 string, then epoch-milliseconds Double, then now
        if let iso = try? c.decodeIfPresent(String.self, forKey: .timestamp),
           let date = ISO8601DateFormatter().date(from: iso) {
            timestamp = date
        } else if let ms = try? c.decodeIfPresent(Double.self, forKey: .timestamp) {
            timestamp = Date(timeIntervalSince1970: ms / 1000.0)
        } else {
            timestamp = Date()
        }

        senderName            = try? c.decodeIfPresent(String.self, forKey: .senderName)
        senderNumber          = try? c.decodeIfPresent(String.self, forKey: .senderNumber)
        contactId             = try? c.decodeIfPresent(String.self, forKey: .contactId)
        groupName             = try? c.decodeIfPresent(String.self, forKey: .groupName)
        messageBody           = try? c.decodeIfPresent(String.self, forKey: .messageBody)
        messagePreviewEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .messagePreviewEnabled)) ?? true
        appName               = try? c.decodeIfPresent(String.self, forKey: .appName)
        appPackage            = try? c.decodeIfPresent(String.self, forKey: .appPackage)
        notificationTitle     = try? c.decodeIfPresent(String.self, forKey: .notificationTitle)
        notificationBody      = try? c.decodeIfPresent(String.self, forKey: .notificationBody)
        callState             = try? c.decodeIfPresent(String.self, forKey: .callState)
        callDurationSeconds   = try? c.decodeIfPresent(Int.self,    forKey: .callDurationSeconds)
        batteryLevel          = try? c.decodeIfPresent(Int.self,    forKey: .batteryLevel)
        isCharging            = try? c.decodeIfPresent(Bool.self,   forKey: .isCharging)
        permissionName        = try? c.decodeIfPresent(String.self, forKey: .permissionName)
        permissionDescription = try? c.decodeIfPresent(String.self, forKey: .permissionDescription)
    }

    // MARK: - Helpers

    /// Display name or "Unknown" for anonymous senders.
    var displaySender: String { senderName ?? "someone" }

    /// SHA-256 of message body, used for content-duplicate detection.
    func bodyHash() -> String? {
        guard let body = messageBody, !body.isEmpty else { return nil }
        let data = Data(body.utf8)
        return SHA256.hash(data: data)
            .compactMap { String(format: "%02x", $0) }
            .joined()
    }
}

// MARK: - AndroidEventRecord  (persisted / overlay display)

/// Lightweight persisted snapshot of a phone event.
/// Stored to prevent re-alerting the same event after an app restart.
struct AndroidEventRecord: Codable, Identifiable {
    let id: String                  // == eventId from AndroidPhoneEvent
    let type: AndroidEventType
    let timestamp: Date
    let senderName: String?
    let appName: String?
    let contentHash: String?        // SHA-256 of message body (nil for calls)
    var wasSpoken: Bool
    var wasOpened: Bool
}
