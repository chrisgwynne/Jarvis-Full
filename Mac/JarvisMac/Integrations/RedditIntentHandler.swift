import Foundation
import AppKit

/// Handles Reddit-domain intents and helpers previously inline in JarvisController.
/// Extracted following the per-domain handler pattern — Sprint Q decomposition.
@MainActor final class RedditIntentHandler {

    private let redditStore: RedditStore
    private let state: AppState
    private let llmRouter: LLMRouter

    var speak: (String) -> Void = { _ in }
    var openOverlay: (OverlayKind) -> Void = { _ in }

    init(redditStore: RedditStore, state: AppState, llmRouter: LLMRouter) {
        self.redditStore = redditStore
        self.state = state
        self.llmRouter = llmRouter
    }

    /// Returns true if the intent was handled, false if it is not a Reddit intent.
    func handle(_ intent: Intent) -> Bool {
        switch intent {

        case .showReddit:
            executeShow(mode: .feed, spoken: "Opening Reddit.")
            return true

        case .showRedditTop:
            executeShow(mode: .top, spoken: "Showing the top Reddit posts across your sources.")
            return true

        case .showSubreddit(let name):
            if let src = redditStore.source(matchingName: name) {
                executeShow(mode: .subreddit(src.id), spoken: "Opening r/\(src.subreddit).",
                            refreshSourceId: src.id)
            } else {
                openOverlay(.reddit)
                state.redditLastError = "Subreddit '\(name)' is not in your configured sources."
                speak("I don't have r/\(name) configured. Add it in Settings → Reddit and I'll fetch it.")
            }
            return true

        case .redditQuery(let query):
            Task { await executeQuery(query) }
            return true

        case .redditOpenIndex(let index):
            executeOpenIndex(index)
            return true

        case .redditShowComments:
            Task { await executeShowComments() }
            return true

        case .redditOpenInBrowser:
            executeOpenInBrowser()
            return true

        case .redditSavePost:
            executeSavePost()
            return true

        case .redditSummarisePost:
            Task { await executeSummarisePost() }
            return true

        case .redditSummariseComments:
            Task { await executeSummariseComments() }
            return true

        case .redditRefresh:
            openOverlay(.reddit)
            speak("Refreshing Reddit.")
            Task { await redditStore.refreshAllEnabledSources() }
            return true

        default:
            return false
        }
    }

    // MARK: - Helpers

    enum SummaryKind { case post, comments }

    private func executeShow(mode: RedditOverlayMode,
                              spoken: String,
                              refreshSourceId: String? = nil) {
        openOverlay(.reddit)
        state.redditPendingMode = mode
        speak(spoken)
        if let id = refreshSourceId, let s = redditStore.source(id: id) {
            Task { await redditStore.refreshSource(s) }
        } else {
            let stale: Bool = {
                if redditStore.posts.isEmpty { return true }
                guard let last = redditStore.lastFullRefreshAt else { return true }
                return Date().timeIntervalSince(last) > 600
            }()
            if stale {
                Task { await redditStore.refreshAllEnabledSources() }
            }
        }
        ActiveContextRegistry.shared.record(
            source: .other,
            title: "Reddit list",
            summary: "Active Reddit post list",
            pronouns: ["it", "that", "this", "the list", "these posts"],
            priority: 3,
            suggestedActions: [.open, .describeMore])
    }

    private func executeQuery(_ query: String) async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            speak("What should I search Reddit for?")
            return
        }
        openOverlay(.reddit)
        state.redditPendingMode = .search(q)
        state.redditLastQuery = q
        speak("Searching Reddit for \(q).")
        let result = await redditStore.searchAcrossSources(query: q)
        if result.posts.isEmpty {
            if result.errors.isEmpty {
                speak("I didn't find anything about \(q) in your configured subreddits.")
            } else {
                state.redditLastError = result.errors.joined(separator: "; ")
                speak("Reddit search ran into a problem. Check Settings → Reddit for details.")
            }
            return
        }
        state.redditPendingSelectionPostId = result.posts.first?.id
        if llmRouter.mode != .disabled {
            let snippets = result.posts.prefix(8).enumerated().map {
                "\($0.offset + 1). [r/\($0.element.subreddit)] \($0.element.title)"
            }.joined(separator: "\n")
            let req = LLMRequest(
                systemPrompt: """
                You are Jarvis. Summarise the dominant Reddit themes in 2 spoken
                sentences. No bullets, under 50 words.
                """,
                userPrompt: "Topic: \(q)\nTop posts:\n\(snippets)",
                contextSummary: nil,
                temperature: 0.4, maxTokens: 150,
                responseFormat: .text, timeoutSeconds: 20)
            do {
                let r = try await llmRouter.complete(req)
                speak("Reddit on \(q): \(r.text)")
            } catch {
                speak("Found \(result.posts.count) posts about \(q) across your subreddits.")
            }
        } else {
            speak("Found \(result.posts.count) posts about \(q) across your subreddits.")
        }
    }

    private func executeOpenIndex(_ index: Int) {
        let list = redditStore.posts
            .filter { !redditStore.dismissedPostIds.contains($0.id) }
        guard index >= 0, index < list.count else {
            speak("I don't have a post at position \(index + 1).")
            return
        }
        let post = list[index]
        openOverlay(.reddit)
        state.redditPendingSelectionPostId = post.id
        speak("Opening: \(post.title)")
        ActiveContextRegistry.shared.record(
            source: .other,
            title: "Reddit: " + post.title,
            summary: "r/\(post.subreddit)",
            externalIdentifier: post.id,
            openableURL: "https://www.reddit.com" + post.permalink,
            pronouns: ["it", "that", "this", "post", "this post"],
            priority: 6,
            suggestedActions: [.open, .summarise, .describeMore])
    }

    private func executeShowComments() async {
        guard let post = currentActivePost() else {
            speak("I don't have an active Reddit post. Open one first.")
            return
        }
        openOverlay(.reddit)
        state.redditPendingSelectionPostId = post.id
        state.redditAutoOpenComments = true
        speak("Loading comments for that post.")
        _ = await redditStore.loadComments(for: post)
    }

    private func executeOpenInBrowser() {
        guard let post = currentActivePost() else {
            speak("I don't have an active Reddit post.")
            return
        }
        guard let url = URL(string: post.url) else {
            speak("That post doesn't have a valid link.")
            return
        }
        NSWorkspace.shared.open(url)
        speak("Opening in your browser.")
    }

    private func executeSavePost() {
        guard let post = currentActivePost() else {
            speak("I don't have an active Reddit post to save.")
            return
        }
        redditStore.toggleSaved(post)
        let saved = redditStore.savedPostIds.contains(post.id)
        speak(saved ? "Saved." : "Unsaved.")
    }

    private func executeSummarisePost() async {
        guard let post = currentActivePost() else {
            speak("I don't have an active Reddit post.")
            return
        }
        let body = post.selfText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            speak("That post has no body text — only an outbound link.")
            return
        }
        if let s = await summariseText(title: post.title, body: body, kind: .post) {
            speak(s)
        } else {
            speak("Summary unavailable — the LLM is disabled or unreachable.")
        }
    }

    private func executeSummariseComments() async {
        guard let post = currentActivePost() else {
            speak("I don't have an active Reddit post.")
            return
        }
        var comments = redditStore.commentsByPostId[post.id] ?? []
        if comments.isEmpty {
            _ = await redditStore.loadComments(for: post)
            comments = redditStore.commentsByPostId[post.id] ?? []
        }
        guard !comments.isEmpty else {
            speak("No comments to summarise.")
            return
        }
        let joined = comments.prefix(40).map {
            "[\($0.score)] u/\($0.author): \($0.body)"
        }.joined(separator: "\n")
        if let s = await summariseText(title: "Comments on: \(post.title)", body: joined, kind: .comments) {
            speak(s)
        } else {
            speak("Summary unavailable — the LLM is disabled or unreachable.")
        }
    }

    private func currentActivePost() -> RedditPost? {
        if let id = state.redditPendingSelectionPostId,
           let p = redditStore.posts.first(where: { $0.id == id }) {
            return p
        }
        if let ext = ActiveContextRegistry.shared.mostRecent?.externalIdentifier,
           let p = redditStore.posts.first(where: { $0.id == ext }) {
            return p
        }
        return redditStore.posts.first
    }

    func summariseText(title: String, body: String, kind: SummaryKind) async -> String? {
        guard llmRouter.mode != .disabled else { return nil }
        let systemPrompt: String
        switch kind {
        case .post:
            systemPrompt = """
            You are Jarvis. Summarise a Reddit post in 2–3 spoken sentences.
            No bullets. Under 60 words. Focus on what the post is asking or
            claiming, not meta-commentary.
            """
        case .comments:
            systemPrompt = """
            You are Jarvis. Summarise the dominant themes and disagreements in
            this Reddit comment thread in 2–3 spoken sentences. No bullets.
            Under 70 words. Quote a notable user opinion only when one cleanly
            captures the consensus.
            """
        }
        let req = LLMRequest(
            systemPrompt: systemPrompt,
            userPrompt:   "Title: \(title)\n\n\(body)",
            contextSummary: nil,
            temperature:  0.4,
            maxTokens:    220,
            responseFormat: .text,
            timeoutSeconds: 25)
        do {
            let r = try await llmRouter.complete(req)
            state.llmProviderUsed = r.providerID
            state.llmModelUsed    = r.model
            state.llmLatencyMs    = r.latencyMs
            state.llmLastError    = nil
            return r.text
        } catch {
            state.redditLastError = error.localizedDescription
            state.llmLastError    = error.localizedDescription
            return nil
        }
    }
}
