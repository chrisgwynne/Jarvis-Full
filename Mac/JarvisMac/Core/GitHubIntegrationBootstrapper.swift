import Foundation

/// Result bundle returned by GitHubIntegrationBootstrapper.bootstrap().
@MainActor
struct GitHubBootstrapResult {
    let client: GitHubAPIClient
    let module: GitHubModule
    /// Non-nil only when subsystemGitHubProviderEnabled is true.
    let proactivityProvider: GitHubProactivityProvider?
}

/// Initialises the GitHub client, intelligence module, and optional proactivity provider.
///
/// Extracted from JarvisController.bootstrap() — Sprint N decomposition.
/// Returned objects must be stored by the caller to prevent deallocation.
@MainActor
enum GitHubIntegrationBootstrapper {

    /// Creates and starts the GitHub stack for the given token.
    ///
    /// Returns nil if the token is empty.
    static func bootstrap(
        token: String,
        llmRouter: LLMRouter,
        proactivity: ProactivityEngine,
        appState: AppState,
        prefs: PreferencesStore
    ) -> GitHubBootstrapResult {
        let client = GitHubAPIClient(token: token)
        let module = GitHubModule(token: token, llmRouter: llmRouter)
        var provider: GitHubProactivityProvider?
        if prefs.current.subsystemGitHubProviderEnabled {
            let prov = GitHubProactivityProvider(token: token, engine: proactivity, appState: appState)
            prov.start()
            provider = prov
        }
        return GitHubBootstrapResult(client: client, module: module, proactivityProvider: provider)
    }
}
