import XCTest
@testable import JarvisMac

// MARK: - EntityFirstResolverTests

@MainActor
final class EntityFirstResolverTests: XCTestCase {

    // MARK: - NounSpanExtractor

    func testExtractOpenEuroNews() {
        let (action, spans) = NounSpanExtractor.extract(from: "open euro news")
        XCTAssertEqual(action, .open)
        XCTAssertTrue(spans.contains("euro news"), "spans=\(spans)")
    }

    func testExtractOpenBBC() {
        let (action, spans) = NounSpanExtractor.extract(from: "open bbc news")
        XCTAssertEqual(action, .open)
        XCTAssertTrue(spans.contains("bbc news") || spans.contains("bbc"), "spans=\(spans)")
    }

    func testExtractTurnOnKitchenLight() {
        let (action, spans) = NounSpanExtractor.extract(from: "turn on the kitchen light")
        XCTAssertEqual(action, .control)
        XCTAssertTrue(spans.contains("kitchen light") || spans.contains("kitchen"), "spans=\(spans)")
    }

    func testExtractPlaySpotify() {
        let (action, spans) = NounSpanExtractor.extract(from: "play spotify")
        XCTAssertEqual(action, .play)
        XCTAssertTrue(spans.contains("spotify"), "spans=\(spans)")
    }

    // MARK: - EntityScorer exact / alias

    func testScorerExactMatch() {
        let candidate = makeCandidate("euronews", "EuroNews", aliases: ["euro news"])
        let (score, reason) = EntityScorer.score(span: "euronews", against: candidate)
        XCTAssertGreaterThanOrEqual(score, 0.95, "reason=\(reason)")
    }

    func testScorerAliasMatch() {
        let candidate = makeCandidate("euronews", "EuroNews", aliases: ["euro news"])
        let (score, reason) = EntityScorer.score(span: "euro news", against: candidate)
        XCTAssertGreaterThanOrEqual(score, 0.90, "reason=\(reason)")
        XCTAssertTrue(reason.contains("alias"), "reason=\(reason)")
    }

    func testScorerFuzzyTypo() {
        let candidate = makeCandidate("bbc_news", "BBC News", aliases: ["bbc news", "bbc"])
        // "bbc nws" — one missing char
        let (score, _) = EntityScorer.score(span: "bbc nws", against: candidate)
        XCTAssertGreaterThanOrEqual(score, 0.60)
    }

    func testScorerPhoneticVariant() {
        // "euronues" — phonetically similar to "euronews"
        let candidate = makeCandidate("euronews", "EuroNews", aliases: ["euro news"])
        let jw = EntityScorer.jaroWinkler("euronews", "euronues")
        XCTAssertGreaterThan(jw, 0.85)
    }

    func testScorerGenericNewsLowScore() {
        // Span "news" alone should NOT confidently match "BBC News" (too generic)
        let candidate = makeCandidate("bbc_news", "BBC News", aliases: ["bbc", "bbc news"])
        let (score, _) = EntityScorer.score(span: "news", against: candidate)
        // "news" is a contains match in "bbc news" but ratio is low
        XCTAssertLessThan(score, EntityFirstResolver.minimumConfidence)
    }

    // MARK: - Jaro-Winkler

    func testJaroWinklerIdentical() {
        XCTAssertEqual(EntityScorer.jaroWinkler("skysports", "skysports"), 1.0, accuracy: 0.001)
    }

    func testJaroWinklerClose() {
        let jw = EntityScorer.jaroWinkler("sky sports", "sky sport")
        XCTAssertGreaterThan(jw, 0.90)
    }

    func testJaroWinklerDistant() {
        let jw = EntityScorer.jaroWinkler("netflix", "euronews")
        XCTAssertLessThan(jw, 0.70)
    }

    // MARK: - Soundex

    func testSoundexEuroNews() {
        let s1 = EntityScorer.soundex("euronews")
        let s2 = EntityScorer.soundex("euronues")
        XCTAssertEqual(s1, s2)
    }

    func testSoundexDifferent() {
        XCTAssertNotEqual(EntityScorer.soundex("netflix"), EntityScorer.soundex("euronews"))
    }

    // MARK: - MediaEntityProvider

    func testMediaProviderContainsEuroNews() async {
        let provider = MediaEntityProvider()
        let candidates = await provider.candidates(for: ["euro news"])
        XCTAssertTrue(candidates.contains { $0.entityId == "euronews" })
    }

    func testMediaProviderContainsBBCNews() async {
        let provider = MediaEntityProvider()
        let candidates = await provider.candidates(for: ["bbc"])
        XCTAssertTrue(candidates.contains { $0.entityId == "bbc_news" })
    }

    func testMediaProviderContainsSkySports() async {
        let provider = MediaEntityProvider()
        let candidates = await provider.candidates(for: ["sky sports"])
        XCTAssertTrue(candidates.contains { $0.entityId == "sky_sports" })
    }

    // MARK: - EntityIntentBinder

    func testBinderNewsChannelProducesOpenURL() {
        let result = makeResult(entityType: .newsChannel, action: .open,
                                url: URL(string: "https://www.euronews.com")!)
        let binding = EntityIntentBinder.bind(result)
        XCTAssertNotNil(binding)
        if case .openURL(let url) = binding!.intent {
            XCTAssertEqual(url.host, "www.euronews.com")
        } else {
            XCTFail("Expected .openURL intent")
        }
    }

    func testBinderAppProducesOpenApp() {
        let result = makeResult(entityType: .app, action: .open,
                                displayName: "Safari", bundleID: "com.apple.Safari")
        let binding = EntityIntentBinder.bind(result)
        XCTAssertNotNil(binding)
        if case .openApp = binding!.intent { } else {
            XCTFail("Expected .openApp intent")
        }
    }

    func testBinderSpokenPrefixContainsEntityName() {
        let result = makeResult(entityType: .newsChannel, action: .open,
                                displayName: "Sky Sports",
                                url: URL(string: "https://www.skysports.com")!)
        let binding = EntityIntentBinder.bind(result)
        XCTAssertNotNil(binding)
        XCTAssertTrue(binding!.spokenPrefix.contains("Sky Sports"))
    }

    // MARK: - CustomEntityAliasStore

    func testCustomAliasStoreRoundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_aliases_\(UUID().uuidString).json")
        let store = await MainActor.run { CustomEntityAliasStore(fileURL: tmp) }
        let entry = CustomEntityAliasStore.AliasEntry(
            alias: "euro", entityId: "euronews",
            displayName: "EuroNews", entityType: .newsChannel,
            url: URL(string: "https://www.euronews.com")
        )
        await MainActor.run { store.save(entry) }
        let loaded = await MainActor.run { store.allAliases() }
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].entityId, "euronews")
        try FileManager.default.removeItem(at: tmp)
    }

    // MARK: - GitHubEntityProvider

    func testGitHubProviderBuildsRepoCandidate() async {
        let note = makeGHNotification(fullName: "acme/auth-service")
        let provider = GitHubEntityProvider(getNotifications: { [note] })
        let candidates = await provider.candidates(for: ["auth service"])
        XCTAssertTrue(candidates.contains { $0.entityId == "github:acme/auth-service" },
                      "Should produce a candidate for acme/auth-service")
    }

    func testGitHubProviderDeduplicatesRepos() async {
        let n1 = makeGHNotification(fullName: "acme/auth-service")
        let n2 = makeGHNotification(fullName: "acme/auth-service")
        let provider = GitHubEntityProvider(getNotifications: { [n1, n2] })
        let candidates = await provider.candidates(for: ["auth"])
        let count = candidates.filter { $0.entityId == "github:acme/auth-service" }.count
        XCTAssertEqual(count, 1, "Same repo should only appear once")
    }

    func testGitHubProviderHasGitHubURL() async {
        let note = makeGHNotification(fullName: "octocat/hello-world")
        let provider = GitHubEntityProvider(getNotifications: { [note] })
        let candidates = await provider.candidates(for: ["hello world"])
        let candidate = candidates.first { $0.entityId == "github:octocat/hello-world" }
        XCTAssertEqual(candidate?.externalURL?.absoluteString, "https://github.com/octocat/hello-world")
    }

    func testGitHubProviderEntityType() async {
        let note = makeGHNotification(fullName: "owner/repo")
        let provider = GitHubEntityProvider(getNotifications: { [note] })
        let candidates = await provider.candidates(for: ["repo"])
        XCTAssertEqual(candidates.first?.entityType, .githubRepo)
    }

    // MARK: - HAAreaEntityProvider

    func testHAAreaProviderExtractsArea() async {
        let registry = await MainActor.run { makeRegistryWithArea("living_room") }
        let provider = await MainActor.run { HAAreaEntityProvider(registry: registry) }
        let candidates = await provider.candidates(for: ["living room"])
        XCTAssertTrue(candidates.contains { $0.entityType == .haRoom },
                      "Should produce a haRoom candidate")
    }

    func testHAAreaProviderHumanisesAreaName() async {
        let registry = await MainActor.run { makeRegistryWithArea("master_bedroom") }
        let provider = await MainActor.run { HAAreaEntityProvider(registry: registry) }
        let candidates = await provider.candidates(for: ["bedroom"])
        let candidate = candidates.first { $0.entityType == .haRoom }
        XCTAssertEqual(candidate?.displayName, "Master Bedroom")
    }

    func testHAAreaProviderDeduplicatesAreas() async {
        let registry = await MainActor.run { makeRegistryWithArea("kitchen", count: 3) }
        let provider = await MainActor.run { HAAreaEntityProvider(registry: registry) }
        let candidates = await provider.candidates(for: ["kitchen"])
        let count = candidates.filter { $0.entityType == .haRoom }.count
        XCTAssertEqual(count, 1, "Same area should only appear once")
    }

    // MARK: - EntityIntentBinder (new types)

    func testBinderHARoomProducesShowHomeOverlay() {
        let result = makeResult(entityType: .haRoom, action: .show, displayName: "Living Room")
        let binding = EntityIntentBinder.bind(result)
        XCTAssertNotNil(binding)
        if case .showHomeOverlay = binding!.intent { } else {
            XCTFail("Expected .showHomeOverlay, got \(String(describing: binding?.intent))")
        }
    }

    func testBinderGitHubRepoProducesOpenURL() {
        let result = makeResult(entityType: .githubRepo, action: .open,
                                displayName: "auth-service",
                                url: URL(string: "https://github.com/acme/auth-service")!)
        let binding = EntityIntentBinder.bind(result)
        XCTAssertNotNil(binding)
        if case .openURL(let url) = binding!.intent {
            XCTAssertEqual(url.host, "github.com")
        } else {
            XCTFail("Expected .openURL")
        }
    }

    func testBinderGitHubRepoNoURLFallsBackToGitHubOverlay() {
        let result = makeResult(entityType: .githubRepo, action: .open, displayName: "some-repo")
        let binding = EntityIntentBinder.bind(result)
        XCTAssertNotNil(binding)
        if case .showGitHubOverlay = binding!.intent { } else {
            XCTFail("Expected .showGitHubOverlay fallback")
        }
    }

    func testBinderAppleNoteProducesOpenNotes() {
        let result = makeResult(entityType: .appleNote, action: .open, displayName: "Meeting Notes")
        let binding = EntityIntentBinder.bind(result)
        XCTAssertNotNil(binding)
        if case .openNotes = binding!.intent { } else {
            XCTFail("Expected .openNotes, got \(String(describing: binding?.intent))")
        }
    }

    func testBinderFileProducesOpenURL() {
        let result = makeResult(entityType: .file, action: .open,
                                displayName: "Config.swift",
                                url: URL(fileURLWithPath: "/tmp/Config.swift"))
        let binding = EntityIntentBinder.bind(result)
        XCTAssertNotNil(binding)
        if case .openURL = binding!.intent { } else {
            XCTFail("Expected .openURL for file")
        }
    }

    // MARK: - EntityResolutionDiagnostics

    func testDiagnosticsRecordsResolution() {
        let diag = EntityResolutionDiagnostics()
        let result = makeResult(entityType: .newsChannel, action: .open,
                                url: URL(string: "https://example.com")!)
        diag.record(result)
        XCTAssertEqual(diag.totalResolutions, 1)
    }

    func testDiagnosticsSuccessRateCalculation() {
        let diag = EntityResolutionDiagnostics()
        let success = makeResult(entityType: .newsChannel, action: .open,
                                 url: URL(string: "https://a.com")!)
        let clarify = makeResultWithClarification(entityType: .app, action: .open)
        diag.record(success)
        diag.record(clarify)
        XCTAssertEqual(diag.successRate, 0.5, accuracy: 0.01)
    }

    func testDiagnosticsStatusLineNonEmpty() {
        let diag = EntityResolutionDiagnostics()
        XCTAssertEqual(diag.statusLine, "No resolutions yet")
        let result = makeResult(entityType: .app, action: .open,
                                displayName: "Safari", bundleID: "com.apple.Safari")
        diag.record(result)
        XCTAssertTrue(diag.statusLine.contains("Safari"))
    }

    // MARK: - pbxproj UUID regression


    // MARK: - Helpers

    private func makeCandidate(_ id: String, _ name: String,
                                aliases: [String] = [],
                                entityType: EntityType = .newsChannel) -> EntityCandidate {
        EntityCandidate(
            entityId: id, displayName: name, entityType: entityType,
            provider: "test", aliases: aliases,
            externalURL: nil, bundleIdentifier: nil, baseConfidence: 1.0
        )
    }

    private func makeResult(entityType: EntityType, action: EntityAction,
                             displayName: String = "Test Entity",
                             url: URL? = nil, bundleID: String? = nil) -> EntityResolutionResult {
        let candidate = EntityCandidate(
            entityId: "test", displayName: displayName, entityType: entityType,
            provider: "test", aliases: [],
            externalURL: url, bundleIdentifier: bundleID, baseConfidence: 1.0,
            matchedAlias: nil, score: 0.95, matchReason: "test"
        )
        return EntityResolutionResult(
            originalSpan: displayName.lowercased(),
            action: action, entity: candidate,
            competingCandidates: [], needsClarification: false
        )
    }

    private func makeResultWithClarification(entityType: EntityType,
                                              action: EntityAction) -> EntityResolutionResult {
        let candidate = EntityCandidate(
            entityId: "test-clarify", displayName: "Ambiguous Entity",
            entityType: entityType, provider: "test", aliases: [],
            externalURL: nil, bundleIdentifier: nil, baseConfidence: 1.0,
            matchedAlias: nil, score: 0.78, matchReason: "test"
        )
        return EntityResolutionResult(
            originalSpan: "ambiguous",
            action: action, entity: candidate,
            competingCandidates: [], needsClarification: true
        )
    }

    // MARK: - Sprint S test helpers

    private func makeGHNotification(fullName: String) -> GHNotification {
        GHNotification(
            id: UUID().uuidString,
            reason: "mention",
            unread: true,
            updated_at: "2025-01-01T00:00:00Z",
            subject: GHNotification.Subject(title: "Test", type: "PullRequest", url: nil),
            repository: GHNotification.Repository(full_name: fullName)
        )
    }

    @MainActor
    private func makeRegistryWithArea(_ area: String, count: Int = 1) -> HAEntityRegistry {
        let registry = HAEntityRegistry()
        let entities = (0..<count).map { i in
            HomeEntity(
                entityID: "light.device_\(i)",
                state: "on",
                friendlyName: "Device \(i)",
                lastChanged: nil
            )
        }
        var attrs: [String: [String: Any]] = [:]
        for entity in entities {
            attrs[entity.entityID] = ["area_id": area as Any]
        }
        registry.sync(from: entities, attributes: attrs)
        return registry
    }
}
