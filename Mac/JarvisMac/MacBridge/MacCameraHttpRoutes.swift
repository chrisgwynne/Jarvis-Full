import Foundation
import Network

/// Handles /camera/health, /camera/snapshot, and /camera/stream.
///
/// MJPEG streaming:
///   handleStream(connection:) takes ownership of the NWConnection and returns
///   immediately. The connection is tracked in activeClients. A single streaming
///   Task writes JPEG frames to every active client at the configured FPS.
///   Disconnects are detected by both stateUpdateHandler (connection teardown) and
///   NWConnection.send() completion-handler errors (mid-write failure), both
///   routing to removeClient(id:) which is idempotent.
@MainActor
final class MacCameraHttpRoutes {

    weak var cameraService: MacCameraService?
    weak var frameStore:    MacCameraFrameStore?
    weak var diagnostics:   MacCameraDiagnostics?

    var keepCameraWarm = false
    var fpsInterval: TimeInterval = 0.2   // 5 fps default

    // MARK: - Active stream clients

    private struct StreamClient {
        let id:         UUID
        let connection: NWConnection
    }

    private var activeClients: [StreamClient] = []
    private var streamTask: Task<Void, Never>?

    var activeClientCount: Int { activeClients.count }

    // MARK: - GET /camera/health

    func handleHealth() -> (statusCode: Int, body: Data, contentType: String) {
        diagnostics?.log(.healthRequest)
        let payload: [String: Any] = [
            "ok":               true,
            "cameraAvailable":  true,
            "cameraPermission": diagnostics?.permission ?? "notDetermined",
            "streaming":        !activeClients.isEmpty,
            "activeClients":    activeClients.count,
            "timestamp":        Int(Date().timeIntervalSince1970 * 1000)
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload,
                                                options: .sortedKeys)) ?? Data()
        return (200, data, "application/json")
    }

    // MARK: - GET /camera/snapshot

    func handleSnapshot() async -> (statusCode: Int, body: Data, contentType: String) {
        diagnostics?.log(.snapshotRequest)

        if cameraService?.isRunning == false {
            cameraService?.start()
        }

        // Wait up to 2 s for the first frame (50 ms polls).
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if let jpeg = frameStore?.latestJPEG {
                return (200, jpeg, "image/jpeg")
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        let err = #"{"error":"Camera not ready","code":"CAMERA_TIMEOUT"}"#
        return (503, Data(err.utf8), "application/json")
    }

    // MARK: - GET /camera/stream  (takes permanent ownership of NWConnection)

    func handleStream(connection: NWConnection) async {
        let clientID = UUID()

        // Register disconnect handler BEFORE sending headers so we never miss it.
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor [weak self] in
                    self?.removeClient(id: clientID)
                }
            default: break
            }
        }

        // Send MJPEG response headers (no Content-Length — infinite stream).
        let headerStr = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: multipart/x-mixed-replace; boundary=frame\r\n"
            + "Cache-Control: no-cache, no-store, must-revalidate\r\n"
            + "Pragma: no-cache\r\n"
            + "Connection: keep-alive\r\n"
            + "\r\n"
        let headerSent = await rawSend(Data(headerStr.utf8), to: connection)
        guard headerSent else {
            diagnostics?.log(.clientDisconnected)
            connection.cancel()
            return
        }

        // Register client.
        activeClients.append(StreamClient(id: clientID, connection: connection))
        diagnostics?.log(.clientConnected)
        diagnostics?.log(.streamStarted)

        // Ensure camera is running.
        if cameraService?.isRunning == false {
            cameraService?.start()
        }

        // Start (or re-arm) the shared streaming loop.
        if streamTask == nil || streamTask!.isCancelled {
            startStreamingLoop()
        }
    }

    // MARK: - Streaming loop (one Task for all clients, sequential writes)

    private func startStreamingLoop() {
        streamTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard !activeClients.isEmpty else { break }

                if let jpeg = frameStore?.latestJPEG {
                    await sendFrameToAll(jpeg)
                }

                let nanos = UInt64(fpsInterval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
            }

            streamTask = nil
            diagnostics?.log(.streamStopped)

            if !keepCameraWarm {
                cameraService?.stop()
            }
        }
    }

    private func sendFrameToAll(_ jpeg: Data) async {
        var frameData = Data()
        let boundary = "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n"
        frameData.append(Data(boundary.utf8))
        frameData.append(jpeg)
        frameData.append(Data("\r\n".utf8))

        var failed: [UUID] = []
        for client in activeClients {
            let ok = await rawSend(frameData, to: client.connection)
            if !ok { failed.append(client.id) }
        }
        for id in failed { removeClient(id: id) }
    }

    // MARK: - Client management

    private func removeClient(id: UUID) {
        guard let idx = activeClients.firstIndex(where: { $0.id == id }) else { return }
        activeClients[idx].connection.cancel()
        activeClients.remove(at: idx)
        diagnostics?.log(.clientDisconnected)
        if activeClients.isEmpty {
            streamTask?.cancel()
        }
    }

    // MARK: - Cleanup (called when server is stopped)

    func stopAll() {
        streamTask?.cancel()
        streamTask = nil
        for client in activeClients { client.connection.cancel() }
        activeClients.removeAll()
        diagnostics?.log(.serverDisabled)
        cameraService?.stop()
    }

    // MARK: - NWConnection write (async bridge)

    private func rawSend(_ data: Data, to connection: NWConnection) async -> Bool {
        await withCheckedContinuation { cont in
            connection.send(content: data, completion: .contentProcessed { error in
                cont.resume(returning: error == nil)
            })
        }
    }
}
