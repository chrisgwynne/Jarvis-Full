import Foundation

/// Returns committed long-term memories from `BrainMemoryStore`.
@MainActor
final class MemoryContextProvider: BrainContextProviding {
    let category = "memory"

    func provide(query: String?, maxItems: Int) async -> BrainContextBlock? {
        let q = query ?? ""
        let memories = await BrainMemoryStore.shared.search(query: q, limit: min(maxItems, 5))
        guard !memories.isEmpty else { return nil }

        let items = memories.map { m in
            BrainContextItem(
                key: m.title,
                value: m.summary,
                confidence: m.importance * m.confidence,
                source: m.type.rawValue
            )
        }
        return BrainContextBlock(category: category, label: "Memory", items: items)
    }
}
