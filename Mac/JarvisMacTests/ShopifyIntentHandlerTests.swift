import XCTest
@testable import JarvisMac

final class ShopifyIntentHandlerTests: XCTestCase {

    @MainActor
    private func makeHandler() -> (ShopifyIntentHandler, PreferencesStore) {
        let prefs    = PreferencesStore()
        let renderer = ResponseRenderer(store: ResponseTemplateStore())
        let h        = ShopifyIntentHandler(prefs: prefs, renderer: renderer)
        return (h, prefs)
    }

    // MARK: - Return value

    @MainActor
    func test_shopifyIntents_returnTrue() {
        let (h, _) = makeHandler()
        var spoken = [String]()
        h.speak = { spoken.append($0) }
        h.openOverlay = { _ in }

        let shopifyIntents: [Intent] = [
            .showShopifyOverlay,
            .shopifyOrders,
            .shopifyStatus,
            .shopifyRevenue,
            .shopifyFulfilment,
        ]
        for intent in shopifyIntents {
            XCTAssertTrue(h.handle(intent),
                          "Expected true for \(intent)")
        }
    }

    @MainActor
    func test_nonShopifyIntent_returnsFalse() {
        let (h, _) = makeHandler()
        h.speak      = { _ in }
        h.openOverlay = { _ in }

        XCTAssertFalse(h.handle(.showCalendar))
        XCTAssertFalse(h.handle(.spotifyPause))
        XCTAssertFalse(h.handle(.currentWeather))
    }

    // MARK: - showShopifyOverlay

    @MainActor
    func test_showShopifyOverlay_opensOverlayAndSpeaks() {
        let (h, _) = makeHandler()
        var spokenTexts = [String]()
        var openedOverlays = [OverlayKind]()
        h.speak       = { spokenTexts.append($0) }
        h.openOverlay = { openedOverlays.append($0) }

        _ = h.handle(.showShopifyOverlay)

        XCTAssertEqual(openedOverlays, [.shopify])
        XCTAssertFalse(spokenTexts.isEmpty)
    }

    // MARK: - Not-configured guard

    @MainActor
    func test_shopifyOrders_withNoToken_speaksNotConfigured() {
        let (h, _) = makeHandler()
        // PreferencesStore with no keychain entry → token is nil → fetchOrders should speak "not config"
        var spokenTexts = [String]()
        h.speak       = { spokenTexts.append($0) }
        h.openOverlay = { _ in }

        _ = h.handle(.shopifyOrders)

        // fetchOrders fires a Task; flush with a brief expectation
        let exp = expectation(description: "task fires")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        // Token is nil → should have spoken the "not configured" message
        XCTAssertFalse(spokenTexts.isEmpty,
                       "Expected a 'not configured' response; got none")
    }
}
