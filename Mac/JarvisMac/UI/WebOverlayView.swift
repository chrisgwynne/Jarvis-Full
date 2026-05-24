import SwiftUI
import AppKit

/// Content view for the `.article` overlay. Renders the current article
/// URL (from AppState) in an embedded WKWebView with a minimal control
/// strip — open-in-browser button and that's it. Close X is provided by
/// the surrounding OverlayPanelView; voice users can say "close article"
/// or "close that".
struct WebOverlayContent: View {
    let state: AppState
    let controller: JarvisController

    var body: some View {
        VStack(spacing: 0) {
            // Source / title strip — kept tiny so most space goes to the page.
            if !state.currentArticleTitle.isEmpty
                || !state.currentArticleSource.isEmpty {
                HStack(spacing: 8) {
                    if !state.currentArticleSource.isEmpty {
                        Text(state.currentArticleSource.uppercased())
                            .font(.system(size: 9, weight: .semibold,
                                          design: .monospaced))
                            .tracking(1.6)
                            .foregroundStyle(.cyan.opacity(0.75))
                    }
                    Text(state.currentArticleTitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                    Spacer()
                    Button {
                        controller.openCurrentArticleInBrowser()
                    } label: {
                        Label("Browser", systemImage: "safari")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Open this article in the default browser")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color(white: 1.0, opacity: 0.04))
            }

            // The actual page.
            ArticleWebView(url: state.currentArticleURL)
                .background(Color.clear)
        }
    }
}
