import Foundation
import GRDB

public enum Migrations {
    /// All migrations in order. `openDefault()` runs this once at startup.
    public static func all(_ writer: any DatabaseWriter) throws {
        try v1(writer)
        try v2(writer)
        try v3(writer)
        try v4(writer)
        try v5(writer)
        try v6(writer)
        try v7(writer)
        try v8(writer)
    }

    public static func v1(_ writer: any DatabaseWriter) throws {
        try writer.write { db in
            try db.create(table: "workspaces", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("decoded_path", .text).notNull()
                t.column("group", .text).notNull()
                t.column("display_name", .text).notNull()
                t.column("indexed_at", .datetime).notNull()
            }

            try db.create(table: "sessions_index", ifNotExists: true) { t in
                t.column("session_id", .text).primaryKey()
                t.column("workspace_id", .text).notNull()
                    .references("workspaces", onDelete: .cascade)
                t.column("title", .text).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("last_modified_at", .datetime).notNull()
                t.column("message_count", .integer).notNull()
                t.column("token_count", .integer).notNull()
                t.column("file_size_bytes", .integer).notNull().defaults(to: 0)
                t.column("file_mtime", .datetime).notNull()
            }

            try db.create(indexOn: "sessions_index",
                          columns: ["workspace_id", "last_modified_at"],
                          options: .ifNotExists)
            try db.create(indexOn: "sessions_index",
                          columns: ["last_modified_at"],
                          options: .ifNotExists)
        }
    }

    /// v2 — adds the lazily-populated `transcript_fts` FTS5 virtual table plus
    /// `fts_state` (one row per workspace that's already been indexed).
    ///
    /// The FTS table starts EMPTY. `FtsIndex.ensureIndexed(...)` populates it
    /// on first `/full:` search so startup stays under a second even with
    /// thousands of jsonl files to index.
    public static func v2(_ writer: any DatabaseWriter) throws {
        try writer.write { db in
            // FTS5 virtual table. Raw SQL — GRDB's typed builder doesn't cover
            // UNINDEXED columns or the tokenize= pragma cleanly.
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS transcript_fts USING fts5(
                    session_id UNINDEXED,
                    workspace_id UNINDEXED,
                    title,
                    body,
                    tokenize = 'unicode61 remove_diacritics 2'
                )
                """)

            // One row per workspace telling us the FTS rows for that workspace
            // are already populated. Presence = "indexed at least once".
            try db.create(table: "fts_state", ifNotExists: true) { t in
                t.column("workspace_id", .text).primaryKey()
                t.column("last_indexed_at", .integer).notNull()
            }
        }
    }

    /// v3 — adds `session_terminal_overrides` so TerminalPreference can remember
    /// per-session launch-terminal choices. One row per session that diverges
    /// from the user's default terminal; absence = use default.
    public static func v3(_ writer: any DatabaseWriter) throws {
        try writer.write { db in
            try db.create(table: "session_terminal_overrides", ifNotExists: true) { t in
                t.column("session_id", .text).primaryKey()
                t.column("terminal_raw", .text).notNull()
            }
        }
    }

    /// v4 — adds user-metadata organisation features: pinning, archiving,
    /// soft-delete with Trash retention, custom titles, freeform notes,
    /// plus a tags catalogue and a session_tags join table.
    ///
    /// Nothing in this migration references `sessions_index` with a FK because
    /// user_metadata rows can exist independently of (or slightly before) a
    /// session row arriving during bootstrap — simpler to manage.
    public static func v4(_ writer: any DatabaseWriter) throws {
        try writer.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS user_metadata (
                    session_id        TEXT PRIMARY KEY NOT NULL,
                    is_pinned         INTEGER NOT NULL DEFAULT 0,
                    is_archived       INTEGER NOT NULL DEFAULT 0,
                    is_deleted        INTEGER NOT NULL DEFAULT 0,
                    deleted_at        INTEGER,
                    custom_title      TEXT,
                    note              TEXT,
                    updated_at        INTEGER NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_user_metadata_is_pinned
                    ON user_metadata(is_pinned) WHERE is_pinned = 1
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_user_metadata_is_archived
                    ON user_metadata(is_archived) WHERE is_archived = 1
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_user_metadata_is_deleted
                    ON user_metadata(is_deleted) WHERE is_deleted = 1
                """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS tags (
                    id         INTEGER PRIMARY KEY AUTOINCREMENT,
                    name       TEXT NOT NULL UNIQUE COLLATE NOCASE,
                    color_hue  INTEGER NOT NULL DEFAULT 30
                )
                """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS session_tags (
                    session_id TEXT NOT NULL,
                    tag_id     INTEGER NOT NULL,
                    PRIMARY KEY (session_id, tag_id),
                    FOREIGN KEY (tag_id) REFERENCES tags(id) ON DELETE CASCADE
                )
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_session_tags_tag_id
                    ON session_tags(tag_id)
                """)
        }
    }

    /// v5 — adds Smart Folders and per-session flags.
    ///
    /// `smart_folders` stores user-visible + built-in saved queries. Built-ins
    /// (Today / This week / Used `git push` / Errored sessions) are seeded by
    /// `SessionsRepository.ensureBuiltInSmartFolders()` on bootstrap.
    ///
    /// `session_flags` is a many-to-many set of booleans attached to a session
    /// id. Currently populated with `git_push` and `errored` by the parser
    /// during indexing. Used by smart-folder queries to avoid re-scanning the
    /// jsonl on every query.
    public static func v5(_ writer: any DatabaseWriter) throws {
        try writer.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS smart_folders (
                    id         INTEGER PRIMARY KEY AUTOINCREMENT,
                    name       TEXT NOT NULL,
                    query_json TEXT NOT NULL,
                    sort_order INTEGER NOT NULL DEFAULT 0,
                    is_builtin INTEGER NOT NULL DEFAULT 0
                )
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_smart_folders_sort
                    ON smart_folders(sort_order)
                """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS session_flags (
                    session_id TEXT NOT NULL,
                    flag_name  TEXT NOT NULL,
                    PRIMARY KEY (session_id, flag_name)
                )
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_session_flags_flag
                    ON session_flags(flag_name)
                """)
        }
    }

    /// v6 — adds the authoritative `cwd`, `git_branch`, and `claude_version`
    /// columns on the `workspaces` table. The dash-encoded folder name under
    /// `~/.claude/projects/` is lossy: Claude Code replaces `/`, ` `, `_`,
    /// `-`, and `.` all with `-`, so reverse-decoding is provably wrong for
    /// any real-world path with spaces or punctuation. The real cwd is
    /// recorded inside every jsonl line as `cwd`, so during indexing we
    /// snapshot it once per workspace and store it here. The launcher uses
    /// this column when present and falls back to `decoded_path` otherwise.
    public static func v6(_ writer: any DatabaseWriter) throws {
        try writer.write { db in
            // Add columns idempotently — older databases may already have
            // them when running on a freshly-created store. SQLite has no
            // `IF NOT EXISTS` for ALTER TABLE so we probe pragma first.
            let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(workspaces)")
                .compactMap { $0["name"] as String? }
            if !cols.contains("cwd") {
                try db.execute(sql: "ALTER TABLE workspaces ADD COLUMN cwd TEXT")
            }
            if !cols.contains("git_branch") {
                try db.execute(sql: "ALTER TABLE workspaces ADD COLUMN git_branch TEXT")
            }
            if !cols.contains("claude_version") {
                try db.execute(sql: "ALTER TABLE workspaces ADD COLUMN claude_version TEXT")
            }
        }
    }

    /// v7 — split the aggregate `token_count` on `sessions_index` into
    /// `total_input_tokens` and `total_output_tokens`. Stats was previously
    /// guessing a 50/50 split which produced visibly wrong numbers in the
    /// per-project Cost USD column. The parser now writes both halves
    /// directly so cost is calculated against real input/output volume.
    public static func v7(_ writer: any DatabaseWriter) throws {
        try writer.write { db in
            let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(sessions_index)")
                .compactMap { $0["name"] as String? }
            if !cols.contains("total_input_tokens") {
                try db.execute(sql: "ALTER TABLE sessions_index ADD COLUMN total_input_tokens INTEGER NOT NULL DEFAULT 0")
            }
            if !cols.contains("total_output_tokens") {
                try db.execute(sql: "ALTER TABLE sessions_index ADD COLUMN total_output_tokens INTEGER NOT NULL DEFAULT 0")
            }
            // Optional model-name column so per-row cost can pick the right
            // pricing tier when the parser sees the model field. Defaults
            // to NULL — falls back to blended pricing when missing.
            if !cols.contains("model") {
                try db.execute(sql: "ALTER TABLE sessions_index ADD COLUMN model TEXT")
            }
        }
    }

    /// v8 — change `file_mtime` from `.datetime` (ISO-8601 TEXT) to `REAL`
    /// (epoch seconds). The TEXT round-trip via GRDB rounds APFS's
    /// sub-millisecond mtime resolution down to whole milliseconds (and on
    /// some legacy paths to whole seconds), which forced the bootstrap cache
    /// hit to use a 1.0s tolerance — far too generous, causing a file
    /// modified within 1s of bootstrap to be a false cache hit.
    ///
    /// SQLite has no `ALTER COLUMN TYPE`, so we rebuild the table:
    ///   1. Probe the column affinity — skip the rebuild if it's already REAL
    ///      (idempotent on re-runs and a no-op on freshly-created v8+ stores).
    ///   2. Create `sessions_index_new` with the new schema.
    ///   3. Copy every row, converting the existing `file_mtime` text via
    ///      `(julianday(file_mtime) - 2440587.5) * 86400.0` → unix epoch
    ///      seconds. SQLite handles the ISO-8601 input natively.
    ///   4. Drop the old table, rename the new one, recreate the two
    ///      composite indexes that v1 created on the original table.
    public static func v8(_ writer: any DatabaseWriter) throws {
        try writer.write { db in
            // Idempotent guard: if file_mtime is already REAL, skip.
            // PRAGMA table_info returns the declared type as it was written
            // in CREATE TABLE — for REAL it'll be "REAL"; for the legacy
            // .datetime column GRDB writes "DATETIME". We do a case-insensitive
            // contains check on "real" rather than exact match to be tolerant
            // of any future GRDB type-name variations.
            let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(sessions_index)")
            let mtimeRow = cols.first { ($0["name"] as String?) == "file_mtime" }
            let declaredType = (mtimeRow?["type"] as String?) ?? ""
            if declaredType.uppercased().contains("REAL") {
                return  // already migrated — no-op
            }

            // Discover which v7 columns exist so we copy the right shape.
            // Older databases that stopped at v6 won't have total_input_tokens
            // / total_output_tokens / model — handle that by COALESCE-ing
            // through default values during the rebuild.
            let colNames: Set<String> = Set(cols.compactMap { $0["name"] as String? })
            let hasTotalIn  = colNames.contains("total_input_tokens")
            let hasTotalOut = colNames.contains("total_output_tokens")
            let hasModel    = colNames.contains("model")

            // 1. Build the new table with file_mtime REAL.
            try db.execute(sql: """
                CREATE TABLE sessions_index_new (
                    session_id TEXT PRIMARY KEY NOT NULL,
                    workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
                    title TEXT NOT NULL,
                    created_at DATETIME NOT NULL,
                    last_modified_at DATETIME NOT NULL,
                    message_count INTEGER NOT NULL,
                    token_count INTEGER NOT NULL,
                    file_size_bytes INTEGER NOT NULL DEFAULT 0,
                    file_mtime REAL NOT NULL,
                    total_input_tokens INTEGER NOT NULL DEFAULT 0,
                    total_output_tokens INTEGER NOT NULL DEFAULT 0,
                    model TEXT
                )
                """)

            // 2. Copy rows over, converting the legacy ISO-8601 TEXT
            //    `file_mtime` to a Unix epoch seconds Double.
            //    julianday() parses ISO-8601 and returns a Julian day count;
            //    subtracting the Julian day for 1970-01-01 and multiplying
            //    by 86400 yields seconds since the epoch — which is exactly
            //    what `Date(timeIntervalSince1970:)` wants on read.
            //    `COALESCE(..., 0)` defends against any malformed legacy
            //    rows where julianday() returns NULL — those become epoch
            //    zero so the cache check immediately misses and we re-parse.
            let inExpr  = hasTotalIn  ? "total_input_tokens"  : "0"
            let outExpr = hasTotalOut ? "total_output_tokens" : "0"
            let modelExpr = hasModel ? "model" : "NULL"
            try db.execute(sql: """
                INSERT INTO sessions_index_new
                    (session_id, workspace_id, title, created_at, last_modified_at,
                     message_count, token_count, file_size_bytes, file_mtime,
                     total_input_tokens, total_output_tokens, model)
                SELECT session_id, workspace_id, title, created_at, last_modified_at,
                       message_count, token_count, file_size_bytes,
                       COALESCE((julianday(file_mtime) - 2440587.5) * 86400.0, 0),
                       \(inExpr), \(outExpr), \(modelExpr)
                FROM sessions_index
                """)

            // 3. Swap.
            try db.execute(sql: "DROP TABLE sessions_index")
            try db.execute(sql: "ALTER TABLE sessions_index_new RENAME TO sessions_index")

            // 4. Recreate the v1 indexes on the new table. `IF NOT EXISTS`
            //    is defensive — after the DROP they shouldn't exist, but
            //    re-running the migration on a partially-applied DB
            //    shouldn't blow up.
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS sessions_index_on_workspace_id_last_modified_at
                ON sessions_index(workspace_id, last_modified_at)
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS sessions_index_on_last_modified_at
                ON sessions_index(last_modified_at)
                """)
        }
    }
}
