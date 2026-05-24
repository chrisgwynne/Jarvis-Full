// AirDock.swift
// JarvisMac — SpatialInteraction
//
// Workspace save/restore system ("AirDock workspaces").
// Lets users save and restore named spatial configurations of their widgets,
// including overlay kinds, widget positions, dock state, and z-order.
//
// Usage:
//   let ws = AirDock.shared.save(name: "Code Session", widgetStates: states, overlayKinds: kinds)
//   AirDock.shared.activate(id: ws.id)   // callers read workspace data and restore positions

import Foundation
import CoreGraphics

// DockEdge is defined in SpatialWidgetManager.swift.

// MARK: - WorkspaceFrame

/// A CGRect serialized to Codable-friendly value types.
struct WorkspaceFrame: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    init(_ rect: CGRect) {
        x      = rect.origin.x
        y      = rect.origin.y
        width  = rect.size.width
        height = rect.size.height
    }
}

// MARK: - WorkspaceWidgetState

/// The full saved state of a single widget inside a workspace snapshot.
struct WorkspaceWidgetState: Codable {
    /// Stable ID of the widget instance (matches whatever ID the caller assigns).
    let widgetID: UUID
    /// `OverlayKind.rawValue` string — keeps AirDock decoupled from the OverlayKind enum.
    let kindRawValue: String
    /// Widget frame in screen coordinates at save time.
    let frame: WorkspaceFrame
    /// Whether the widget was collapsed/minimized.
    let isMinimized: Bool
    /// Whether the widget was snapped to a screen edge.
    let isDocked: Bool
    /// `DockEdge.rawValue` when `isDocked` is true, otherwise nil.
    let dockedEdge: String?
    /// Render ordering (higher = on top).
    let zOrder: Int
}

// MARK: - AirWorkspace

/// A named snapshot of the entire widget layout at a point in time.
struct AirWorkspace: Identifiable, Codable {
    let id: UUID
    var name: String
    /// Per-widget position/state data.
    var widgetStates: [WorkspaceWidgetState]
    /// Raw values of overlay kinds that were open when this workspace was saved.
    var activeOverlayKinds: [String]
    let createdAt: Date
    var updatedAt: Date
    /// Emoji or short label used as a visual thumbnail in the UI.
    var thumbnail: String?
}

// MARK: - AirDock

/// Manages saved workspaces: create, restore, persist, and recall named spatial configurations.
///
/// - Thread safety: `@MainActor` — all access must occur on the main actor.
/// - Persistence: JSON array written to `~/Library/Application Support/JarvisMac/airdock_workspaces.json`.
/// - Observation: Uses `@Observable` (Swift 5.9 macros) — no Combine, no `@Published`.
@MainActor
@Observable
final class AirDock {

    // MARK: Singleton

    static let shared = AirDock()

    // MARK: Observable state

    /// All saved workspaces, ordered by creation date (oldest first).
    private(set) var workspaces: [AirWorkspace] = []

    /// The ID of the currently active (restored) workspace, if any.
    private(set) var activeWorkspaceID: UUID?

    // MARK: Init

    private init() {
        loadFromDisk()
    }

    // MARK: - CRUD

    /// Create and persist a new workspace snapshot.
    ///
    /// - Parameters:
    ///   - name: Display name chosen by the user.
    ///   - widgetStates: Current per-widget state array provided by the caller.
    ///   - overlayKinds: Raw values of open `OverlayKind`s at save time.
    /// - Returns: The newly created `AirWorkspace`.
    @discardableResult
    func save(name: String,
              widgetStates: [WorkspaceWidgetState],
              overlayKinds: [String]) -> AirWorkspace {
        let now = Date()
        let workspace = AirWorkspace(
            id:                 UUID(),
            name:               name,
            widgetStates:       widgetStates,
            activeOverlayKinds: overlayKinds,
            createdAt:          now,
            updatedAt:          now,
            thumbnail:          autoThumbnail(for: name)
        )
        workspaces.append(workspace)
        saveToDisk()
        print("[AirDock] Saved workspace '\(name)' (id: \(workspace.id))")
        return workspace
    }

    /// Permanently delete a workspace by ID.
    func delete(id: UUID) {
        guard let idx = workspaces.firstIndex(where: { $0.id == id }) else { return }
        let name = workspaces[idx].name
        workspaces.remove(at: idx)
        if activeWorkspaceID == id { activeWorkspaceID = nil }
        saveToDisk()
        print("[AirDock] Deleted workspace '\(name)' (id: \(id))")
    }

    /// Rename an existing workspace.
    func rename(id: UUID, to newName: String) {
        guard let idx = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[idx].name      = newName
        workspaces[idx].updatedAt = Date()
        // Update thumbnail to reflect new name keywords.
        workspaces[idx].thumbnail = autoThumbnail(for: newName)
        saveToDisk()
        print("[AirDock] Renamed workspace \(id) → '\(newName)'")
    }

    /// Replace the widget states and overlay kinds for an existing workspace in-place.
    func update(id: UUID,
                widgetStates: [WorkspaceWidgetState],
                overlayKinds: [String]) {
        guard let idx = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[idx].widgetStates       = widgetStates
        workspaces[idx].activeOverlayKinds = overlayKinds
        workspaces[idx].updatedAt          = Date()
        saveToDisk()
        print("[AirDock] Updated workspace '\(workspaces[idx].name)' (id: \(id))")
    }

    // MARK: - Lookup

    /// Find a workspace by exact name first; falls back to fuzzy matching.
    func workspace(named query: String) -> AirWorkspace? {
        // Exact match (case-insensitive).
        if let exact = workspaces.first(where: {
            $0.name.lowercased() == query.lowercased()
        }) {
            return exact
        }
        return fuzzyMatch(query: query)
    }

    /// Find a workspace by its stable UUID.
    func workspace(id: UUID) -> AirWorkspace? {
        workspaces.first(where: { $0.id == id })
    }

    /// Fuzzy name lookup.
    ///
    /// Strategy (in order):
    /// 1. Lowercased substring — name contains query or query contains name.
    /// 2. Word-level overlap — at least one word in the query matches a word in the name.
    func fuzzyMatch(query: String) -> AirWorkspace? {
        let needle = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return nil }

        // Pass 1: substring containment.
        if let hit = workspaces.first(where: {
            let hay = $0.name.lowercased().trimmingCharacters(in: .whitespaces)
            return hay.contains(needle) || needle.contains(hay)
        }) {
            return hit
        }

        // Pass 2: word-level overlap (≥1 shared word).
        let needleWords = Set(needle.split(separator: " ").map(String.init))
        return workspaces.first(where: {
            let hayWords = Set($0.name.lowercased().split(separator: " ").map(String.init))
            return !hayWords.isDisjoint(with: needleWords)
        })
    }

    // MARK: - Activation

    /// Mark a workspace as the active one.
    ///
    /// AirDock only records which workspace is active; callers are responsible
    /// for reading the returned workspace data and restoring widget positions.
    func activate(id: UUID) {
        guard workspaces.contains(where: { $0.id == id }) else {
            print("[AirDock] activate(id:) — workspace \(id) not found")
            return
        }
        activeWorkspaceID = id
        print("[AirDock] Activated workspace \(id) ('\(workspace(id: id)?.name ?? "?")')")
    }

    /// Clear the active workspace selection without deleting anything.
    func deactivate() {
        activeWorkspaceID = nil
        print("[AirDock] Deactivated current workspace")
    }

    // MARK: - Persistence

    /// Load workspaces from disk.  Called automatically on first access via `init`.
    func loadFromDisk() {
        guard let url = storageURL else {
            print("[AirDock] Could not resolve storage URL — skipping load")
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([AirWorkspace].self, from: data)
            workspaces = decoded
            print("[AirDock] Loaded \(decoded.count) workspace(s) from disk")
        } catch {
            print("[AirDock] Load error: \(error)")
        }
    }

    /// Persist the current workspace list to disk.  Called automatically after every mutation.
    func saveToDisk() {
        guard let url = storageURL else {
            print("[AirDock] Could not resolve storage URL — skipping save")
            return
        }
        do {
            // Ensure the directory exists.
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(workspaces)
            try data.write(to: url, options: .atomic)
        } catch {
            print("[AirDock] Save error: \(error)")
        }
    }

    // MARK: - Private helpers

    /// Resolved path to `~/Library/Application Support/JarvisMac/airdock_workspaces.json`.
    private var storageURL: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("JarvisMac", isDirectory: true)
            .appendingPathComponent("airdock_workspaces.json")
    }

    /// Pick a representative emoji thumbnail based on keywords in the workspace name.
    private func autoThumbnail(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("code") || lower.contains("dev") || lower.contains("work") {
            return "💻"
        }
        if lower.contains("music") || lower.contains("spotify") {
            return "🎵"
        }
        if lower.contains("home") {
            return "🏠"
        }
        if lower.contains("news") {
            return "📰"
        }
        if lower.contains("camera") || lower.contains("surveillance") {
            return "📷"
        }
        return "🗂️"
    }
}
