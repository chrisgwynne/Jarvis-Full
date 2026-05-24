import Foundation

/// Aggregates context from up to five providers, each capped at 500 ms.
/// Providers are called sequentially (all are @MainActor, no true parallelism
/// is possible); the per-provider timeout guard protects against a slow
/// HA REST call or similar blocking I/O.
@MainActor
final class BrainContextEngine {

    var memoryProvider:     MemoryContextProvider?
    var projectProvider:    ProjectContextProvider?
    var preferenceProvider: PreferenceContextProvider?
    var haAliasProvider:    HomeAssistantAliasProvider?
    var githubProvider:     GitHubContextProvider?

    func buildContext(query: String?,
                      categories: [String]?,
                      maxItems: Int) async -> [BrainContextBlock] {
        let cats = Set(categories ?? ["memory", "project", "preferences", "ha_aliases", "github"])
        var blocks: [BrainContextBlock] = []

        let pairs: [(String, (any BrainContextProviding)?)] = [
            ("memory",      memoryProvider),
            ("project",     projectProvider),
            ("preferences", preferenceProvider),
            ("ha_aliases",  haAliasProvider),
            ("github",      githubProvider),
        ]

        for (cat, provider) in pairs {
            guard cats.contains(cat), let provider else { continue }
            if let block = await timedProvide(provider, query: query, maxItems: maxItems) {
                blocks.append(block)
            }
        }
        return blocks
    }

    // MARK: - Per-provider 500 ms timeout

    private func timedProvide(_ provider: any BrainContextProviding,
                               query: String?,
                               maxItems: Int) async -> BrainContextBlock? {
        await withTaskGroup(of: BrainContextBlock?.self) { group in
            group.addTask { await provider.provide(query: query, maxItems: maxItems) }
            group.addTask {
                try? await Task.sleep(nanoseconds: 500_000_000)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
}

// MARK: - Provider protocol

protocol BrainContextProviding: AnyObject {
    var category: String { get }
    func provide(query: String?, maxItems: Int) async -> BrainContextBlock?
}
