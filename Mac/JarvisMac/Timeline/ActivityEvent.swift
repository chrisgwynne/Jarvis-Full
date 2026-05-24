import Foundation

/// A single timestamped entry in the activity timeline.
/// Kept compact — no raw screenshots or large blobs.
struct ActivityEvent: Identifiable, Codable, Equatable {
    let id: UUID
    let timestamp: Date
    let kind: ActivityEventKind
    let title: String
    let detail: String?   // optional secondary line, max ~100 chars
    let appName: String?  // active app at event time

    init(kind: ActivityEventKind,
         title: String,
         detail: String? = nil,
         appName: String? = nil,
         timestamp: Date = Date()) {
        self.id = UUID()
        self.timestamp = timestamp
        self.kind = kind
        self.title = title
        self.detail = detail.map { String($0.prefix(120)) }
        self.appName = appName
    }

    // Bridge from the existing lightweight TimelineEvent used in AppState
    init(from event: TimelineEvent, kind: ActivityEventKind, appName: String? = nil) {
        self.id = UUID()
        self.timestamp = event.timestamp
        self.kind = kind
        self.title = event.title
        self.detail = event.detail
        self.appName = appName
    }
}
