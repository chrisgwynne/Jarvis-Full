import Foundation
import AppKit

// MARK: - HandoffCoordinator

@MainActor final class HandoffCoordinator {
    static let shared = HandoffCoordinator()

    private init() {}

    // MARK: - Receive from other devices

    /// Handles an incoming handoff.request from another device.
    /// - "url": opens via NSWorkspace
    /// - "text" / "clipboard": writes to NSPasteboard.general
    /// - any other key: writes value to NSPasteboard.general as a fallback
    func receive(key: String, value: String) {
        switch key.lowercased() {
        case "url":
            if let url = URL(string: value) {
                NSWorkspace.shared.open(url)
            }
        case "text", "clipboard":
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

    /// Sends a plain-text handoff to Android (or broadcasts if no specific device).
    func sendToAndroid(text: String, via bridge: DaemonAppBridge) {
        bridge.sendHandoffRequest(key: "text", value: text, targetDeviceId: nil)
    }

    /// Reads the current clipboard string and sends it to Android as a clipboard handoff.
    func sendClipboardToAndroid(via bridge: DaemonAppBridge) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        bridge.sendHandoffRequest(key: "clipboard", value: text, targetDeviceId: nil)
    }

    // MARK: - Private helpers

    private func writeToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
