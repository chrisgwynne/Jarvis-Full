import Foundation

/// Polls Shopify every 5 minutes and emits proactivity signals for:
/// - New orders (compared against a seen-IDs set)
/// - Low inventory products (checked once per hour)
@MainActor
final class ShopifyProactivityProvider: ProactivitySignalProvider {
    var source: SignalSource { .shopify }

    private weak var engine: ProactivityEngine?
    private weak var appState: AppState?
    private let prefs: PreferencesStore
    private var pollTask: Task<Void, Never>?

    /// Persistent dedup set — survives app restarts so re-launching within
    /// the 6 h lookback window no longer re-alerts every order again.
    private let dedup = ProactivityDedupStore(name: "shopify.orders")
    private var lastLowStockCheck = Date.distantPast
    /// True during the very first poll — we seed `dedup` silently so
    /// we don't fire TTS alerts for every existing order on launch.
    private var isFirstPoll = true

    init(engine: ProactivityEngine, appState: AppState, prefs: PreferencesStore) {
        self.engine   = engine
        self.appState = appState
        self.prefs    = prefs
    }

    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollNow()
                try? await Task.sleep(for: .seconds(300)) // 5 min
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func pollNow() async {
        let p = prefs.current
        guard let token = prefs.shopifyAccessToken, !token.isEmpty,
              let domain = p.shopifyShopDomain, !domain.isEmpty else { return }

        let client = ShopifyAPIClient(shopDomain: domain, accessToken: token)

        // MARK: New orders
        if let orders = try? await client.getRecentOrders(since: 6) {
            let newOrders = orders.filter { !dedup.contains(String($0.id)) }
            // Persistent insert — the store handles bulk write + cap + atomic
            // serialisation to ~/Library/Application Support/JarvisMac/dedup/.
            dedup.insertBatch(orders.map { String($0.id) })

            // On the first poll we silently seed `dedup` so we don't
            // announce every existing order from the last 6 hours on launch.
            if !isFirstPoll {
                for order in newOrders.prefix(3) {
                    let signal = ProactivitySignal(
                        source: .shopify,
                        title: "New order #\(order.orderNumber)",
                        body: "Order #\(order.orderNumber) from \(order.customerName) — \(order.displayPrice)",
                        category: "shopify.order",
                        priority: .high,
                        dedupeKey: "shopify.order.\(order.id)",
                        spokenText: "New order \(order.orderNumber) from \(order.customerName) — \(order.displayPrice)."
                    )
                    ProactivityOrchestrator.shared.providerPublish(signal: signal)
                }
            }
        }
        isFirstPoll = false

        // MARK: Low stock (hourly)
        if Date().timeIntervalSince(lastLowStockCheck) > 3600 {
            lastLowStockCheck = Date()
            let threshold = prefs.current.shopifyLowStockThreshold
            if let lowStock = try? await client.getLowStockProducts(threshold: threshold) {
                for product in lowStock.prefix(2) {
                    let key = "shopify.lowstock.\(product.id).\(product.totalInventory)"
                    let signal = ProactivitySignal(
                        source: .shopify,
                        title: "Low stock: \(product.title)",
                        body: "\(product.title) has only \(product.totalInventory) left.",
                        category: "shopify.inventory",
                        priority: .normal,
                        dedupeKey: key,
                        spokenText: "\(product.title) is running low — \(product.totalInventory) remaining."
                    )
                    ProactivityOrchestrator.shared.providerPublish(signal: signal)
                }
            }
        }
    }
}
