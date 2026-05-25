import Foundation

// MARK: - RemoteExecutionCoordinator

/// Mac delegates specific execution tasks to a Windows sidecar (browser navigation,
/// click, clipboard, OCR) via the V2 bridge. Tracks pending requests with per-request
/// timeouts and a bounded queue (max 10 active).
@MainActor
final class RemoteExecutionCoordinator {

    static let shared = RemoteExecutionCoordinator()

    // MARK: - Config

    private static let maxPending = 10
    private static let defaultTimeoutSeconds: Double = 5.0

    // MARK: - State

    private var pending: [String: PendingExecution] = [:]  // requestId → pending

    // Wired by JarvisBrainDaemon routing to actually send the request over WebSocket.
    // (MacBridgeProtocolV2 SSE is deprecated — daemon routing handles this.)
    var onSendRequest: ((ExecutionRequest, String) -> Void)?   // request, targetDeviceId
    // Called when Windows reports back a result.
    var onResultReceived: ((ExecutionResult) -> Void)?

    // MARK: - Submit

    /// Submits an execution request to `targetDeviceId` and waits for the result.
    /// Returns nil on timeout or queue-full.
    func submit(_ request: ExecutionRequest, to targetDeviceId: String) async -> ExecutionResult? {
        guard pending.count < Self.maxPending else {
            return ExecutionResult(
                requestId: request.id,
                success: false,
                output: nil,
                error: "Request queue full",
                completedAt: Date()
            )
        }

        let continuation = await withCheckedContinuation { (cont: CheckedContinuation<ExecutionResult?, Never>) in
            let timeout = request.timeoutSeconds > 0 ? request.timeoutSeconds : Self.defaultTimeoutSeconds
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if !Task.isCancelled {
                    await MainActor.run {
                        if let pend = self.pending.removeValue(forKey: request.id) {
                            pend.continuation.resume(returning: ExecutionResult(
                                requestId: request.id,
                                success: false,
                                output: nil,
                                error: "Timeout after \(Int(timeout))s",
                                completedAt: Date()
                            ))
                        }
                    }
                }
            }
            pending[request.id] = PendingExecution(request: request, continuation: cont, timeoutTask: timeoutTask)
            onSendRequest?(request, targetDeviceId)
        }
        return continuation
    }

    // MARK: - Result delivery (called by MacBridgeV2Handler on incoming result)

    func deliver(_ result: ExecutionResult) {
        guard let pend = pending.removeValue(forKey: result.requestId) else { return }
        pend.timeoutTask.cancel()
        pend.continuation.resume(returning: result)
        onResultReceived?(result)
    }

    // MARK: - Cancel all

    func cancelAll() {
        for (_, pend) in pending {
            pend.timeoutTask.cancel()
            pend.continuation.resume(returning: ExecutionResult(
                requestId: pend.request.id,
                success: false,
                output: nil,
                error: "Cancelled",
                completedAt: Date()
            ))
        }
        pending.removeAll()
    }

    var pendingCount: Int { pending.count }

    // MARK: - Private

    private struct PendingExecution {
        let request: ExecutionRequest
        let continuation: CheckedContinuation<ExecutionResult?, Never>
        let timeoutTask: Task<Void, Never>
    }
}
