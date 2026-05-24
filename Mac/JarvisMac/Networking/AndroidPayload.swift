import Foundation

// MARK: - Mac → Android (outbound commands)

/// Conversational context attached to every outbound command so the Android
/// app knows what the user originally said and which Mac session it belongs to.
struct AndroidCommandContext: Encodable {
    /// The raw transcript that triggered this command (e.g. "call Cath").
    let transcript: String?
    /// Mac session ID for correlation / logging.
    let sessionId: String?
}

/// A command pushed from Mac to the connected Android device.
/// Sent via `WebSocketServer.broadcast(data:)`.
struct AndroidCommand: Encodable {
    let id: String              // UUID — used to correlate the response
    let type: String = "request"
    let source: String = "mac"
    let target: String = "android"
    let command: String         // e.g. "call_contact", "send_sms", "ring_phone"
    let payload: AndroidCommandPayload?
    let context: AndroidCommandContext?
    let auth: String?           // mirrors webSocketAuthToken when auth is required
}

/// Payload fields for outbound commands. Most fields are optional; only the
/// relevant subset is populated per command.
struct AndroidCommandPayload: Encodable {
    var contact: String?        // contact name (for call/SMS/WhatsApp)
    var contactId: String?      // resolved contact ID (after disambiguation)
    var recipient: String?      // explicit recipient override
    var message: String?        // text body for SMS / WhatsApp
    var destination: String?    // navigation destination
    var query: String?          // generic search / query string
    var app: String?            // app name for notification query
    /// WhatsApp call type — `"voice"` or `"video"`.  Only meaningful on
    /// `whatsapp_voice_call` / `whatsapp_video_call` commands.  Android
    /// resolves the contact via Contacts → WhatsApp account lookup and
    /// launches the matching deep link.
    var callType: String?
}

// MARK: - Android → Mac (inbound discriminator)

/// Minimal envelope decoded first to determine whether an inbound WS frame
/// is a *command* (Android→Mac, handled by existing logic) or a *response*
/// (correlated reply to a Mac→Android request) or an *event* (heartbeat, etc.).
///
/// Android apps may use slightly different field names depending on version:
///   - Canonical:  `type: "event"`, `command: "incoming_call"`, top-level event fields
///   - Envelope:   `type: "phone_event"`, `event: "incoming_call"`, `payload: {...}`
///   - Heartbeat:  `type: "heartbeat"` (no separate command field needed)
struct BridgeEnvelope: Decodable {
    let id: String?
    let type: String?    // "request" | "response" | "event" | "phone_event" | "heartbeat" | …
    let command: String? // event sub-type in canonical format
    let event: String?   // event sub-type in Android-envelope format (some versions use this instead of command)
    let source: String?  // "android" | "mac"
    /// Shared secret — required on every inbound frame when
    /// `requireWebSocketAuth` is true.  Android clients must include the same
    /// token they receive during pairing on **every** frame (commands, events,
    /// responses, heartbeats).  Frames missing or mismatching this field are
    /// rejected at the inbound gate before any routing.
    let auth: String?

    /// Canonical event sub-type name — tries `command` first, then `event`.
    var commandOrEvent: String? { command ?? event }
}

// MARK: - Android native phone event envelope
// (for Android apps that wrap phone events in an outer envelope with a `payload` object)

/// Flexible decoder for the Android-native phone event envelope format.
///
/// Handles both camelCase (`contactName`) and snake_case (`contact_name`)
/// field names in the `payload` block.
///
/// Example inbound frame:
/// ```json
/// {
///   "id": "uuid", "type": "phone_event", "event": "incoming_call",
///   "payload": { "contactName": "Alice", "phoneNumber": "+44..." }
/// }
/// ```
struct AndroidNativePhoneEnvelope: Decodable {
    let id: String?
    let type: String?    // "phone_event" | "event"
    let event: String?   // event sub-type
    let command: String? // alternative sub-type field
    let payload: NativePayload?

    /// The event sub-type (e.g. "incoming_call").
    var eventSubtype: String? { event ?? command }

    struct NativePayload: Decodable {
        var contactName: String?
        var senderName: String?
        var callerName: String?
        var phoneNumber: String?
        var messageBody: String?
        var appName: String?
        var batteryLevel: Int?
        var isCharging: Bool?
        var permissionName: String?
        var permissionDescription: String?

        // Custom init handles both camelCase and snake_case field names gracefully.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: RawKey.self)

            // Helper: try multiple key spellings, return first non-nil match.
            func str(_ keys: String...) -> String? {
                keys.lazy.compactMap { try? c.decodeIfPresent(String.self, forKey: RawKey($0)) }.first
            }
            func int_(_ keys: String...) -> Int? {
                keys.lazy.compactMap { try? c.decodeIfPresent(Int.self,    forKey: RawKey($0)) }.first
            }
            func bool_(_ keys: String...) -> Bool? {
                keys.lazy.compactMap { try? c.decodeIfPresent(Bool.self,   forKey: RawKey($0)) }.first
            }

            contactName           = str("contactName", "contact_name", "name")
            senderName            = str("senderName",  "sender_name")
            callerName            = str("callerName",  "caller_name")
            phoneNumber           = str("phoneNumber", "phone_number", "number")
            messageBody           = str("messageBody", "message_body", "message", "body", "text")
            appName               = str("appName",     "app_name",     "app")
            batteryLevel          = int_("batteryLevel",  "battery_level",  "level")
            isCharging            = bool_("isCharging",   "is_charging",    "charging")
            permissionName        = str("permissionName",        "permission_name")
            permissionDescription = str("permissionDescription", "permission_description")
        }

        private struct RawKey: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(_ s: String)           { stringValue = s }
            init?(stringValue: String)  { self.stringValue = stringValue }
            init?(intValue: Int)        { nil }
        }
    }
}

// MARK: - Android → Mac (response)

/// A response sent back by the Android app after executing a Mac-initiated command.
struct AndroidResponse: Decodable {
    let id: String              // echoes the AndroidCommand.id
    let type: String            // "response"
    let ok: Bool
    let status: String?         // "sent" | "calling" | "error" | "needs_clarification" | etc.
    let message: String?
    let payload: AndroidResponsePayload?
}

struct AndroidResponsePayload: Decodable {
    /// Contacts returned from a `find_contact` or disambiguation query.
    var contacts: [AndroidContact]?
    /// Capabilities the Android device supports (returned with `capabilities_report`).
    var capabilities: [String]?
    /// Battery level 0–100.
    var battery: Int?
    /// True when plugged in / on a charger.  Optional so older Android
    /// builds without this field still parse cleanly.
    var charging: Bool?
    /// Active network kind: "wifi" / "cellular" / "ethernet" / "none".
    var network: String?
    /// Human-readable device name.
    var deviceName: String?
    /// Notification text (for `read_notifications` responses).
    var notificationText: String?
    /// Notification count.
    var notificationCount: Int?
    /// App name associated with a notification.
    var notificationApp: String?

    // ── Audio-route diagnostics (from `speakerphone_on/off` responses) ──
    /// `AudioManager` reported route: "speaker" / "earpiece" / "bluetooth"
    /// / "wired_headset" / "unknown".  Mac displays in diagnostics row.
    var audioRoute: String?
    /// True if speakerphone is currently active.  Reports the *resulting*
    /// state after the requested action — not just success/failure.
    var speakerEnabled: Bool?
    /// True if a Bluetooth audio device is currently connected.
    var bluetoothActive: Bool?
    /// True if a wired headset is currently plugged in.
    var wiredHeadsetActive: Bool?
    /// Telecom in-call state: "ringing" / "active" / "held" / "idle".
    var inCallState: String?
}

// MARK: - Contact model

struct AndroidContact: Decodable, Identifiable {
    let id: String      // Android contact ID
    let name: String
    let phone: String?
}

// MARK: - Capability constants

/// String constants matching the capability identifiers reported by the Android
/// app in its `capabilities_report` event. Used for pre-flight capability checks.
enum AndroidCapability {
    static let callContact       = "call_contact"
    static let sendSMS           = "send_sms"
    static let sendWhatsApp      = "send_whatsapp"
    static let whatsAppVoiceCall = "whatsapp_voice_call"
    static let whatsAppVideoCall = "whatsapp_video_call"
    static let findContact       = "find_contact"
    static let ringPhone         = "ring_phone"
    static let phoneLocation     = "phone_location"
    static let navigation        = "navigation"
    static let readNotifications = "read_notifications"
    static let queryNotification = "query_notification"
    static let captureCamera     = "capture_camera"
    static let clipboardGet      = "clipboard.get"
    static let clipboardSet      = "clipboard.set"
    static let appOpen           = "app.open"
    static let mediaControl      = "media.control"

    // Phase-1 call control
    static let answerCall        = "answer_call"
    static let declineCall       = "decline_call"
    static let endCall           = "end_call"
    static let speakerphoneOn    = "speakerphone_on"
    static let speakerphoneOff   = "speakerphone_off"
}

// MARK: - Response status constants

/// Status strings returned by Android in `AndroidResponse.status`.
enum AndroidResponseStatus {
    static let completed          = "completed"
    static let needsClarification = "needs_clarification"
    static let failed             = "failed"
    static let permissionRequired = "permission_required"
    static let timeout            = "timeout"
    static let disconnected       = "disconnected"
    static let error              = "error"
    static let answered           = "answered"
    static let declined           = "declined"
    static let ended              = "ended"
    static let noActiveCall       = "no_active_call"
}
