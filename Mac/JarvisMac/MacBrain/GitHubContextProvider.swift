import Foundation

/// Returns recent GitHub notifications (review requests, mentions, assignments)
/// so Android can surface them without an extra API call.
@MainActor
final class GitHubContextProvider: BrainContextProviding {
    let category = "github"

    /// Injected closure returns the most recent cached notifications.
    /// Wire to `githubClient?.cachedNotifications` or similar.
    var getNotifications: () -> [GHNotification] = { [] }

    func provide(query: String?, maxItems: Int) async -> BrainContextBlock? {
        let notifications = getNotifications()
        guard !notifications.isEmpty else { return nil }

        let items = notifications.prefix(maxItems).map { n -> BrainContextItem in
            BrainContextItem(
                key: n.reason,
                value: "\(n.repository.full_name): \(n.subject.title)",
                confidence: nil,
                source: "github"
            )
        }
        guard !items.isEmpty else { return nil }
        return BrainContextBlock(category: category, label: "GitHub", items: Array(items))
    }
}
