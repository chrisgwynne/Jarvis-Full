import Foundation
import SQLite3

/// Versioned schema migrator using SQLite's `PRAGMA user_version`.
///
/// Adding a new migration: append an entry to `migrations`. Never modify or
/// remove existing migrations — only append. Each migration is applied exactly
/// once and the version is bumped atomically inside a transaction.
///
/// Version history:
///   1 – base schema (conversations, memory_entries, context_snapshots, FTS5)
///   2 – extend conversations (intent, session_id), extend context_snapshots
///       (last_intent, last_action, last_response, session_id), add snapshots_fts
///   3 – news_feeds, news_articles, news_articles_fts
///   4 – Brain layer: brain_memories, brain_tasks, brain_episodes with FTS5
enum DatabaseMigrator {

    // MARK: - Public entry point

    /// Run all pending migrations. Called from `JarvisDatabase.init()` after
    /// the base schema is created. Failures are logged but do not prevent the
    /// app from starting — subsequent store writes may fail for missing columns,
    /// which is preferable to a hard crash.
    static func migrate(db: OpaquePointer?, path: String) {
        var version = currentVersion(db: db)

        // Legacy detection: if tables exist but user_version was never set,
        // the DB was created before the migrator was introduced (Sprint 1/2).
        // Mark it as v1 so only newer migrations run.
        if version == 0 && tablesExist(db: db) {
            setVersion(db: db, version: 1)
            version = 1
            Log.memory.info("migrator: legacy DB detected — stamped as v1")
        }

        for (targetVersion, statements) in migrations where targetVersion > version {
            Log.memory.info("migrator: applying v\(targetVersion) to \(path)")
            do {
                try apply(statements: statements, targetVersion: targetVersion, db: db)
                Log.memory.info("migrator: v\(targetVersion) complete")
            } catch {
                Log.memory.error("migrator: v\(targetVersion) failed — \(error.localizedDescription)")
                return  // stop; further migrations depend on this one
            }
        }
    }

    // MARK: - Migration definitions

    /// Ordered list of (targetVersion, SQL statements). Version 1 has no
    /// statements because the base schema is handled by JarvisDatabase via
    /// `CREATE TABLE IF NOT EXISTS`; we only need to stamp it.
    private static let migrations: [(Int32, [String])] = [
        (1, []),
        (2, v2Statements),
        (3, v3Statements),
        (4, v4Statements),
    ]

    private static let v2Statements: [String] = [
        // Extend conversations with metadata.
        "ALTER TABLE conversations ADD COLUMN intent TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE conversations ADD COLUMN session_id TEXT NOT NULL DEFAULT ''",

        // Extend context_snapshots with full activity detail.
        "ALTER TABLE context_snapshots ADD COLUMN last_intent TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE context_snapshots ADD COLUMN last_action TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE context_snapshots ADD COLUMN last_response TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE context_snapshots ADD COLUMN session_id TEXT NOT NULL DEFAULT ''",

        // FTS5 on snapshot summaries for "what was I doing earlier" queries.
        """
        CREATE VIRTUAL TABLE IF NOT EXISTS snapshots_fts
        USING fts5(summary, last_intent, last_response,
                   content=context_snapshots, content_rowid=id)
        """,

        """
        CREATE TRIGGER IF NOT EXISTS snapshots_ai
        AFTER INSERT ON context_snapshots BEGIN
            INSERT INTO snapshots_fts(rowid, summary, last_intent, last_response)
            VALUES (new.id, new.summary, new.last_intent, new.last_response);
        END
        """,

        // Prune context_snapshots to 2,000 most recent rows to prevent unbounded growth.
        """
        CREATE TRIGGER IF NOT EXISTS snapshots_prune
        AFTER INSERT ON context_snapshots
        WHEN (SELECT COUNT(*) FROM context_snapshots) > 2000
        BEGIN
            DELETE FROM context_snapshots
            WHERE id NOT IN (
                SELECT id FROM context_snapshots ORDER BY ts DESC LIMIT 2000
            );
        END
        """,
    ]

    private static let v3Statements: [String] = [
        // News feeds — one row per subscribed RSS/Atom/HN feed.
        """
        CREATE TABLE IF NOT EXISTS news_feeds (
            id                       TEXT PRIMARY KEY,
            name                     TEXT NOT NULL,
            url                      TEXT NOT NULL,
            category                 TEXT NOT NULL DEFAULT '',
            enabled                  INTEGER NOT NULL DEFAULT 1,
            refresh_interval_minutes INTEGER NOT NULL DEFAULT 30,
            source_type              TEXT NOT NULL DEFAULT 'rss',
            created_at               REAL NOT NULL,
            updated_at               REAL NOT NULL
        )
        """,

        // News articles fetched from feeds.
        """
        CREATE TABLE IF NOT EXISTS news_articles (
            id               TEXT PRIMARY KEY,
            feed_id          TEXT NOT NULL REFERENCES news_feeds(id) ON DELETE CASCADE,
            source_name      TEXT NOT NULL,
            title            TEXT NOT NULL,
            url              TEXT NOT NULL,
            published_at     REAL NOT NULL,
            fetched_at       REAL NOT NULL,
            summary          TEXT NOT NULL DEFAULT '',
            content_excerpt  TEXT NOT NULL DEFAULT '',
            labels           TEXT NOT NULL DEFAULT '',
            importance_score REAL NOT NULL DEFAULT 0.5,
            read_status      INTEGER NOT NULL DEFAULT 0,
            saved            INTEGER NOT NULL DEFAULT 0,
            ignored          INTEGER NOT NULL DEFAULT 0,
            dedupe_key       TEXT NOT NULL UNIQUE
        )
        """,

        "CREATE INDEX IF NOT EXISTS idx_articles_feed ON news_articles(feed_id)",
        "CREATE INDEX IF NOT EXISTS idx_articles_published ON news_articles(published_at DESC)",
        "CREATE INDEX IF NOT EXISTS idx_articles_saved ON news_articles(saved)",

        // FTS5 for full-text search across article fields.
        """
        CREATE VIRTUAL TABLE IF NOT EXISTS news_articles_fts
        USING fts5(title, summary, content_excerpt, labels, source_name,
                   content=news_articles, content_rowid=rowid)
        """,

        """
        CREATE TRIGGER IF NOT EXISTS news_articles_ai
        AFTER INSERT ON news_articles BEGIN
            INSERT INTO news_articles_fts(rowid, title, summary, content_excerpt, labels, source_name)
            VALUES (new.rowid, new.title, new.summary, new.content_excerpt, new.labels, new.source_name);
        END
        """,

        // Prune to 5,000 most recent articles (non-saved) to prevent unbounded growth.
        """
        CREATE TRIGGER IF NOT EXISTS news_articles_prune
        AFTER INSERT ON news_articles
        WHEN (SELECT COUNT(*) FROM news_articles WHERE saved = 0) > 5000
        BEGIN
            DELETE FROM news_articles
            WHERE saved = 0 AND id NOT IN (
                SELECT id FROM news_articles WHERE saved = 0
                ORDER BY published_at DESC LIMIT 5000
            );
        END
        """,
    ]

    // MARK: - v4 — Brain layer

    private static let v4Statements: [String] = [
        // Durable long-term memory store.
        """
        CREATE TABLE IF NOT EXISTS brain_memories (
            id               TEXT PRIMARY KEY,
            type             TEXT NOT NULL,
            tier             TEXT NOT NULL,
            title            TEXT NOT NULL,
            summary          TEXT NOT NULL DEFAULT '',
            raw_text         TEXT NOT NULL DEFAULT '',
            source           TEXT NOT NULL DEFAULT 'memoryExtractor',
            confidence       REAL NOT NULL DEFAULT 0.7,
            importance       REAL NOT NULL DEFAULT 0.5,
            created_at       REAL NOT NULL,
            updated_at       REAL NOT NULL,
            expires_at       REAL,
            tags_json        TEXT NOT NULL DEFAULT '[]',
            entity_ids_json  TEXT NOT NULL DEFAULT '[]',
            conversation_id  TEXT,
            privacy_level    TEXT NOT NULL DEFAULT 'normal',
            is_pinned        INTEGER NOT NULL DEFAULT 0
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_bm_created ON brain_memories(created_at DESC)",
        "CREATE INDEX IF NOT EXISTS idx_bm_type    ON brain_memories(type)",
        "CREATE INDEX IF NOT EXISTS idx_bm_importance ON brain_memories(importance DESC)",
        """
        CREATE VIRTUAL TABLE IF NOT EXISTS brain_memories_fts
        USING fts5(title, summary, raw_text, tags_json,
                   content=brain_memories, content_rowid=rowid)
        """,
        """
        CREATE TRIGGER IF NOT EXISTS brain_memories_ai
        AFTER INSERT ON brain_memories BEGIN
            INSERT INTO brain_memories_fts(rowid, title, summary, raw_text, tags_json)
            VALUES (new.rowid, new.title, new.summary, new.raw_text, new.tags_json);
        END
        """,

        // Durable task queue for background/overnight work.
        """
        CREATE TABLE IF NOT EXISTS brain_tasks (
            id            TEXT PRIMARY KEY,
            title         TEXT NOT NULL,
            type          TEXT NOT NULL,
            status        TEXT NOT NULL DEFAULT 'queued',
            priority      INTEGER NOT NULL DEFAULT 5,
            created_at    REAL NOT NULL,
            started_at    REAL,
            completed_at  REAL,
            error         TEXT,
            retry_count   INTEGER NOT NULL DEFAULT 0,
            max_retries   INTEGER NOT NULL DEFAULT 3,
            payload_json  TEXT NOT NULL DEFAULT '{}',
            progress      REAL NOT NULL DEFAULT 0,
            user_visible  INTEGER NOT NULL DEFAULT 0,
            tags_json     TEXT NOT NULL DEFAULT '[]'
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_bt_status   ON brain_tasks(status)",
        "CREATE INDEX IF NOT EXISTS idx_bt_priority ON brain_tasks(priority, created_at)",
        // Auto-prune completed/cancelled tasks older than 30 days.
        """
        CREATE TRIGGER IF NOT EXISTS brain_tasks_prune
        AFTER INSERT ON brain_tasks
        WHEN (SELECT COUNT(*) FROM brain_tasks WHERE status IN ('completed','cancelled')) > 500
        BEGIN
            DELETE FROM brain_tasks
            WHERE status IN ('completed','cancelled')
              AND completed_at < (strftime('%s','now') - 2592000)
              AND id NOT IN (
                SELECT id FROM brain_tasks
                WHERE status IN ('completed','cancelled')
                ORDER BY completed_at DESC LIMIT 500
              );
        END
        """,

        // Episodic memory — time-bounded activity groupings.
        """
        CREATE TABLE IF NOT EXISTS brain_episodes (
            id                TEXT PRIMARY KEY,
            title             TEXT NOT NULL,
            started_at        REAL NOT NULL,
            ended_at          REAL,
            summary           TEXT NOT NULL DEFAULT '',
            memory_ids_json   TEXT NOT NULL DEFAULT '[]',
            entity_ids_json   TEXT NOT NULL DEFAULT '[]',
            topics_json       TEXT NOT NULL DEFAULT '[]',
            projects_json     TEXT NOT NULL DEFAULT '[]',
            apps_json         TEXT NOT NULL DEFAULT '[]',
            tags_json         TEXT NOT NULL DEFAULT '[]',
            importance        REAL NOT NULL DEFAULT 0.5,
            episode_type      TEXT NOT NULL DEFAULT 'general',
            user_initiated    INTEGER NOT NULL DEFAULT 0
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_be_started ON brain_episodes(started_at DESC)",
    ]

    // MARK: - Helpers

    private static func apply(statements: [String], targetVersion: Int32, db: OpaquePointer?) throws {
        exec(db: db, sql: "BEGIN")
        for sql in statements {
            var errMsg: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
            if rc != SQLITE_OK {
                let msg = errMsg.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(errMsg)
                // "duplicate column name" means the column already exists —
                // treat this as a safe no-op (can happen if the app crashed
                // mid-migration on a previous launch).
                if msg.lowercased().contains("duplicate column") {
                    Log.memory.info("migrator: column already exists (skipping): \(msg)")
                    continue
                }
                exec(db: db, sql: "ROLLBACK")
                throw DatabaseError.exec("v\(targetVersion): \(msg)")
            }
        }
        setVersion(db: db, version: targetVersion)
        exec(db: db, sql: "COMMIT")
    }

    @discardableResult
    private static func exec(db: OpaquePointer?, sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private static func currentVersion(db: OpaquePointer?) -> Int32 {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK else {
            return 0
        }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int(stmt, 0) : 0
    }

    private static func setVersion(db: OpaquePointer?, version: Int32) {
        sqlite3_exec(db, "PRAGMA user_version = \(version)", nil, nil, nil)
    }

    private static func tablesExist(db: OpaquePointer?) -> Bool {
        var stmt: OpaquePointer?
        let sql = "SELECT name FROM sqlite_master WHERE type='table' AND name='conversations'"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW
    }
}
