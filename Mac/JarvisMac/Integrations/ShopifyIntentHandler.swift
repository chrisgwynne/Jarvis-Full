import Foundation

/// Handles all Shopify-domain intents previously inline in JarvisController.execute().
/// Extracted as the pilot per-domain handler — Sprint O decomposition.
@MainActor final class ShopifyIntentHandler {

    private let prefs: PreferencesStore
    private let renderer: ResponseRenderer

    var speak: (String) -> Void = { _ in }
    var openOverlay: (OverlayKind) -> Void = { _ in }

    init(prefs: PreferencesStore, renderer: ResponseRenderer) {
        self.prefs = prefs
        self.renderer = renderer
    }

    /// Returns true if the intent was handled, false if it is not a Shopify intent.
    @discardableResult
    func handle(_ intent: Intent) -> Bool {
        switch intent {
        case .showShopifyOverlay:
            openOverlay(.shopify)
            speak(renderer.render(ResponseKey.shopifyOverlay))
            return true
        case .shopifyOrders, .shopifyStatus:
            fetchOrders()
            return true
        case .shopifyRevenue:
            fetchRevenue()
            return true
        case .shopifyFulfilment:
            fetchFulfilment()
            return true
        default:
            return false
        }
    }

    private func fetchOrders() {
        Task {
            let p = prefs.current
            guard let token = prefs.shopifyAccessToken, !token.isEmpty,
                  let domain = p.shopifyShopDomain, !domain.isEmpty else {
                speak(renderer.render(ResponseKey.shopifyNotConfig)); return
            }
            let client = ShopifyAPIClient(shopDomain: domain, accessToken: token)
            guard let orders = try? await client.getRecentOrders(since: 24) else { return }
            if orders.isEmpty {
                speak(renderer.render(ResponseKey.shopifyNoOrders))
            } else {
                let count = orders.count
                let top = orders.prefix(3).map { order -> String in
                    let items = order.lineItems.prefix(2)
                        .map { $0.quantity > 1 ? "\($0.quantity) \($0.title)" : $0.title }
                        .joined(separator: " and ")
                    return items.isEmpty
                        ? "order \(order.orderNumber)"
                        : "order \(order.orderNumber) for \(items)"
                }.joined(separator: "; ")
                speak(renderer.render(ResponseKey.shopifyOrders, [
                    "count":  "\(count)",
                    "plural": count == 1 ? "" : "s",
                    "top":    top
                ]))
            }
        }
    }

    private func fetchRevenue() {
        Task {
            let p = prefs.current
            guard let token = prefs.shopifyAccessToken, !token.isEmpty,
                  let domain = p.shopifyShopDomain, !domain.isEmpty else {
                speak(renderer.render(ResponseKey.shopifyNotConfig)); return
            }
            let client = ShopifyAPIClient(shopDomain: domain, accessToken: token)
            guard let (count, total, currency) = try? await client.getTodayRevenue() else { return }
            speak(renderer.render(ResponseKey.shopifyRevenue, [
                "count":    "\(count)",
                "plural":   count == 1 ? "" : "s",
                "total":    String(format: "%.2f", total),
                "currency": currency
            ]))
        }
    }

    private func fetchFulfilment() {
        Task {
            let p = prefs.current
            guard let token = prefs.shopifyAccessToken, !token.isEmpty,
                  let domain = p.shopifyShopDomain, !domain.isEmpty else {
                speak(renderer.render(ResponseKey.shopifyNotConfig)); return
            }
            let client = ShopifyAPIClient(shopDomain: domain, accessToken: token)
            guard let orders = try? await client.getUnfulfilledOrders() else { return }
            let count = orders.count
            speak(renderer.render(ResponseKey.shopifyFulfilment, [
                "count":    "\(count)",
                "plural":   count == 1 ? "" : "s",
                "plural_s": count == 1 ? "s" : ""
            ]))
        }
    }
}
