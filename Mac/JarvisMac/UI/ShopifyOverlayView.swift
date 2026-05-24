import SwiftUI

struct ShopifyOverlayView: View {
    let prefs: PreferencesStore

    @State private var recentOrders:  [ShopifyOrder] = []
    @State private var unfulfilled:   [ShopifyOrder] = []
    @State private var todayRevenue:  (count: Int, total: Double, currency: String) = (0, 0, "GBP")
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var client: ShopifyAPIClient? {
        guard let token  = prefs.shopifyAccessToken,
              let domain = prefs.current.shopifyShopDomain,
              !token.isEmpty, !domain.isEmpty
        else { return nil }
        return ShopifyAPIClient(shopDomain: domain, accessToken: token)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Revenue / order stats strip
            HStack(spacing: 24) {
                statPill(
                    label: "Revenue Today",
                    value: String(format: "%@ %.2f", todayRevenue.currency, todayRevenue.total)
                )
                statPill(label: "Orders Today",  value: "\(todayRevenue.count)")
                statPill(label: "Unfulfilled",   value: "\(unfulfilled.count)")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color.green.opacity(0.10))

            Divider().overlay(Color.white.opacity(0.08))

            if isLoading {
                Spacer()
                ProgressView("Loading Shopify…")
                    .progressViewStyle(.circular)
                Spacer()
            } else if let msg = errorMessage {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2).foregroundStyle(.orange)
                    Text(msg)
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !unfulfilled.isEmpty {
                            sectionHeader("Needs Fulfilling (\(unfulfilled.count))", color: .orange)
                            ForEach(unfulfilled) { order in
                                orderRow(order, accent: .orange)
                                Divider().opacity(0.06).padding(.leading, 12)
                            }
                        }
                        if !recentOrders.isEmpty {
                            sectionHeader("Recent Orders (24 h)", color: .green)
                            ForEach(recentOrders.prefix(15)) { order in
                                orderRow(order, accent: .green)
                                Divider().opacity(0.06).padding(.leading, 12)
                            }
                        }
                        if unfulfilled.isEmpty && recentOrders.isEmpty {
                            emptyState
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
        .task { await loadData() }
    }

    // MARK: - Sub-views

    private func statPill(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3.bold())
                .foregroundStyle(.green)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func sectionHeader(_ text: String, color: Color) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .tracking(1.2)
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    private func orderRow(_ order: ShopifyOrder, accent: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("#\(order.orderNumber)")
                        .font(.subheadline.bold())
                    if order.isUnfulfilled {
                        Text("UNFULFILLED")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange.opacity(0.18)))
                            .foregroundStyle(.orange)
                    }
                }
                Text(order.customerName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !order.lineItems.isEmpty {
                    Text(order.lineItems.prefix(2).map { $0.title }.joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(order.displayPrice)
                    .font(.subheadline.bold())
                    .foregroundStyle(accent)
                Text(order.createdAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bag")
                .font(.title2).foregroundStyle(.secondary)
            Text("No orders today")
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(32)
    }

    // MARK: - Data loading

    private func loadData() async {
        guard let client else {
            errorMessage = "Shopify not configured. Add your credentials in Settings → Integrations."
            isLoading = false
            return
        }
        isLoading = true
        errorMessage = nil
        async let ordersResult     = client.getRecentOrders(since: 24)
        async let unfulfilledResult = client.getUnfulfilledOrders()
        async let revenueResult    = client.getTodayRevenue()
        do {
            let (orders, unfulfill, revenue) = try await (ordersResult, unfulfilledResult, revenueResult)
            recentOrders  = orders
            unfulfilled   = unfulfill
            todayRevenue  = revenue
        } catch {
            errorMessage = "Failed to load Shopify data: \(error.localizedDescription)"
        }
        isLoading = false
    }
}

#Preview {
    ShopifyOverlayView(prefs: PreferencesStore())
        .frame(width: 720, height: 536)
}
