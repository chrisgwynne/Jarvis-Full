import Foundation

/// Routes parsed HTTP requests to the three Mac Brain endpoints.
@MainActor
final class BrainHTTPHandler {

    struct HTTPResponse {
        let statusCode: Int
        let body: Data
    }

    private let contextEngine: BrainContextEngine
    private let interactionStore: BrainInteractionStore
    private let correctionStore: BrainCorrectionStore
    private let memoryCandidateStore: BrainMemoryCandidateStore
    private let diagnostics: GatewayDiagnostics
    private let startedAt = Date()

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return e
    }()
    private let decoder = JSONDecoder()

    init(contextEngine: BrainContextEngine,
         interactionStore: BrainInteractionStore,
         correctionStore: BrainCorrectionStore,
         memoryCandidateStore: BrainMemoryCandidateStore,
         diagnostics: GatewayDiagnostics) {
        self.contextEngine = contextEngine
        self.interactionStore = interactionStore
        self.correctionStore = correctionStore
        self.memoryCandidateStore = memoryCandidateStore
        self.diagnostics = diagnostics
    }

    // MARK: - Dispatch

    func handle(method: String, path: String, headers: [String: String], body: Data) async -> HTTPResponse {
        switch (method, path) {
        case ("GET", "/brain/health"):
            return handleHealth()
        case ("POST", "/brain/context"):
            return await handleContext(body: body)
        case ("POST", "/brain/interactions"):
            return await handleInteractions(body: body)
        default:
            return errorResponse(status: 404, message: "Not found", requestId: nil)
        }
    }

    // MARK: - GET /brain/health

    private func handleHealth() -> HTTPResponse {
        let resp = BrainHealthResponse(
            status: diagnostics.lastError == nil ? "ok" : "degraded",
            version: "1.0",
            uptimeSeconds: Date().timeIntervalSince(startedAt),
            requestsServed: diagnostics.requestsServed,
            lastContextAt: diagnostics.lastContextAt.map(isoDate)
        )
        return json(resp, status: 200)
    }

    // MARK: - POST /brain/context

    private func handleContext(body: Data) async -> HTTPResponse {
        guard !body.isEmpty else {
            return errorResponse(status: 400, message: "Body required", requestId: nil)
        }
        guard let req = try? decoder.decode(BrainContextRequest.self, from: body) else {
            return errorResponse(status: 400, message: "Invalid JSON", requestId: nil)
        }

        // Race context assembly against a 1500 ms global wall-clock guard
        let blocks: [BrainContextBlock] = await withTaskGroup(of: [BrainContextBlock].self) { group in
            group.addTask {
                await self.contextEngine.buildContext(
                    query: req.query,
                    categories: req.categories,
                    maxItems: req.maxItems ?? 10
                )
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                return []
            }
            let first = await group.next() ?? []
            group.cancelAll()
            return first
        }

        let resp = BrainContextResponse(
            requestId: req.resolvedMeta.requestId,
            generatedAt: isoDate(Date()),
            blocks: blocks,
            truncated: false
        )
        return json(resp, status: 200)
    }

    // MARK: - POST /brain/interactions

    private func handleInteractions(body: Data) async -> HTTPResponse {
        guard !body.isEmpty else {
            return errorResponse(status: 400, message: "Body required", requestId: nil)
        }
        guard let req = try? decoder.decode(BrainInteractionsRequest.self, from: body) else {
            return errorResponse(status: 400, message: "Invalid JSON", requestId: nil)
        }

        var accepted = 0, rejected = 0
        var errors: [String] = []

        for event in req.events {
            do {
                try await route(event)
                accepted += 1
            } catch {
                rejected += 1
                errors.append("\(event.eventId): \(error.localizedDescription)")
            }
        }

        let resp = BrainInteractionsResponse(
            requestId: req.resolvedMeta.requestId,
            accepted: accepted,
            rejected: rejected,
            errors: errors
        )
        return json(resp, status: 200)
    }

    private func route(_ event: BrainInteractionEvent) async throws {
        switch event.eventType {
        case "MEMORY_CANDIDATE":
            try await memoryCandidateStore.save(event)
        case "ALIAS_CORRECTION", "HOME_ASSISTANT_CORRECTION":
            try await correctionStore.save(event)
        default:
            try await interactionStore.save(event)
        }
    }

    // MARK: - Helpers

    private func json<T: Encodable>(_ value: T, status: Int) -> HTTPResponse {
        HTTPResponse(statusCode: status, body: (try? encoder.encode(value)) ?? Data())
    }

    private func errorResponse(status: Int, message: String, requestId: String?) -> HTTPResponse {
        json(BrainErrorResponse(error: message, requestId: requestId), status: status)
    }

    private func isoDate(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
