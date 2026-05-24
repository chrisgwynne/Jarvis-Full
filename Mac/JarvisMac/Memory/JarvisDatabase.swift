import Foundation
import SQLite3

// SQLITE_TRANSIENT is a C macro (-1 cast to sqlite3_destructor_type) that
// isn't bridged to Swift automatically.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Thin, synchronous SQLite3 C-API wrapper. All public methods are
/// designed to be called only from the dedicated serial queue owned by
/// the store objects — never call from @MainActor.
final class JarvisDatabase {

    private var db: OpaquePointer?
    let path: String

    init(url: URL) throws {
        self.path = url.path
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw DatabaseError.open(msg)
        }
        try configure()
        try createSchema()
        // Run versioned migrations after base schema is ensured.
        DatabaseMigrator.migrate(db: db, path: path)
    }

    deinit { sqlite3_close_v2(db) }

    // MARK: - Schema

    private func configure() throws {
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA foreign_keys=ON")
        try exec("PRAGMA synchronous=NORMAL")
    }

    private func createSchema() throws {
        try exec("""
            CREATE TABLE IF NOT EXISTS conversations (
                id   INTEGER PRIMARY KEY AUTOINCREMENT,
                ts   REAL    NOT NULL,
                role TEXT    NOT NULL CHECK(role IN ('user','assistant')),
                text TEXT    NOT NULL
            )
            """)

        try exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS conversations_fts
            USING fts5(text, content=conversations, content_rowid=id)
            """)

        try exec("""
            CREATE TRIGGER IF NOT EXISTS conversations_ai
            AFTER INSERT ON conversations BEGIN
                INSERT INTO conversations_fts(rowid, text) VALUES (new.id, new.text);
            END
            """)

        try exec("""
            CREATE TABLE IF NOT EXISTS memory_entries (
                id   INTEGER PRIMARY KEY AUTOINCREMENT,
                ts   REAL    NOT NULL,
                text TEXT    NOT NULL,
                tags TEXT    NOT NULL DEFAULT ''
            )
            """)

        try exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts
            USING fts5(text, tags, content=memory_entries, content_rowid=id)
            """)

        try exec("""
            CREATE TRIGGER IF NOT EXISTS memory_ai
            AFTER INSERT ON memory_entries BEGIN
                INSERT INTO memory_fts(rowid, text, tags) VALUES (new.id, new.text, new.tags);
            END
            """)

        try exec("""
            CREATE TABLE IF NOT EXISTS context_snapshots (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                ts         REAL    NOT NULL,
                phase      TEXT    NOT NULL,
                active_app TEXT    NOT NULL DEFAULT '',
                summary    TEXT    NOT NULL
            )
            """)

        try exec("""
            CREATE INDEX IF NOT EXISTS idx_conv_ts ON conversations(ts DESC)
            """)

        try exec("""
            CREATE INDEX IF NOT EXISTS idx_mem_ts ON memory_entries(ts DESC)
            """)
    }

    // MARK: - Conversations

    func insertConversation(role: String, text: String) throws -> Int64 {
        let sql = "INSERT INTO conversations(ts, role, text) VALUES (?, ?, ?)"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
        sqlite3_bind_text(stmt, 2, role, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, text, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw stepError() }
        return sqlite3_last_insert_rowid(db)
    }

    func recentConversations(limit: Int = 50) throws -> [ConversationRow] {
        let sql = "SELECT id, ts, role, text FROM conversations ORDER BY ts DESC LIMIT ?"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        return try collectConvRows(stmt).reversed()
    }

    func searchConversations(query: String, limit: Int = 20) throws -> [ConversationRow] {
        let sql = """
            SELECT c.id, c.ts, c.role, c.text
            FROM conversations_fts
            JOIN conversations c ON conversations_fts.rowid = c.id
            WHERE conversations_fts MATCH ?
            ORDER BY rank
            LIMIT ?
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, query, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        return try collectConvRows(stmt)
    }

    // MARK: - Memory entries

    func insertMemory(text: String, tags: String = "") throws -> Int64 {
        let sql = "INSERT INTO memory_entries(ts, text, tags) VALUES (?, ?, ?)"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
        sqlite3_bind_text(stmt, 2, text, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, tags, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw stepError() }
        return sqlite3_last_insert_rowid(db)
    }

    func recentMemories(limit: Int = 100) throws -> [MemoryRow] {
        let sql = "SELECT id, ts, text, tags FROM memory_entries ORDER BY ts DESC LIMIT ?"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        return try collectMemRows(stmt)
    }

    func searchMemory(query: String, limit: Int = 20) throws -> [MemoryRow] {
        let sql = """
            SELECT m.id, m.ts, m.text, m.tags
            FROM memory_fts
            JOIN memory_entries m ON memory_fts.rowid = m.id
            WHERE memory_fts MATCH ?
            ORDER BY rank
            LIMIT ?
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, query, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        return try collectMemRows(stmt)
    }

    // MARK: - Context snapshots

    func insertSnapshot(phase: String, activeApp: String, summary: String) throws -> Int64 {
        let sql = "INSERT INTO context_snapshots(ts, phase, active_app, summary) VALUES (?, ?, ?, ?)"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
        sqlite3_bind_text(stmt, 2, phase, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, activeApp, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, summary, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw stepError() }
        return sqlite3_last_insert_rowid(db)
    }

    func recentSnapshots(limit: Int = 20) throws -> [SnapshotRow] {
        let sql = "SELECT id, ts, phase, active_app, summary FROM context_snapshots ORDER BY ts DESC LIMIT ?"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        return try collectSnapRows(stmt)
    }

    // MARK: - Extended insert methods (require migration v2 columns)

    /// Insert a conversation row with intent and session metadata (v2+).
    func insertConversationFull(role: String, text: String,
                                intent: String, sessionId: String) throws -> Int64 {
        let sql = """
            INSERT INTO conversations(ts, role, text, intent, session_id)
            VALUES (?, ?, ?, ?, ?)
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
        sqlite3_bind_text(stmt, 2, role, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, text, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, intent, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 5, sessionId, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw stepError() }
        return sqlite3_last_insert_rowid(db)
    }

    /// Insert a snapshot with full activity detail (v2+).
    func insertSnapshotFull(phase: String, activeApp: String, summary: String,
                            lastIntent: String, lastAction: String,
                            lastResponse: String, sessionId: String) throws -> Int64 {
        let sql = """
            INSERT INTO context_snapshots
                (ts, phase, active_app, summary,
                 last_intent, last_action, last_response, session_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
        sqlite3_bind_text(stmt, 2, phase, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, activeApp, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, summary, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 5, lastIntent, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 6, lastAction, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 7, lastResponse, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 8, sessionId, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw stepError() }
        return sqlite3_last_insert_rowid(db)
    }

    /// Recent snapshots with all v2 columns.
    func recentSnapshotsFull(limit: Int = 20) throws -> [SnapshotRow] {
        let sql = """
            SELECT id, ts, phase, active_app, summary,
                   last_intent, last_action, last_response, session_id
            FROM context_snapshots ORDER BY ts DESC LIMIT ?
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        return try collectSnapRowsFull(stmt)
    }

    /// Snapshots for a specific session.
    func snapshotsForSession(sessionId: String, limit: Int = 20) throws -> [SnapshotRow] {
        let sql = """
            SELECT id, ts, phase, active_app, summary,
                   last_intent, last_action, last_response, session_id
            FROM context_snapshots
            WHERE session_id = ?
            ORDER BY ts DESC LIMIT ?
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        return try collectSnapRowsFull(stmt)
    }

    // MARK: - News feeds

    func upsertNewsFeed(_ feed: NewsFeed) throws {
        let sql = """
            INSERT INTO news_feeds
                (id, name, url, category, enabled, refresh_interval_minutes,
                 source_type, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                url = excluded.url,
                category = excluded.category,
                enabled = excluded.enabled,
                refresh_interval_minutes = excluded.refresh_interval_minutes,
                source_type = excluded.source_type,
                updated_at = excluded.updated_at
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, feed.id, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, feed.name, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, feed.url, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, feed.category, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 5, feed.enabled ? 1 : 0)
        sqlite3_bind_int(stmt, 6, Int32(feed.refreshIntervalMinutes))
        sqlite3_bind_text(stmt, 7, feed.sourceType.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 8, feed.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 9, feed.updatedAt.timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw stepError() }
    }

    func allNewsFeeds() throws -> [NewsFeed] {
        let sql = """
            SELECT id, name, url, category, enabled, refresh_interval_minutes,
                   source_type, created_at, updated_at
            FROM news_feeds ORDER BY name ASC
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var feeds: [NewsFeed] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let sourceType = NewsSourceType(rawValue: safeText(stmt, 6)) ?? .rss
            feeds.append(NewsFeed(
                id: safeText(stmt, 0),
                name: safeText(stmt, 1),
                url: safeText(stmt, 2),
                category: safeText(stmt, 3),
                enabled: sqlite3_column_int(stmt, 4) != 0,
                refreshIntervalMinutes: Int(sqlite3_column_int(stmt, 5)),
                sourceType: sourceType,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8))
            ))
        }
        return feeds
    }

    func deleteNewsFeed(id: String) throws {
        let stmt = try prepare("DELETE FROM news_feeds WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw stepError() }
    }

    // MARK: - News articles

    func insertNewsArticle(_ article: NewsArticle) throws {
        let sql = """
            INSERT OR IGNORE INTO news_articles
                (id, feed_id, source_name, title, url, published_at, fetched_at,
                 summary, content_excerpt, labels, importance_score,
                 read_status, saved, ignored, dedupe_key)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        let labelsStr = article.labels.map(\.rawValue).joined(separator: ",")
        sqlite3_bind_text(stmt, 1, article.id, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, article.feedID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, article.sourceName, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, article.title, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 5, article.url, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 6, article.publishedAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 7, article.fetchedAt.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 8, article.summary, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 9, article.contentExcerpt, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 10, labelsStr, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 11, article.importanceScore)
        sqlite3_bind_int(stmt, 12, article.isRead ? 1 : 0)
        sqlite3_bind_int(stmt, 13, article.isSaved ? 1 : 0)
        sqlite3_bind_int(stmt, 14, article.isIgnored ? 1 : 0)
        sqlite3_bind_text(stmt, 15, article.dedupeKey, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw stepError() }
    }

    func updateArticleReadStatus(id: String, isRead: Bool) throws {
        let stmt = try prepare("UPDATE news_articles SET read_status = ? WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, isRead ? 1 : 0)
        sqlite3_bind_text(stmt, 2, id, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw stepError() }
    }

    func updateArticleSaved(id: String, saved: Bool) throws {
        let stmt = try prepare("UPDATE news_articles SET saved = ? WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, saved ? 1 : 0)
        sqlite3_bind_text(stmt, 2, id, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw stepError() }
    }

    func recentArticles(limit: Int = 60, feedID: String? = nil) throws -> [NewsArticle] {
        let filter = feedID != nil ? "WHERE feed_id = ?" : ""
        let sql = """
            SELECT id, feed_id, source_name, title, url, published_at, fetched_at,
                   summary, content_excerpt, labels, importance_score,
                   read_status, saved, ignored, dedupe_key
            FROM news_articles \(filter)
            ORDER BY published_at DESC LIMIT ?
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var col = 1
        if let fid = feedID {
            sqlite3_bind_text(stmt, Int32(col), fid, -1, SQLITE_TRANSIENT); col += 1
        }
        sqlite3_bind_int(stmt, Int32(col), Int32(limit))
        return collectArticleRows(stmt)
    }

    func articlesWithLabel(_ label: String, limit: Int = 40) throws -> [NewsArticle] {
        let sql = """
            SELECT id, feed_id, source_name, title, url, published_at, fetched_at,
                   summary, content_excerpt, labels, importance_score,
                   read_status, saved, ignored, dedupe_key
            FROM news_articles
            WHERE labels LIKE ?
            ORDER BY published_at DESC LIMIT ?
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, "%\(label)%", -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        return collectArticleRows(stmt)
    }

    func savedArticles(limit: Int = 100) throws -> [NewsArticle] {
        let sql = """
            SELECT id, feed_id, source_name, title, url, published_at, fetched_at,
                   summary, content_excerpt, labels, importance_score,
                   read_status, saved, ignored, dedupe_key
            FROM news_articles WHERE saved = 1
            ORDER BY published_at DESC LIMIT ?
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        return collectArticleRows(stmt)
    }

    func searchNewsArticles(query: String, limit: Int = 30) throws -> [NewsArticle] {
        let sql = """
            SELECT a.id, a.feed_id, a.source_name, a.title, a.url, a.published_at, a.fetched_at,
                   a.summary, a.content_excerpt, a.labels, a.importance_score,
                   a.read_status, a.saved, a.ignored, a.dedupe_key
            FROM news_articles_fts
            JOIN news_articles a ON news_articles_fts.rowid = a.rowid
            WHERE news_articles_fts MATCH ?
            ORDER BY rank
            LIMIT ?
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, query, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        return collectArticleRows(stmt)
    }

    private func collectArticleRows(_ stmt: OpaquePointer?) -> [NewsArticle] {
        var rows: [NewsArticle] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let labelsStr = safeText(stmt, 9)
            let labels = labelsStr.split(separator: ",")
                .compactMap { NewsLabel(rawValue: String($0)) }
            rows.append(NewsArticle(
                id: safeText(stmt, 0),
                feedID: safeText(stmt, 1),
                sourceName: safeText(stmt, 2),
                title: safeText(stmt, 3),
                url: safeText(stmt, 4),
                publishedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)),
                fetchedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6)),
                summary: safeText(stmt, 7),
                contentExcerpt: safeText(stmt, 8),
                labels: labels,
                importanceScore: sqlite3_column_double(stmt, 10),
                isRead: sqlite3_column_int(stmt, 11) != 0,
                isSaved: sqlite3_column_int(stmt, 12) != 0,
                isIgnored: sqlite3_column_int(stmt, 13) != 0,
                dedupeKey: safeText(stmt, 14)
            ))
        }
        return rows
    }

    // MARK: - Brain Memories (v4+)

    static var standardURL: URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("JarvisMac", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("jarvis.sqlite3")
    }

    func insertBrainMemory(id: String, type: String, tier: String,
                           title: String, summary: String, rawText: String,
                           source: String, confidence: Double, importance: Double,
                           createdAt: Date, updatedAt: Date, expiresAt: Date?,
                           tagsJSON: String, entityIdsJSON: String,
                           conversationId: String?, privacyLevel: String,
                           isPinned: Bool) throws {
        let sql = """
            INSERT OR REPLACE INTO brain_memories
                (id, type, tier, title, summary, raw_text, source,
                 confidence, importance, created_at, updated_at, expires_at,
                 tags_json, entity_ids_json, conversation_id, privacy_level, is_pinned)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt,  1, id,           -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt,  2, type,         -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt,  3, tier,         -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt,  4, title,        -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt,  5, summary,      -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt,  6, rawText,      -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt,  7, source,       -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt,8, confidence)
        sqlite3_bind_double(stmt,9, importance)
        sqlite3_bind_double(stmt,10, createdAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt,11, updatedAt.timeIntervalSince1970)
        if let exp = expiresAt {
            sqlite3_bind_double(stmt, 12, exp.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, 12)
        }
        sqlite3_bind_text(stmt, 13, tagsJSON,      -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 14, entityIdsJSON, -1, SQLITE_TRANSIENT)
        if let cid = conversationId {
            sqlite3_bind_text(stmt, 15, cid, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 15)
        }
        sqlite3_bind_text(stmt, 16, privacyLevel, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt,  17, isPinned ? 1 : 0)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw stepError() }
    }

    func deleteBrainMemory(id: String) throws {
        let stmt = try prepare("DELETE FROM brain_memories WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw stepError() }
    }

    func recentBrainMemories(limit: Int = 50) throws -> [BrainMemoryRow] {
        let sql = """
            SELECT id, type, tier, title, summary, raw_text, source,
                   confidence, importance, created_at, updated_at, expires_at,
                   tags_json, entity_ids_json, conversation_id, privacy_level, is_pinned
            FROM brain_memories ORDER BY created_at DESC LIMIT ?
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        return collectBrainMemoryRows(stmt)
    }

    func brainMemoriesByType(_ type: String, limit: Int = 20) throws -> [BrainMemoryRow] {
        let sql = """
            SELECT id, type, tier, title, summary, raw_text, source,
                   confidence, importance, created_at, updated_at, expires_at,
                   tags_json, entity_ids_json, conversation_id, privacy_level, is_pinned
            FROM brain_memories WHERE type = ? ORDER BY importance DESC, created_at DESC LIMIT ?
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, type, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt,  2, Int32(limit))
        return collectBrainMemoryRows(stmt)
    }

    func searchBrainMemories(query: String, limit: Int = 20) throws -> [BrainMemoryRow] {
        let sql = """
            SELECT m.id, m.type, m.tier, m.title, m.summary, m.raw_text, m.source,
                   m.confidence, m.importance, m.created_at, m.updated_at, m.expires_at,
                   m.tags_json, m.entity_ids_json, m.conversation_id, m.privacy_level, m.is_pinned
            FROM brain_memories_fts
            JOIN brain_memories m ON brain_memories_fts.rowid = m.rowid
            WHERE brain_memories_fts MATCH ?
            ORDER BY rank
            LIMIT ?
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, query, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt,  2, Int32(limit))
        return collectBrainMemoryRows(stmt)
    }

    func sweepExpiredBrainMemories() throws {
        let now = Date().timeIntervalSince1970
        try exec("DELETE FROM brain_memories WHERE expires_at IS NOT NULL AND expires_at < \(now)")
    }

    private func collectBrainMemoryRows(_ stmt: OpaquePointer?) -> [BrainMemoryRow] {
        var rows: [BrainMemoryRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let expiresRaw = sqlite3_column_type(stmt, 11) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 11))
            let convId = sqlite3_column_type(stmt, 14) == SQLITE_NULL
                ? nil
                : safeText(stmt, 14)
            rows.append(BrainMemoryRow(
                id:             safeText(stmt,  0),
                type:           safeText(stmt,  1),
                tier:           safeText(stmt,  2),
                title:          safeText(stmt,  3),
                summary:        safeText(stmt,  4),
                rawText:        safeText(stmt,  5),
                source:         safeText(stmt,  6),
                confidence:     sqlite3_column_double(stmt, 7),
                importance:     sqlite3_column_double(stmt, 8),
                createdAt:      Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9)),
                updatedAt:      Date(timeIntervalSince1970: sqlite3_column_double(stmt, 10)),
                expiresAt:      expiresRaw,
                tagsJSON:       safeText(stmt, 12),
                entityIdsJSON:  safeText(stmt, 13),
                conversationId: convId,
                privacyLevel:   safeText(stmt, 15),
                isPinned:       sqlite3_column_int(stmt, 16) != 0
            ))
        }
        return rows
    }

    // MARK: - Brain Tasks (v4+)

    func upsertBrainTask(id: String, title: String, type: String, status: String,
                         priority: Int, createdAt: Date, startedAt: Date?,
                         completedAt: Date?, error: String?,
                         retryCount: Int, maxRetries: Int,
                         payloadJSON: String, progress: Double,
                         userVisible: Bool, tagsJSON: String) throws {
        let sql = """
            INSERT OR REPLACE INTO brain_tasks
                (id, title, type, status, priority, created_at, started_at,
                 completed_at, error, retry_count, max_retries,
                 payload_json, progress, user_visible, tags_json)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt,  1, id,          -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt,  2, title,        -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt,  3, type,         -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt,  4, status,       -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt,   5, Int32(priority))
        sqlite3_bind_double(stmt,6, createdAt.timeIntervalSince1970)
        if let s = startedAt   { sqlite3_bind_double(stmt, 7, s.timeIntervalSince1970) }
        else                   { sqlite3_bind_null(stmt, 7) }
        if let c = completedAt { sqlite3_bind_double(stmt, 8, c.timeIntervalSince1970) }
        else                   { sqlite3_bind_null(stmt, 8) }
        if let e = error       { sqlite3_bind_text(stmt, 9, e, -1, SQLITE_TRANSIENT) }
        else                   { sqlite3_bind_null(stmt, 9) }
        sqlite3_bind_int(stmt,  10, Int32(retryCount))
        sqlite3_bind_int(stmt,  11, Int32(maxRetries))
        sqlite3_bind_text(stmt, 12, payloadJSON, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt,13, progress)
        sqlite3_bind_int(stmt,  14, userVisible ? 1 : 0)
        sqlite3_bind_text(stmt, 15, tagsJSON,    -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw stepError() }
    }

    func brainTasksByStatus(_ status: String, limit: Int = 100) throws -> [BrainTaskRow] {
        let sql = """
            SELECT id, title, type, status, priority, created_at, started_at,
                   completed_at, error, retry_count, max_retries,
                   payload_json, progress, user_visible, tags_json
            FROM brain_tasks WHERE status = ?
            ORDER BY priority, created_at
            LIMIT ?
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, status, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt,  2, Int32(limit))
        return collectBrainTaskRows(stmt)
    }

    func allActiveBrainTasks() throws -> [BrainTaskRow] {
        let sql = """
            SELECT id, title, type, status, priority, created_at, started_at,
                   completed_at, error, retry_count, max_retries,
                   payload_json, progress, user_visible, tags_json
            FROM brain_tasks WHERE status IN ('queued','running','paused')
            ORDER BY priority, created_at
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        return collectBrainTaskRows(stmt)
    }

    private func collectBrainTaskRows(_ stmt: OpaquePointer?) -> [BrainTaskRow] {
        var rows: [BrainTaskRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(BrainTaskRow(
                id:          safeText(stmt, 0),
                title:       safeText(stmt, 1),
                type:        safeText(stmt, 2),
                status:      safeText(stmt, 3),
                priority:    Int(sqlite3_column_int(stmt, 4)),
                createdAt:   Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)),
                startedAt:   sqlite3_column_type(stmt, 6)  == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6)),
                completedAt: sqlite3_column_type(stmt, 7)  == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7)),
                error:       sqlite3_column_type(stmt, 8)  == SQLITE_NULL ? nil : safeText(stmt, 8),
                retryCount:  Int(sqlite3_column_int(stmt, 9)),
                maxRetries:  Int(sqlite3_column_int(stmt, 10)),
                payloadJSON: safeText(stmt, 11),
                progress:    sqlite3_column_double(stmt, 12),
                userVisible: sqlite3_column_int(stmt, 13) != 0,
                tagsJSON:    safeText(stmt, 14)
            ))
        }
        return rows
    }

    // MARK: - Brain Episodes (v4+)

    func upsertBrainEpisode(id: String, title: String, startedAt: Date,
                            endedAt: Date?, summary: String,
                            memoryIdsJSON: String, entityIdsJSON: String,
                            topicsJSON: String, projectsJSON: String,
                            appsJSON: String, tagsJSON: String,
                            importance: Double, episodeType: String,
                            userInitiated: Bool) throws {
        let sql = """
            INSERT OR REPLACE INTO brain_episodes
                (id, title, started_at, ended_at, summary,
                 memory_ids_json, entity_ids_json, topics_json,
                 projects_json, apps_json, tags_json,
                 importance, episode_type, user_initiated)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt,  1, id,            -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt,  2, title,         -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt,3, startedAt.timeIntervalSince1970)
        if let e = endedAt { sqlite3_bind_double(stmt, 4, e.timeIntervalSince1970) }
        else               { sqlite3_bind_null(stmt, 4) }
        sqlite3_bind_text(stmt,  5, summary,       -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt,  6, memoryIdsJSON, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt,  7, entityIdsJSON, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt,  8, topicsJSON,    -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt,  9, projectsJSON,  -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 10, appsJSON,      -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 11, tagsJSON,      -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt,12, importance)
        sqlite3_bind_text(stmt, 13, episodeType,   -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt,  14, userInitiated ? 1 : 0)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw stepError() }
    }

    func recentBrainEpisodes(limit: Int = 20) throws -> [BrainEpisodeRow] {
        let sql = """
            SELECT id, title, started_at, ended_at, summary,
                   memory_ids_json, entity_ids_json, topics_json,
                   projects_json, apps_json, tags_json,
                   importance, episode_type, user_initiated
            FROM brain_episodes ORDER BY started_at DESC LIMIT ?
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        return collectBrainEpisodeRows(stmt)
    }

    private func collectBrainEpisodeRows(_ stmt: OpaquePointer?) -> [BrainEpisodeRow] {
        var rows: [BrainEpisodeRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(BrainEpisodeRow(
                id:            safeText(stmt, 0),
                title:         safeText(stmt, 1),
                startedAt:     Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                endedAt:       sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                summary:       safeText(stmt, 4),
                memoryIdsJSON: safeText(stmt, 5),
                entityIdsJSON: safeText(stmt, 6),
                topicsJSON:    safeText(stmt, 7),
                projectsJSON:  safeText(stmt, 8),
                appsJSON:      safeText(stmt, 9),
                tagsJSON:      safeText(stmt, 10),
                importance:    sqlite3_column_double(stmt, 11),
                episodeType:   safeText(stmt, 12),
                userInitiated: sqlite3_column_int(stmt, 13) != 0
            ))
        }
        return rows
    }

    // MARK: - Low-level helpers

    func exec(_ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errMsg) == SQLITE_OK else {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            throw DatabaseError.exec(msg)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepare(lastErrorMessage())
        }
        return stmt
    }

    private func stepError() -> DatabaseError {
        DatabaseError.step(lastErrorMessage())
    }

    private func lastErrorMessage() -> String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "no db"
    }

    private func collectConvRows(_ stmt: OpaquePointer?) throws -> [ConversationRow] {
        var rows: [ConversationRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id   = sqlite3_column_int64(stmt, 0)
            let ts   = sqlite3_column_double(stmt, 1)
            let role = String(cString: sqlite3_column_text(stmt, 2))
            let text = String(cString: sqlite3_column_text(stmt, 3))
            rows.append(ConversationRow(id: id, ts: Date(timeIntervalSince1970: ts), role: role, text: text))
        }
        return rows
    }

    private func collectMemRows(_ stmt: OpaquePointer?) throws -> [MemoryRow] {
        var rows: [MemoryRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id   = sqlite3_column_int64(stmt, 0)
            let ts   = sqlite3_column_double(stmt, 1)
            let text = String(cString: sqlite3_column_text(stmt, 2))
            let tags = String(cString: sqlite3_column_text(stmt, 3))
            rows.append(MemoryRow(id: id, ts: Date(timeIntervalSince1970: ts), text: text, tags: tags))
        }
        return rows
    }

    private func collectSnapRows(_ stmt: OpaquePointer?) throws -> [SnapshotRow] {
        var rows: [SnapshotRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(SnapshotRow(
                id: sqlite3_column_int64(stmt, 0),
                ts: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                phase: safeText(stmt, 2),
                activeApp: safeText(stmt, 3),
                summary: safeText(stmt, 4)
            ))
        }
        return rows
    }

    private func collectSnapRowsFull(_ stmt: OpaquePointer?) throws -> [SnapshotRow] {
        var rows: [SnapshotRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(SnapshotRow(
                id: sqlite3_column_int64(stmt, 0),
                ts: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                phase: safeText(stmt, 2),
                activeApp: safeText(stmt, 3),
                summary: safeText(stmt, 4),
                lastIntent: safeText(stmt, 5),
                lastAction: safeText(stmt, 6),
                lastResponse: safeText(stmt, 7),
                sessionId: safeText(stmt, 8)
            ))
        }
        return rows
    }

    /// Read a TEXT column safely, returning "" for NULL or out-of-range indices.
    private func safeText(_ stmt: OpaquePointer?, _ col: Int32) -> String {
        guard let ptr = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: ptr)
    }
}

// MARK: - Row types

struct ConversationRow {
    let id: Int64
    let ts: Date
    let role: String  // "user" | "assistant"
    let text: String
}

struct MemoryRow {
    let id: Int64
    let ts: Date
    let text: String
    let tags: String
}

struct SnapshotRow {
    let id: Int64
    let ts: Date
    let phase: String
    let activeApp: String
    let summary: String
    var lastIntent: String = ""
    var lastAction: String = ""
    var lastResponse: String = ""
    var sessionId: String = ""
}

// MARK: - Brain row types (v4+)

struct BrainMemoryRow {
    let id: String
    let type: String
    let tier: String
    let title: String
    let summary: String
    let rawText: String
    let source: String
    let confidence: Double
    let importance: Double
    let createdAt: Date
    let updatedAt: Date
    let expiresAt: Date?
    let tagsJSON: String
    let entityIdsJSON: String
    let conversationId: String?
    let privacyLevel: String
    let isPinned: Bool
}

struct BrainTaskRow {
    let id: String
    let title: String
    let type: String
    let status: String
    let priority: Int
    let createdAt: Date
    let startedAt: Date?
    let completedAt: Date?
    let error: String?
    let retryCount: Int
    let maxRetries: Int
    let payloadJSON: String
    let progress: Double
    let userVisible: Bool
    let tagsJSON: String
}

struct BrainEpisodeRow {
    let id: String
    let title: String
    let startedAt: Date
    let endedAt: Date?
    let summary: String
    let memoryIdsJSON: String
    let entityIdsJSON: String
    let topicsJSON: String
    let projectsJSON: String
    let appsJSON: String
    let tagsJSON: String
    let importance: Double
    let episodeType: String
    let userInitiated: Bool
}

// MARK: - Errors

enum DatabaseError: LocalizedError {
    case open(String)
    case exec(String)
    case prepare(String)
    case step(String)

    var errorDescription: String? {
        switch self {
        case .open(let m):    return "DB open: \(m)"
        case .exec(let m):    return "DB exec: \(m)"
        case .prepare(let m): return "DB prepare: \(m)"
        case .step(let m):    return "DB step: \(m)"
        }
    }
}
