import XCTest
@testable import JarvisMac

final class HomeAssistantIntentHandlerTests: XCTestCase {

    @MainActor
    private func makeHandler() -> HomeAssistantIntentHandler {
        let registry  = HAEntityRegistry()
        let mapper    = HAMotionCameraMapper()
        let proact    = ProactivityEngine()
        let renderer  = ResponseRenderer(store: ResponseTemplateStore())
        let state     = AppState()
        return HomeAssistantIntentHandler(
            haEntityRegistry: registry,
            haMotionMapper:   mapper,
            proactivity:      proact,
            renderer:         renderer,
            state:            state
        )
    }

    // MARK: - Return value

    @MainActor
    func test_haIntents_returnTrue() async {
        let h = makeHandler()
        h.speak             = { _ in }
        h.openOverlay       = { _ in }
        h.closeOverlay      = { _ in }
        h.setPendingContext = { _ in }
        h.currentTranscript = { "" }
        h.getSmartHome      = { DisabledSmartHomeClient() }
        h.statusSummary     = { "2 lights on" }
        h.entityLookup      = { [] }

        let intents: [Intent] = [
            .homeStatus,
            .homeTurnOn(entity: "living room lights"),
            .homeTurnOff(entity: "bedroom lights"),
            .homeQueryEntity(entity: "light.living_room"),
            .homeSetBrightness(entity: "light.living_room", level: 50),
            .homeSetColor(entity: "light.living_room", color: "red"),
            .homeActivateScene(sceneName: "Movie Night"),
            .homeRunAutomation(name: "Good Morning"),
            .homeOpenCover(entity: "cover.garage"),
            .homeCloseCover(entity: "cover.garage"),
            .homeLock(entity: "lock.front_door"),
            .homeUnlock(entity: "lock.front_door"),
            .homeShowCamera(entity: "camera.front"),
            .homeShowCameraOverlay(entity: "camera.front"),
            .homeCloseCamera,
            .homeShowAllCameras,
            .homeMuteAlerts,
            .homeUnmuteAlerts,
            .homeIgnoreCameraForHour(entity: "camera.front"),
            .homeShowHADiagnostics,
        ]
        for intent in intents {
            let handled = await h.handle(intent)
            XCTAssertTrue(handled, "Expected true for \(intent)")
        }
    }

    @MainActor
    func test_nonHAIntent_returnsFalse() async {
        let h = makeHandler()
        h.speak = { _ in }

        let handled = await h.handle(.spotifyPause)
        XCTAssertFalse(handled)
    }

    // MARK: - homeStatus

    @MainActor
    func test_homeStatus_speaksStatusSummary() async {
        let h = makeHandler()
        var spokenTexts = [String]()
        h.speak         = { spokenTexts.append($0) }
        h.openOverlay   = { _ in }
        h.closeOverlay  = { _ in }
        h.getSmartHome  = { DisabledSmartHomeClient() }
        h.statusSummary = { "3 lights on, garage open" }

        _ = await h.handle(.homeStatus)

        XCTAssertEqual(spokenTexts, ["3 lights on, garage open"])
    }

    // MARK: - Ambiguous homeTurnOn sets pending context

    @MainActor
    func test_homeTurnOn_withAmbiguousEntity_setsPendingContext() async {
        let h = makeHandler()
        var spokenTexts       = [String]()
        var pendingContextSet = false
        h.speak             = { spokenTexts.append($0) }
        h.openOverlay       = { _ in }
        h.closeOverlay      = { _ in }
        h.setPendingContext = { _ in pendingContextSet = true }
        h.currentTranscript = { "turn on the lights" }
        h.getSmartHome      = { DisabledSmartHomeClient() }

        _ = await h.handle(.homeTurnOn(entity: "lights"))

        XCTAssertTrue(pendingContextSet, "Expected disambiguation context to be set")
        XCTAssertFalse(spokenTexts.isEmpty, "Expected clarifying question spoken")
    }

    // MARK: - homeMuteAlerts / homeUnmuteAlerts

    @MainActor
    func test_homeMuteAlerts_speaksAndMutes() async {
        let h = makeHandler()
        var spokenTexts = [String]()
        h.speak = { spokenTexts.append($0) }

        _ = await h.handle(.homeMuteAlerts)

        XCTAssertFalse(spokenTexts.isEmpty)
    }

    @MainActor
    func test_homeUnmuteAlerts_speaks() async {
        let h = makeHandler()
        var spokenTexts = [String]()
        h.speak = { spokenTexts.append($0) }

        _ = await h.handle(.homeUnmuteAlerts)

        XCTAssertFalse(spokenTexts.isEmpty)
    }

    // MARK: - Not-configured guard

    @MainActor
    func test_homeSetBrightness_withUnconfiguredSmartHome_speaksNotConfigured() async {
        let h = makeHandler()
        var spokenTexts = [String]()
        h.speak        = { spokenTexts.append($0) }
        h.openOverlay  = { _ in }
        h.closeOverlay = { _ in }
        // DisabledSmartHomeClient.isConfigured is false
        h.getSmartHome = { DisabledSmartHomeClient() }

        _ = await h.handle(.homeSetBrightness(entity: "light.test", level: 80))

        XCTAssertFalse(spokenTexts.isEmpty)
    }

    // MARK: - homeCloseCamera

    @MainActor
    func test_homeCloseCamera_closesOverlayAndSpeaks() async {
        let h = makeHandler()
        var closedOverlays = [OverlayKind]()
        var spokenTexts    = [String]()
        h.speak        = { spokenTexts.append($0) }
        h.openOverlay  = { _ in }
        h.closeOverlay = { closedOverlays.append($0) }

        _ = await h.handle(.homeCloseCamera)

        XCTAssertTrue(closedOverlays.contains(.haCamera))
        XCTAssertFalse(spokenTexts.isEmpty)
    }
}
