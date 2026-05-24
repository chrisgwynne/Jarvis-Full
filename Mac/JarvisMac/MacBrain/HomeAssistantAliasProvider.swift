import Foundation

/// Returns the user's Home Assistant entity aliases so Android can resolve
/// spoken names to entity IDs without calling the Mac.
@MainActor
final class HomeAssistantAliasProvider: BrainContextProviding {
    let category = "ha_aliases"
    private weak var aliasStore: HomeEntityAliasStore?

    init(aliasStore: HomeEntityAliasStore) {
        self.aliasStore = aliasStore
    }

    func provide(query: String?, maxItems: Int) async -> BrainContextBlock? {
        guard let store = aliasStore else { return nil }
        let aliases = store.aliases
        guard !aliases.isEmpty else { return nil }

        let items = aliases.prefix(maxItems).map { alias in
            BrainContextItem(
                key: alias.friendlyName,
                value: alias.entityID,
                confidence: 1.0,
                source: "ha_alias_store"
            )
        }
        return BrainContextBlock(category: category, label: "HA aliases", items: Array(items))
    }
}
