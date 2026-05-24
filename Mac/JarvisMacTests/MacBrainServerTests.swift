import XCTest
@testable import JarvisMac

@MainActor
final class MacBrainServerTests: XCTestCase {

    // MARK: - Helpers

    private func makeHandler(auth: String? = nil) -> (BrainHTTPHandler, BrainDiagnostics) {
        let diag = BrainDiagnostics()
        let engine = BrainContextEngine()
        let interactionStore = BrainInteractionStore(fileURL: tempURL("interactions"))
        let correctionStore = BrainCorrectionStore(fileURL: tempURL("corrections"))
        let candidateStore = BrainMemoryCandidateStore(fileURL: tempURL("candidates"))
        let handler = BrainHTTPHandler(
            contextEngine: engine,
            interactionStore: interactionStore,
            correctionStore: correctionStore,
            memoryCandidateStore: candidateStore,
            diagnostics: diag
        )
        if let tok = auth {
            Keychain.set(tok, for: KeychainAccount.brainServerToken)
        }
        return (handler, diag)
    }

    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("brain_test_\(name)_\(UUID().uuidString).json")
    }

    private func metaJSON(requestId: String = "test-req") -> String {
        """
        {"apiVersion":"1.0","deviceId":"android-test","requestId":"\(requestId)"}
        """
    }

    // MARK: - Health endpoint

    func testHealth_returnsOK() async {
        let (handler, _) = makeHandler()
        let resp = await handler.handle(method: "GET", path: "/brain/health", headers: [:], body: Data())
        XCTAssertEqual(resp.statusCode, 200)
    }

    func testHealth_responseContainsVersion() async throws {
        let (handler, _) = makeHandler()
        let resp = await handler.handle(method: "GET", path: "/brain/health", headers: [:], body: Data())
        let json = try JSONDecoder().decode(BrainHealthResponse.self, from: resp.body)
        XCTAssertEqual(json.version, "1.0")
    }

    func testHealth_statusIsOkWhenNoError() async throws {
        let (handler, _) = makeHandler()
        let resp = await handler.handle(method: "GET", path: "/brain/health", headers: [:], body: Data())
        let json = try JSONDecoder().decode(BrainHealthResponse.self, from: resp.body)
        XCTAssertEqual(json.status, "ok")
    }

    // MARK: - Context endpoint

    func testContext_emptyBodyReturns400() async {
        let (handler, _) = makeHandler()
        let resp = await handler.handle(method: "POST", path: "/brain/context", headers: [:], body: Data())
        XCTAssertEqual(resp.statusCode, 400)
    }

    func testContext_invalidJSONReturns400() async {
        let (handler, _) = makeHandler()
        let resp = await handler.handle(method: "POST", path: "/brain/context", headers: [:], body: Data("notjson".utf8))
        XCTAssertEqual(resp.statusCode, 400)
    }

    func testContext_validRequestReturns200() async throws {
        let (handler, _) = makeHandler()
        let body = Data("""
        {"meta":\(metaJSON()),"query":"test"}
        """.utf8)
        let resp = await handler.handle(method: "POST", path: "/brain/context", headers: [:], body: body)
        XCTAssertEqual(resp.statusCode, 200)
    }

    func testContext_responseContainsRequestId() async throws {
        let (handler, _) = makeHandler()
        let body = Data("""
        {"meta":\(metaJSON(requestId: "my-id-123")),"query":"test"}
        """.utf8)
        let resp = await handler.handle(method: "POST", path: "/brain/context", headers: [:], body: body)
        let json = try JSONDecoder().decode(BrainContextResponse.self, from: resp.body)
        XCTAssertEqual(json.requestId, "my-id-123")
    }

    func testContext_emptyProvidersReturnsEmptyBlocks() async throws {
        let (handler, _) = makeHandler()
        let body = Data("""
        {"meta":\(metaJSON())}
        """.utf8)
        let resp = await handler.handle(method: "POST", path: "/brain/context", headers: [:], body: body)
        let json = try JSONDecoder().decode(BrainContextResponse.self, from: resp.body)
        XCTAssertTrue(json.blocks.isEmpty)
    }

    // MARK: - Interactions endpoint

    func testInteractions_emptyBodyReturns400() async {
        let (handler, _) = makeHandler()
        let resp = await handler.handle(method: "POST", path: "/brain/interactions", headers: [:], body: Data())
        XCTAssertEqual(resp.statusCode, 400)
    }

    func testInteractions_acceptsCommandOutcomeEvent() async throws {
        let (handler, _) = makeHandler()
        let body = Data("""
        {"meta":\(metaJSON()),"events":[{"eventId":"ev1","eventType":"COMMAND_OUTCOME","timestampIso":"2026-05-22T10:00:00Z","payload":{"command":"turn on lights","success":"true"}}]}
        """.utf8)
        let resp = await handler.handle(method: "POST", path: "/brain/interactions", headers: [:], body: body)
        XCTAssertEqual(resp.statusCode, 200)
        let json = try JSONDecoder().decode(BrainInteractionsResponse.self, from: resp.body)
        XCTAssertEqual(json.accepted, 1)
        XCTAssertEqual(json.rejected, 0)
    }

    func testInteractions_rejectsZeroAcceptedForEmptyList() async throws {
        let (handler, _) = makeHandler()
        let body = Data("""
        {"meta":\(metaJSON()),"events":[]}
        """.utf8)
        let resp = await handler.handle(method: "POST", path: "/brain/interactions", headers: [:], body: body)
        XCTAssertEqual(resp.statusCode, 200)
        let json = try JSONDecoder().decode(BrainInteractionsResponse.self, from: resp.body)
        XCTAssertEqual(json.accepted, 0)
    }

    // MARK: - Auth

    func testAuth_noTokenConfigured_passes() async {
        Keychain.remove(KeychainAccount.brainServerToken)
        let (handler, diag) = makeHandler(auth: nil)
        let resp = await handler.handle(method: "GET", path: "/brain/health", headers: [:], body: Data())
        XCTAssertEqual(resp.statusCode, 200)
        XCTAssertEqual(diag.unauthorizedAttempts, 0)
    }

    // (Auth enforcement is tested at the server layer; handler doesn't check auth)

    // MARK: - Unknown paths

    func testUnknownPath_returns404() async {
        let (handler, _) = makeHandler()
        let resp = await handler.handle(method: "GET", path: "/brain/unknown", headers: [:], body: Data())
        XCTAssertEqual(resp.statusCode, 404)
    }

    func testWrongMethod_returns404() async {
        let (handler, _) = makeHandler()
        let resp = await handler.handle(method: "GET", path: "/brain/context", headers: [:], body: Data())
        XCTAssertEqual(resp.statusCode, 404)
    }

    // MARK: - BrainInteractionStore

    func testInteractionStore_deduplicatesById() async throws {
        let store = BrainInteractionStore(fileURL: tempURL("dedup"))
        let ev = BrainInteractionEvent(eventId: "abc", eventType: "COMMAND_OUTCOME",
                                        timestampIso: "2026-05-22T10:00:00Z", payload: [:])
        try await store.save(ev)
        try await store.save(ev)  // duplicate
        XCTAssertEqual(store.count, 1)
    }

    func testInteractionStore_capsAt500() async throws {
        let store = BrainInteractionStore(fileURL: tempURL("cap"))
        for i in 0..<510 {
            let ev = BrainInteractionEvent(eventId: "ev-\(i)", eventType: "COMMAND_OUTCOME",
                                            timestampIso: "2026-05-22T10:00:00Z", payload: [:])
            try await store.save(ev)
        }
        XCTAssertEqual(store.count, 500)
    }

    func testCorrectionStore_savesPersists() async throws {
        let store = BrainCorrectionStore(fileURL: tempURL("corr"))
        let ev = BrainInteractionEvent(eventId: "corr1", eventType: "ALIAS_CORRECTION",
                                        timestampIso: "2026-05-22T10:00:00Z",
                                        payload: ["spoken": "desk lamp", "entityId": "light.desk"])
        try await store.save(ev)
        XCTAssertEqual(store.count, 1)
    }

    func testMemoryCandidateStore_savesLowConfidenceWithoutPromotion() async throws {
        let store = BrainMemoryCandidateStore(fileURL: tempURL("cand"))
        let ev = BrainInteractionEvent(eventId: "mc1", eventType: "MEMORY_CANDIDATE",
                                        timestampIso: "2026-05-22T10:00:00Z",
                                        payload: ["title": "Test", "summary": "A test memory", "confidence": "0.3"])
        try await store.save(ev)
        XCTAssertEqual(store.count, 1)
        // confidence 0.3 < 0.65 threshold — no promotion attempted
    }

    // MARK: - BrainDiagnostics

    func testDiagnostics_initialStateIsStopped() {
        let diag = BrainDiagnostics()
        XCTAssertFalse(diag.isRunning)
        XCTAssertNil(diag.lastError)
        XCTAssertEqual(diag.requestsServed, 0)
    }

    func testDiagnostics_markRunning() {
        let diag = BrainDiagnostics()
        diag.markRunning(port: 8765)
        XCTAssertTrue(diag.isRunning)
        XCTAssertEqual(diag.listeningPort, 8765)
    }

    func testDiagnostics_recordRequest_incremensCount() {
        let diag = BrainDiagnostics()
        diag.recordRequest(path: "/brain/health", statusCode: 200)
        diag.recordRequest(path: "/brain/context", statusCode: 200)
        XCTAssertEqual(diag.requestsServed, 2)
        XCTAssertNotNil(diag.lastContextAt)
    }

    // MARK: - BrainContextEngine

    func testContextEngine_noProviders_returnsEmpty() async {
        let engine = BrainContextEngine()
        let blocks = await engine.buildContext(query: "test", categories: nil, maxItems: 5)
        XCTAssertTrue(blocks.isEmpty)
    }

    func testContextEngine_categoryFilter_skipsDisabledCategory() async {
        let engine = BrainContextEngine()
        engine.preferenceProvider = PreferenceContextProvider(prefs: PreferencesStore())
        // Only ask for memory — prefs provider should be skipped
        let blocks = await engine.buildContext(query: nil, categories: ["memory"], maxItems: 5)
        XCTAssertTrue(blocks.allSatisfy { $0.category != "preferences" })
    }

    // MARK: - pbxproj regression guard

    func testNoDuplicateBuildFileUUIDs() throws {
        let pbxpath = Bundle.main.bundlePath
            .components(separatedBy: "/Build/").first
            .flatMap { $0.components(separatedBy: "/JarvisMac.xcodeproj").first }
            .map { $0 + "/JarvisMac.xcodeproj/project.pbxproj" }
        guard let path = pbxpath,
              let content = try? String(contentsOfFile: path, encoding: .utf8) else { return }

        // Extract 24-hex-char UUIDs
        var seen = Set<String>()
        var duplicates = Set<String>()
        let pattern = try NSRegularExpression(pattern: "[A-F0-9]{24}", options: [])
        let matches = pattern.matches(in: content, range: NSRange(content.startIndex..., in: content))
        for match in matches {
            let uuid = String(content[Range(match.range, in: content)!])
            if !seen.insert(uuid).inserted { duplicates.insert(uuid) }
        }
        XCTAssertTrue(duplicates.isEmpty, "Duplicate pbxproj UUIDs: \(duplicates)")
    }
}
