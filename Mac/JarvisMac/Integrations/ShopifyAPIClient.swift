import Foundation

// MARK: - Models

struct ShopifyOrder: Codable, Identifiable {
    let id: Int
    let orderNumber: Int
    let email: String?
    let financialStatus: String
    let fulfillmentStatus: String?
    let totalPrice: String
    let currency: String
    let createdAt: Date
    let lineItems: [LineItem]

    struct LineItem: Codable {
        let title: String
        let quantity: Int
    }

    var isUnfulfilled: Bool {
        (fulfillmentStatus == nil || fulfillmentStatus == "unfulfilled") && financialStatus == "paid"
    }

    var customerName: String {
        email?.components(separatedBy: "@").first ?? "Customer"
    }

    var displayPrice: String {
        "\(currency) \(totalPrice)"
    }

    enum CodingKeys: String, CodingKey {
        case id, email, currency
        case orderNumber       = "order_number"
        case financialStatus   = "financial_status"
        case fulfillmentStatus = "fulfillment_status"
        case totalPrice        = "total_price"
        case createdAt         = "created_at"
        case lineItems         = "line_items"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id               = try c.decode(Int.self,    forKey: .id)
        orderNumber      = try c.decode(Int.self,    forKey: .orderNumber)
        email            = try c.decodeIfPresent(String.self, forKey: .email)
        financialStatus  = try c.decode(String.self, forKey: .financialStatus)
        fulfillmentStatus = try c.decodeIfPresent(String.self, forKey: .fulfillmentStatus)
        totalPrice       = try c.decode(String.self, forKey: .totalPrice)
        currency         = try c.decode(String.self, forKey: .currency)
        createdAt        = try c.decode(Date.self,   forKey: .createdAt)
        lineItems        = (try? c.decode([LineItem].self, forKey: .lineItems)) ?? []
    }
}

struct ShopifyProduct: Codable, Identifiable {
    let id: Int
    let title: String
    let variants: [Variant]

    struct Variant: Codable {
        let id: Int
        let title: String
        let inventoryQuantity: Int?

        enum CodingKeys: String, CodingKey {
            case id, title
            case inventoryQuantity = "inventory_quantity"
        }
    }

    var totalInventory: Int {
        variants.compactMap { $0.inventoryQuantity }.reduce(0, +)
    }
}

// MARK: - Client

final class ShopifyAPIClient {
    private let shopDomain: String
    private let accessToken: String
    private let session = URLSession.shared
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(shopDomain: String, accessToken: String) {
        self.shopDomain  = shopDomain
        self.accessToken = accessToken
    }

    private func request(_ endpoint: String) -> URLRequest? {
        let clean = shopDomain.hasPrefix("https://") ? shopDomain : "https://\(shopDomain)"
        guard let url = URL(string: "\(clean)/admin/api/2024-01/\(endpoint)") else { return nil }
        var req = URLRequest(url: url)
        req.setValue(accessToken, forHTTPHeaderField: "X-Shopify-Access-Token")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return req
    }

    // MARK: - Orders

    /// Fetch orders created within the last `hoursAgo` hours (limit 50).
    func getRecentOrders(since hoursAgo: Int = 24) async throws -> [ShopifyOrder] {
        let since = ISO8601DateFormatter().string(from: Date().addingTimeInterval(TimeInterval(-hoursAgo * 3600)))
        guard let req = request("orders.json?status=any&limit=50&created_at_min=\(since)") else { return [] }
        let (data, _) = try await session.data(for: req)
        struct Wrapper: Codable { let orders: [ShopifyOrder] }
        return try decoder.decode(Wrapper.self, from: data).orders
    }

    /// Fetch paid, unfulfilled orders.
    func getUnfulfilledOrders() async throws -> [ShopifyOrder] {
        guard let req = request("orders.json?fulfillment_status=unfulfilled&financial_status=paid&limit=50") else { return [] }
        let (data, _) = try await session.data(for: req)
        struct Wrapper: Codable { let orders: [ShopifyOrder] }
        return try decoder.decode(Wrapper.self, from: data).orders
    }

    /// Today's revenue: (order count, total, currency).
    func getTodayRevenue() async throws -> (count: Int, total: Double, currency: String) {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let since = ISO8601DateFormatter().string(from: startOfDay)
        guard let req = request("orders.json?status=any&financial_status=paid&limit=250&created_at_min=\(since)") else {
            return (0, 0, "GBP")
        }
        let (data, _) = try await session.data(for: req)
        struct Wrapper: Codable { let orders: [ShopifyOrder] }
        let orders = try decoder.decode(Wrapper.self, from: data).orders
        let total = orders.compactMap { Double($0.totalPrice) }.reduce(0, +)
        let currency = orders.first?.currency ?? "GBP"
        return (orders.count, total, currency)
    }

    // MARK: - Inventory

    /// Products whose total inventory is at or below `threshold`.
    func getLowStockProducts(threshold: Int = 5) async throws -> [ShopifyProduct] {
        guard let req = request("products.json?limit=250") else { return [] }
        let (data, _) = try await session.data(for: req)
        struct Wrapper: Codable { let products: [ShopifyProduct] }
        let products = try decoder.decode(Wrapper.self, from: data).products
        return products.filter { $0.totalInventory <= threshold && $0.totalInventory >= 0 }
    }
}
