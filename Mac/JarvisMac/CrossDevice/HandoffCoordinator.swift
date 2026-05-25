import AppKit
import Observation
import SwiftUI

/// Handles incoming cross-device handoff payloads from the Brain Gateway.
/// Receives content routed from Android (URLs, text, conversation summaries, files)
/// and surfaces it via clipboard and/or the `pendingHandoffText` overlay property.
@Observable @MainActor final class HandoffCoordinator {

    static let shared = HandoffCoordinator()
    private init() {}

    // MARK: - Observable state

    /// Set when a text or conversation handoff arrives. Cleared by `clearPendingHandoff()`.
    var pendingHandoffText: String? = nil

    // MARK: - Receive

    /// Handles an incoming handoff key/value pair from the Brain Gateway or daemon.
    /// - "url": opens via NSWorkspace
    /// - "text": writes to NSPasteboard AND surfaces in overlay
    /// - "conversation": surfaces in overlay only (no clipboard)
    /// - "file": opens the file path via NSWorkspace
    /// - "clipboard": writes to NSPasteboard (legacy alias for "text")
    /// - any other key: writes value to NSPasteboard as a fallback
    func receive(key: String, value: String) {
        switch key.lowercased() {
        case "url":
            if let url = URL(string: value) {
                NSWorkspace.shared.open(url)
            }
        case "text":
            // Write to clipboard AND surface in overlay
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            pendingHandoffText = value
        case "conversation":
            // Surface in overlay only — don't put conversation summaries on clipboard
            pendingHandoffText = value
        case "file":
            // Open the file path if it exists
            let fileURL = URL(fileURLWithPath: value)
            NSWorkspace.shared.open(fileURL)
        case "clipboard":
            writeToClipboard(value)
        default:
            // Fallback: put any unrecognised key's value on the clipboard
            writeToClipboard(value)
        }
    }

    /// Writes text from another device's clipboard.sync event directly to the local clipboard.
    func receiveClipboard(_ text: String) {
        writeToClipboard(text)
    }

    // MARK: - Send to Android

    /// Sends a plain-text handoff to Android via the daemon bridge.
    func sendToAndroid(text: String, via bridge: DaemonAppBridge) {
        bridge.sendHandoffRequest(key: "text", value: text, targetDeviceId: nil)
    }

    /// Sends a plain-text handoff to Android via an optional gateway (stub for compatibility).
    func sendToAndroid(text: String, via gateway: Any? = nil) {
        // Implementation delegates to the gateway client — wired at call site.
    }

    /// Reads the current clipboard string and sends it to Android as a clipboard handoff.
    func sendClipboardToAndroid(via bridge: DaemonAppBridge) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        bridge.sendHandoffRequest(key: "clipboard", value: text, targetDeviceId: nil)
    }

    /// Reads the current clipboard string and sends it to Android (stub for compatibility).
    func sendClipboardToAndroid(via gateway: Any? = nil) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        sendToAndroid(text: text, via: gateway)
    }

    // MARK: - Overlay control

    /// Clear the pending handoff overlay.
    func clearPendingHandoff() {
        pendingHandoffText = nil
    }

    // MARK: - Private helpers

    private func writeToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
