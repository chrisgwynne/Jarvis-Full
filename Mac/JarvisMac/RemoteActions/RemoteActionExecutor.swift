import AppKit
import Foundation
import OSLog

/// Receives remote.action.request from Android via daemon and executes Mac actions.
@MainActor
final class RemoteActionExecutor {
    static let shared = RemoteActionExecutor()

    private let logger = Logger(subsystem: "com.jarvis.jarvisapp", category: "remote-action")

    // MARK: - Wiring (called from JarvisController/AppDelegate)

    func wire(to bridge: DaemonAppBridge) {
        bridge.onRemoteActionRequest = { [weak self] requestId, routeId, sourceDeviceId, action, parameters, userVisibleText, requiresConfirmation in
            Task { @MainActor [weak self] in
                await self?.handle(
                    requestId: requestId,
                    routeId: routeId,
                    sourceDeviceId: sourceDeviceId,
                    action: action,
                    parameters: parameters,
                    userVisibleText: userVisibleText,
                    requiresConfirmation: requiresConfirmation
                )
            }
        }

        bridge.onFileTransferCreated = { [weak self] transferId, filename, mimeType, sizeBytes, openOnMac, suggestedAction, userVisibleName in
            Task { @MainActor [weak self] in
                await self?.handleFileTransfer(
                    transferId: transferId, filename: filename, mimeType: mimeType,
                    sizeBytes: sizeBytes, openOnMac: openOnMac,
                    suggestedAction: suggestedAction, userVisibleName: userVisibleName
                )
            }
        }
    }

    // MARK: - Action dispatch

    private func handle(
        requestId: String,
        routeId: String,
        sourceDeviceId: String,
        action: String,
        parameters: [String: Any],
        userVisibleText: String,
        requiresConfirmation: Bool
    ) async {
        logger.info("remote-action: executing action=\(action, privacy: .public) requestId=\(requestId, privacy: .public)")

        let result: RemoteActionResult
        switch action {
        case "open_app":
            let appName = parameters["appName"] as? String ?? ""
            result = await MacActionHandler.openApp(appName: appName)
        case "create_note":
            let title = parameters["title"] as? String
            let body = parameters["body"] as? String
            result = await MacActionHandler.createNote(title: title, body: body)
        case "show_camera":
            result = MacActionHandler.showCamera()
        case "open_jarvis":
            result = MacActionHandler.openJarvis()
        default:
            result = RemoteActionResult(
                success: false,
                spokenSummary: "That Mac action is not supported yet.",
                errorCode: "unsupported_action"
            )
        }

        logger.info("remote-action: result action=\(action, privacy: .public) success=\(result.success) summary=\(result.spokenSummary, privacy: .public)")

        DaemonAppBridge.shared.sendRemoteActionResult(
            requestId: requestId,
            routeId: routeId,
            targetDeviceId: sourceDeviceId,
            success: result.success,
            spokenSummary: result.spokenSummary,
            errorCode: result.errorCode,
            errorMessage: result.errorMessage
        )
    }

    // MARK: - File transfer receipt

    private func handleFileTransfer(
        transferId: String,
        filename: String,
        mimeType: String,
        sizeBytes: Int,
        openOnMac: Bool,
        suggestedAction: String,
        userVisibleName: String
    ) async {
        logger.info("remote-action: file.transfer.created transferId=\(transferId, privacy: .public) filename=\(filename, privacy: .public)")

        // Download from daemon
        guard let token = Keychain.get(KeychainAccount.gatewayToken) else {
            logger.warning("remote-action: no auth token — cannot download file")
            return
        }
        let url = URL(string: "http://127.0.0.1:8765/v1/files/\(transferId)")!
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.addValue("mac", forHTTPHeaderField: "X-Platform")
        req.addValue("mac", forHTTPHeaderField: "X-Device-Id")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                logger.warning("remote-action: download failed for transferId=\(transferId, privacy: .public)")
                return
            }

            // Save to ~/Downloads/Jarvis Transfers/
            let transfersDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads/Jarvis Transfers", isDirectory: true)
            try FileManager.default.createDirectory(at: transfersDir, withIntermediateDirectories: true)
            let destURL = transfersDir.appendingPathComponent(filename)
            try data.write(to: destURL, options: .atomic)

            logger.info("remote-action: file saved to Jarvis Transfers/\(filename, privacy: .public)")

            // Delete from daemon after successful pickup
            var delReq = URLRequest(url: url)
            delReq.httpMethod = "DELETE"
            delReq.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            _ = try? await URLSession.shared.data(for: delReq)

            // Open if requested
            if openOnMac {
                NSWorkspace.shared.open(destURL)
            }

            // Show notification
            showFileReceivedNotification(filename: filename, path: destURL)

        } catch {
            logger.error("remote-action: file download error: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func showFileReceivedNotification(filename: String, path: URL) {
        let notification = NSUserNotification()
        notification.title = "File received from Android"
        notification.informativeText = filename
        notification.actionButtonTitle = "Show"
        NSUserNotificationCenter.default.deliver(notification)
    }
}

// MARK: - RemoteActionResult

struct RemoteActionResult {
    let success: Bool
    let spokenSummary: String
    let errorCode: String?
    let errorMessage: String?

    init(success: Bool, spokenSummary: String, errorCode: String? = nil, errorMessage: String? = nil) {
        self.success = success
        self.spokenSummary = spokenSummary
        self.errorCode = errorCode
        self.errorMessage = errorMessage
    }
}
