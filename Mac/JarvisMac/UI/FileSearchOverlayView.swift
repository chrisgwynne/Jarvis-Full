import SwiftUI
import AppKit

/// Floating panel that surfaces Spotlight/mdfind results for a voice "find file" command.
/// Appears above the orb, animates in from below, and is dismissed by the ✕ button,
/// tapping outside, or when the user opens/reveals a file.
struct FileSearchOverlayView: View {
    let results: [MacSystemController.FileSearchResult]
    let query: String
    let systemController: MacSystemController
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().opacity(0.22)
            resultsList
        }
        .frame(width: 520,
               height: min(CGFloat(results.count) * 58 + 48, 420))
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12))
                )
        )
        .shadow(color: .black.opacity(0.5), radius: 28, y: 8)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .transition(.scale(scale: 0.92, anchor: .bottom).combined(with: .opacity))
    }

    // MARK: Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)

            Text("\(results.count) result\(results.count == 1 ? "" : "s") for \"\(query)\"")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)

            Spacer()

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: List

    private var resultsList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(Array(results.enumerated()), id: \.element.id) { idx, result in
                    FileResultRow(
                        result: result,
                        systemController: systemController,
                        onDismiss: onDismiss
                    )
                    if idx < results.count - 1 {
                        Divider()
                            .opacity(0.16)
                            .padding(.leading, 52)
                    }
                }
            }
        }
    }
}

// MARK: - File Result Row

private struct FileResultRow: View {
    let result: MacSystemController.FileSearchResult
    let systemController: MacSystemController
    var onDismiss: () -> Void

    @State private var isHovered = false
    @State private var didCopy   = false

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: iconName)
                .font(.title3)
                .foregroundStyle(result.isDirectory ? .yellow : .blue)
                .frame(width: 28, alignment: .center)
                .shadow(color: (result.isDirectory ? Color.yellow : Color.blue).opacity(0.25),
                        radius: 4)

            // Name + path
            VStack(alignment: .leading, spacing: 2) {
                Text(result.displayName)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(tidyPath(result.path))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Action buttons — visible on hover
            if isHovered {
                HStack(spacing: 5) {
                    rowButton("arrow.up.forward.app", tip: "Open") {
                        systemController.openFile(path: result.path)
                        onDismiss()
                    }
                    rowButton("folder.badge.magnifyingglass", tip: "Reveal in Finder") {
                        systemController.revealInFinder(path: result.path)
                        onDismiss()
                    }
                    rowButton(didCopy ? "checkmark" : "doc.on.clipboard", tip: "Copy path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(result.path, forType: .string)
                        didCopy = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            didCopy = false
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(isHovered ? Color.white.opacity(0.07) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture {
            systemController.openFile(path: result.path)
            onDismiss()
        }
        .animation(.easeInOut(duration: 0.13), value: isHovered)
    }

    @ViewBuilder
    private func rowButton(_ icon: String, tip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(Color.white.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(tip)
    }

    // MARK: Helpers

    private func tidyPath(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private var iconName: String {
        if result.isDirectory { return "folder.fill" }
        let ext = (result.displayName as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf":                              return "doc.richtext.fill"
        case "png", "jpg", "jpeg", "heic",
             "gif", "webp", "tiff", "bmp":      return "photo.fill"
        case "mp4", "mov", "avi", "mkv", "m4v": return "video.fill"
        case "mp3", "aac", "m4a", "wav",
             "flac", "ogg":                     return "music.note"
        case "zip", "gz", "tar", "rar",
             "7z", "bz2":                       return "archivebox.fill"
        case "swift", "py", "js", "ts",
             "sh", "rb", "go", "rs":            return "chevron.left.forwardslash.chevron.right"
        case "txt", "md", "rtf":                return "doc.text.fill"
        case "app":                             return "app.fill"
        case "xcodeproj", "xcworkspace":        return "hammer.fill"
        case "html", "css":                     return "globe"
        case "json", "yaml", "yml", "plist",
             "toml":                            return "list.bullet.rectangle"
        default:                                return "doc.fill"
        }
    }
}
