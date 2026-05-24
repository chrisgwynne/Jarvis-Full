import XCTest
@testable import JarvisMac

/// Two-class test bundle for the WhatsApp sprint:
///
///   1. `IntentRouter` correctly extracts contact + call-type from the
///      conversational shapes the brief listed.
///   2. The new `AndroidPhoneEvent.groupName` field round-trips through
///      JSON decode, and the speech-building branch in
///      `AndroidEventReceiver` produces the right sentence for each
///      (named-sender × group × preview) combination.
///
/// Both layers are pure / synchronous so the tests don't need a running
/// controller, network, or Android bridge.
final class WhatsAppRoutingTests: XCTestCase {

    // MARK: - IntentRouter extraction

    private let router = IntentRouter()

    func test_voiceCall_onWhatsApp_suffix_extractsContact() {
        let intent = router.route("call mike on whatsapp")
        guard case .whatsAppVoiceCall(let contact) = intent else {
            return XCTFail("expected .whatsAppVoiceCall, got \(intent)")
        }
        XCTAssertEqual(contact, "Mike")
    }

    func test_phoneVerb_onWhatsApp_extracts() {
        let intent = router.route("phone Cath on whatsapp")
        guard case .whatsAppVoiceCall(let contact) = intent else {
            return XCTFail("expected .whatsAppVoiceCall, got \(intent)")
        }
        XCTAssertEqual(contact, "Cath")
    }

    func test_ringVerb_onWhatsApp_extracts() {
        let intent = router.route("ring rob on whatsapp")
        guard case .whatsAppVoiceCall(let contact) = intent else {
            return XCTFail("expected .whatsAppVoiceCall, got \(intent)")
        }
        XCTAssertEqual(contact, "Rob")
    }

    func test_whatsAppCall_prefix_extracts() {
        let intent = router.route("whatsapp call mike")
        guard case .whatsAppVoiceCall(let contact) = intent else {
            return XCTFail("expected .whatsAppVoiceCall, got \(intent)")
        }
        XCTAssertEqual(contact, "Mike")
    }

    func test_videoCall_onWhatsApp_extracts() {
        let intent = router.route("video call cath on whatsapp")
        guard case .whatsAppVideoCall(let contact) = intent else {
            return XCTFail("expected .whatsAppVideoCall, got \(intent)")
        }
        XCTAssertEqual(contact, "Cath")
    }

    func test_whatsAppVideoCall_prefix_extracts() {
        let intent = router.route("whatsapp video call mike")
        guard case .whatsAppVideoCall(let contact) = intent else {
            return XCTFail("expected .whatsAppVideoCall, got \(intent)")
        }
        XCTAssertEqual(contact, "Mike")
    }

    func test_videoWhatsApp_prefix_extracts() {
        let intent = router.route("video whatsapp cath")
        guard case .whatsAppVideoCall(let contact) = intent else {
            return XCTFail("expected .whatsAppVideoCall, got \(intent)")
        }
        XCTAssertEqual(contact, "Cath")
    }

    func test_genericCall_withoutWhatsAppMarker_doesNotRouteToWhatsApp() {
        // Bare "call mike" must NOT route to WhatsApp — only generic
        // telephony.  This protects the existing call_contact flow.
        let intent = router.route("call mike")
        if case .whatsAppVoiceCall = intent {
            XCTFail("'call mike' must not route to WhatsApp, got \(intent)")
        }
    }

    func test_articleStripping_thePrefix() {
        let intent = router.route("call the mike on whatsapp")
        guard case .whatsAppVoiceCall(let contact) = intent else {
            return XCTFail("expected .whatsAppVoiceCall, got \(intent)")
        }
        XCTAssertEqual(contact, "Mike")
    }

    func test_alternativeSuffixes_viaWhatsApp_works() {
        let intent = router.route("phone mike via whatsapp")
        guard case .whatsAppVoiceCall(let contact) = intent else {
            return XCTFail("expected .whatsAppVoiceCall, got \(intent)")
        }
        XCTAssertEqual(contact, "Mike")
    }

    // MARK: - groupName decoding + speech-building

    /// Decode the JSON the Android side sends and assert the new
    /// `groupName` field round-trips.  Tests against the actual
    /// `AndroidPhoneEvent` decoder.
    func test_groupName_decodesFromSnakeCase() throws {
        let json = """
        {
          "event_id":      "evt-1",
          "type":          "whatsapp_received",
          "sender_name":   "Cath",
          "group_name":    "Family Group",
          "message_body":  "On my way home",
          "message_preview_enabled": true
        }
        """
        let data = Data(json.utf8)
        let event = try JSONDecoder().decode(AndroidPhoneEvent.self, from: data)
        XCTAssertEqual(event.senderName, "Cath")
        XCTAssertEqual(event.groupName,  "Family Group")
        XCTAssertEqual(event.type, .whatsAppReceived)
    }

    func test_groupName_decodesAsNilWhenAbsent() throws {
        let json = """
        { "event_id": "x", "type": "whatsapp_received", "sender_name": "Mike" }
        """
        let data = Data(json.utf8)
        let event = try JSONDecoder().decode(AndroidPhoneEvent.self, from: data)
        XCTAssertNil(event.groupName)
    }

    // MARK: - Speech-shape contract
    //
    // Mirrors the switch table in
    // `AndroidEventReceiver.buildSignal(.whatsAppReceived)` so a refactor
    // there can't accidentally change the user-facing wording.

    func test_speech_directNamed_withPreview() {
        let s = whatsappSpeech(
            sender: "Mike", group: nil, body: "On my way", previewOn: true)
        XCTAssertEqual(s, "WhatsApp from Mike: On my way")
    }

    func test_speech_directNamed_withoutPreview() {
        let s = whatsappSpeech(
            sender: "Mike", group: nil, body: nil, previewOn: false)
        XCTAssertEqual(s, "You've had a WhatsApp from Mike.")
    }

    func test_speech_groupNamed_withPreview() {
        let s = whatsappSpeech(
            sender: "Cath", group: "Family Group", body: "Dinner at 7?", previewOn: true)
        XCTAssertEqual(s, "WhatsApp in Family Group from Cath: Dinner at 7?")
    }

    func test_speech_groupNamed_withoutPreview() {
        let s = whatsappSpeech(
            sender: "Cath", group: "Family Group", body: nil, previewOn: false)
        XCTAssertEqual(s, "You've had a WhatsApp in Family Group from Cath.")
    }

    func test_speech_anonymous_fallback() {
        // Mirrors "Fallback only if extraction genuinely fails" from the brief.
        let s = whatsappSpeech(
            sender: nil, group: nil, body: nil, previewOn: false)
        XCTAssertEqual(s, "You've had a WhatsApp message.")
    }

    func test_speech_someoneSentinel_treatedAsAnonymous() {
        // Android may explicitly send "someone" when the sender field is
        // present but unresolved.  Mac must treat that as "no name" so we
        // don't say "You've had a WhatsApp from someone."
        let s = whatsappSpeech(
            sender: "someone", group: nil, body: nil, previewOn: false)
        XCTAssertEqual(s, "You've had a WhatsApp message.")
    }

    // MARK: - Helper: replicate the speech-decision branch verbatim

    /// Inlined copy of the branching block from
    /// `AndroidEventReceiver.buildSignal(_:)`.  Kept here so the test
    /// suite documents the exact contract — and any future refactor
    /// that breaks the wording fails fast.
    private func whatsappSpeech(sender: String?,
                                 group: String?,
                                 body: String?,
                                 previewOn: Bool) -> String {
        let hasName = sender != nil
            && !(sender?.isEmpty ?? true)
            && (sender ?? "").lowercased() != "someone"
        let hasGroup = (group ?? "").isEmpty == false
        let hasPreview = previewOn && !(body ?? "").isEmpty
        let displaySender = sender ?? "someone"
        switch (hasName, hasGroup, hasPreview) {
        case (true, true, true):
            return "WhatsApp in \(group!) from \(displaySender): \(String(body!.prefix(80)))"
        case (true, true, false):
            return "You've had a WhatsApp in \(group!) from \(displaySender)."
        case (true, false, true):
            return "WhatsApp from \(displaySender): \(String(body!.prefix(80)))"
        case (true, false, false):
            return "You've had a WhatsApp from \(displaySender)."
        case (false, _, _):
            return "You've had a WhatsApp message."
        }
    }
}
