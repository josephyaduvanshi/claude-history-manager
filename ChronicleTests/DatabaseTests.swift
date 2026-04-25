import XCTest
import GRDB
@testable import Chronicle

final class DatabaseTests: XCTestCase {
    func test_inMemoryDatabase_appliesV1Migration() throws {
        let dbq = try DatabaseQueue()
        try Migrations.v1(dbq)

        try dbq.read { db in
            let sessionsExists = try Bool.fetchOne(
                db, sql: "SELECT 1 FROM sqlite_master WHERE type='table' AND name='sessions_index'"
            ) ?? false
            XCTAssertTrue(sessionsExists)

            let workspacesExists = try Bool.fetchOne(
                db, sql: "SELECT 1 FROM sqlite_master WHERE type='table' AND name='workspaces'"
            ) ?? false
            XCTAssertTrue(workspacesExists)
        }
    }

    func test_v1Migration_isIdempotent() throws {
        let dbq = try DatabaseQueue()
        try Migrations.v1(dbq)
        // Second invocation must not throw — indexes (and tables) must use IF NOT EXISTS
        try Migrations.v1(dbq)
    }

    func test_appSupportPath_returnsExpectedDirectory() {
        let url = Database.appSupportDirectory()
        XCTAssertTrue(url.path.contains("/Library/Application Support/Chronicle"))
    }

    // MARK: - v2 (transcript FTS5 + fts_state)

    func test_v2Migration_onFreshDatabase_createsFtsAndStateTables() throws {
        let dbq = try DatabaseQueue()
        try Migrations.all(dbq)

        try dbq.read { db in
            let fts = try Bool.fetchOne(
                db, sql: "SELECT 1 FROM sqlite_master WHERE type='table' AND name='transcript_fts'"
            ) ?? false
            XCTAssertTrue(fts, "transcript_fts virtual table must exist after v2")

            let state = try Bool.fetchOne(
                db, sql: "SELECT 1 FROM sqlite_master WHERE type='table' AND name='fts_state'"
            ) ?? false
            XCTAssertTrue(state, "fts_state table must exist after v2")

            // The FTS table must start empty — population is on-demand.
            let ftsRows = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_fts") ?? -1
            XCTAssertEqual(ftsRows, 0)
        }
    }

    func test_v2Migration_onV1Database_reappliesCleanly() throws {
        let dbq = try DatabaseQueue()
        try Migrations.v1(dbq)
        // Simulate upgrading an existing v1-only DB.
        try Migrations.v2(dbq)
        // Re-running v2 must be a no-op (IF NOT EXISTS everywhere).
        try Migrations.v2(dbq)
    }

    func test_allMigrations_isIdempotent() throws {
        let dbq = try DatabaseQueue()
        try Migrations.all(dbq)
        try Migrations.all(dbq)  // must not throw
    }

    func test_transcriptFts_acceptsInsertAndMatchesBody() throws {
        let dbq = try DatabaseQueue()
        try Migrations.all(dbq)

        try dbq.write { db in
            try db.execute(sql: """
                INSERT INTO transcript_fts(session_id, workspace_id, title, body)
                VALUES ('sid', 'wsp', 'A title about stripe', 'body mentions webhook timeout')
                """)
        }
        try dbq.read { db in
            let hits = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM transcript_fts WHERE transcript_fts MATCH 'webhook'
                """) ?? 0
            XCTAssertEqual(hits, 1)
        }
    }

    // MARK: - v3 (session_terminal_overrides)

    func test_v3Migration_onFreshDatabase_createsOverridesTable() throws {
        let dbq = try DatabaseQueue()
        try Migrations.all(dbq)

        try dbq.read { db in
            let exists = try Bool.fetchOne(
                db, sql: "SELECT 1 FROM sqlite_master WHERE type='table' AND name='session_terminal_overrides'"
            ) ?? false
            XCTAssertTrue(exists, "session_terminal_overrides must exist after v3")
        }
    }

    func test_v3Migration_onV1Database_reappliesCleanly() throws {
        let dbq = try DatabaseQueue()
        try Migrations.v1(dbq)
        // Simulate upgrading a v1-only DB straight to v3 (v2 still needs to run).
        try Migrations.v2(dbq)
        try Migrations.v3(dbq)
        // Re-running v3 must be a no-op.
        try Migrations.v3(dbq)
    }

    func test_v3Migration_onV2Database_reappliesCleanly() throws {
        let dbq = try DatabaseQueue()
        try Migrations.v1(dbq)
        try Migrations.v2(dbq)
        // Now apply v3 — must add the table without disturbing v2 state.
        try Migrations.v3(dbq)
        try Migrations.v3(dbq) // idempotent
    }

    func test_sessionTerminalOverrides_acceptsInsertAndSelect() throws {
        let dbq = try DatabaseQueue()
        try Migrations.all(dbq)

        try dbq.write { db in
            try db.execute(sql: """
                INSERT INTO session_terminal_overrides (session_id, terminal_raw)
                VALUES ('11111111-1111-1111-1111-111111111111', 'ghostty')
                """)
        }
        try dbq.read { db in
            let raw = try String.fetchOne(db, sql: """
                SELECT terminal_raw FROM session_terminal_overrides
                WHERE session_id = '11111111-1111-1111-1111-111111111111'
                """)
            XCTAssertEqual(raw, "ghostty")
        }
    }

    // MARK: - v4 (user_metadata + tags + session_tags)

    func test_v4Migration_onFreshDatabase_createsAllTables() throws {
        let dbq = try DatabaseQueue()
        try Migrations.all(dbq)

        try dbq.read { db in
            for name in ["user_metadata", "tags", "session_tags"] {
                let exists = try Bool.fetchOne(
                    db, sql: "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
                    arguments: [name]
                ) ?? false
                XCTAssertTrue(exists, "\(name) must exist after v4")
            }
        }
    }

    func test_v4Migration_indexesExist() throws {
        let dbq = try DatabaseQueue()
        try Migrations.all(dbq)

        try dbq.read { db in
            for idx in [
                "idx_user_metadata_is_pinned",
                "idx_user_metadata_is_archived",
                "idx_user_metadata_is_deleted",
                "idx_session_tags_tag_id",
            ] {
                let exists = try Bool.fetchOne(
                    db, sql: "SELECT 1 FROM sqlite_master WHERE type='index' AND name=?",
                    arguments: [idx]
                ) ?? false
                XCTAssertTrue(exists, "\(idx) must exist after v4")
            }
        }
    }

    func test_v4Migration_onV1Database_reappliesCleanly() throws {
        let dbq = try DatabaseQueue()
        try Migrations.v1(dbq)
        try Migrations.v2(dbq)
        try Migrations.v3(dbq)
        try Migrations.v4(dbq)
        try Migrations.v4(dbq) // idempotent
    }

    func test_v4Migration_onV2Database_reappliesCleanly() throws {
        let dbq = try DatabaseQueue()
        try Migrations.v1(dbq)
        try Migrations.v2(dbq)
        try Migrations.v4(dbq) // skip v3 still adds user_metadata tables
        try Migrations.v4(dbq) // idempotent
    }

    func test_v4Migration_onV3Database_reappliesCleanly() throws {
        let dbq = try DatabaseQueue()
        try Migrations.v1(dbq)
        try Migrations.v2(dbq)
        try Migrations.v3(dbq)
        try Migrations.v4(dbq)
        try Migrations.v4(dbq)
    }

    func test_v4Migration_onV4Database_idempotent() throws {
        let dbq = try DatabaseQueue()
        try Migrations.all(dbq)
        try Migrations.all(dbq)
    }

    func test_tagsTable_enforcesUniqueNameCaseInsensitive() throws {
        let dbq = try DatabaseQueue()
        try Migrations.all(dbq)

        try dbq.write { db in
            try db.execute(sql: "INSERT INTO tags (name, color_hue) VALUES ('client', 250)")
        }
        do {
            try dbq.write { db in
                try db.execute(sql: "INSERT INTO tags (name, color_hue) VALUES ('CLIENT', 145)")
            }
            XCTFail("tags.name should be UNIQUE COLLATE NOCASE")
        } catch {
            // expected
        }
    }

    func test_sessionTagsForeignKey_cascadesOnTagDelete() throws {
        let dbq = try DatabaseQueue()
        try Migrations.all(dbq)

        try dbq.write { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "INSERT INTO tags (id, name, color_hue) VALUES (1, 'work', 250)")
            try db.execute(sql: """
                INSERT INTO session_tags (session_id, tag_id) VALUES ('sid-1', 1)
                """)
            try db.execute(sql: "DELETE FROM tags WHERE id = 1")
        }
        try dbq.read { db in
            let rows = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_tags") ?? -1
            XCTAssertEqual(rows, 0, "session_tags should cascade on tag delete")
        }
    }

    // MARK: - v5 (smart_folders + session_flags)

    func test_v5Migration_onFreshDatabase_createsAllTables() throws {
        let dbq = try DatabaseQueue()
        try Migrations.all(dbq)

        try dbq.read { db in
            for name in ["smart_folders", "session_flags"] {
                let exists = try Bool.fetchOne(
                    db, sql: "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
                    arguments: [name]
                ) ?? false
                XCTAssertTrue(exists, "\(name) must exist after v5")
            }
        }
    }

    func test_v5Migration_indexesExist() throws {
        let dbq = try DatabaseQueue()
        try Migrations.all(dbq)

        try dbq.read { db in
            for idx in ["idx_smart_folders_sort", "idx_session_flags_flag"] {
                let exists = try Bool.fetchOne(
                    db, sql: "SELECT 1 FROM sqlite_master WHERE type='index' AND name=?",
                    arguments: [idx]
                ) ?? false
                XCTAssertTrue(exists, "\(idx) must exist after v5")
            }
        }
    }

    func test_v5Migration_isIdempotent() throws {
        let dbq = try DatabaseQueue()
        try Migrations.all(dbq)
        try Migrations.v5(dbq)
        try Migrations.v5(dbq) // idempotent
    }

    func test_smartFolders_acceptsInsertAndSelect() throws {
        let dbq = try DatabaseQueue()
        try Migrations.all(dbq)

        try dbq.write { db in
            try db.execute(sql: """
                INSERT INTO smart_folders (name, query_json, sort_order, is_builtin)
                VALUES (?, ?, ?, ?)
                """, arguments: ["Today", #"{"kind":"today"}"#, 0, 1])
        }
        try dbq.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT name, is_builtin FROM smart_folders LIMIT 1")
            XCTAssertEqual(row?["name"] as String?, "Today")
            XCTAssertEqual(row?["is_builtin"] as Int64?, 1)
        }
    }

    func test_sessionFlags_pkComposite() throws {
        let dbq = try DatabaseQueue()
        try Migrations.all(dbq)

        try dbq.write { db in
            try db.execute(sql: "INSERT INTO session_flags (session_id, flag_name) VALUES ('sid', 'git_push')")
            // Re-inserting the same composite key must be rejected by the PK.
            do {
                try db.execute(sql: "INSERT INTO session_flags (session_id, flag_name) VALUES ('sid', 'git_push')")
                XCTFail("session_flags PK (session_id, flag_name) should prevent duplicates")
            } catch {
                // expected
            }
            // Different flag_name is allowed.
            try db.execute(sql: "INSERT INTO session_flags (session_id, flag_name) VALUES ('sid', 'errored')")
        }
        try dbq.read { db in
            let rows = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_flags WHERE session_id = 'sid'") ?? 0
            XCTAssertEqual(rows, 2)
        }
    }

    // MARK: - v8 (file_mtime TEXT → REAL round-trip)

    /// v8 round-trip: build a synthetic v7-shaped DB with `file_mtime` as
    /// legacy ISO-8601 TEXT, run only the v8 migration, then assert:
    ///   (a) the column type is now REAL,
    ///   (b) row count is preserved,
    ///   (c) the legacy ISO-8601 mtime values were converted correctly via
    ///       `(julianday - 2440587.5) * 86400` to Unix epoch seconds.
    func test_v8Migration_convertsLegacyTextMtimeToRealEpochSeconds() throws {
        let dbq = try DatabaseQueue()

        // Build a v7-shape sessions_index by hand: file_mtime DATETIME (TEXT).
        // We deliberately bypass Migrations.v1...v7 here because we want full
        // control over the column types — what matters is that the v8 rebuild
        // logic correctly interprets pre-v8 TEXT mtimes regardless of how the
        // legacy rows arrived.
        try dbq.write { db in
            try db.execute(sql: """
                CREATE TABLE workspaces (
                    id TEXT PRIMARY KEY,
                    decoded_path TEXT NOT NULL,
                    "group" TEXT NOT NULL,
                    display_name TEXT NOT NULL,
                    indexed_at DATETIME NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE TABLE sessions_index (
                    session_id TEXT PRIMARY KEY NOT NULL,
                    workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
                    title TEXT NOT NULL,
                    created_at DATETIME NOT NULL,
                    last_modified_at DATETIME NOT NULL,
                    message_count INTEGER NOT NULL,
                    token_count INTEGER NOT NULL,
                    file_size_bytes INTEGER NOT NULL DEFAULT 0,
                    file_mtime DATETIME NOT NULL,
                    total_input_tokens INTEGER NOT NULL DEFAULT 0,
                    total_output_tokens INTEGER NOT NULL DEFAULT 0,
                    model TEXT
                )
                """)
            try db.execute(sql: """
                INSERT INTO workspaces (id, decoded_path, "group", display_name, indexed_at)
                VALUES ('-w', '/w', 'g', 'w', '2026-04-22 14:00:00')
                """)

            // Two ISO-8601 TEXT mtimes with known epoch values.
            //   1970-01-02 00:00:00 UTC → 86400 seconds since epoch
            //   2026-04-22 14:00:00 UTC → 1776866400 seconds since epoch
            try db.execute(sql: """
                INSERT INTO sessions_index
                    (session_id, workspace_id, title, created_at, last_modified_at,
                     message_count, token_count, file_size_bytes, file_mtime,
                     total_input_tokens, total_output_tokens, model)
                VALUES
                    ('11111111-1111-1111-1111-111111111111', '-w', 't1',
                     '2026-04-22 14:00:00', '2026-04-22 14:00:00', 4, 100, 512,
                     '1970-01-02 00:00:00', 60, 40, 'sonnet'),
                    ('22222222-2222-2222-2222-222222222222', '-w', 't2',
                     '2026-04-22 14:00:00', '2026-04-22 14:00:00', 8, 250, 1024,
                     '2026-04-22 14:00:00', 150, 100, NULL)
                """)
        }

        // Sanity-check the pre-migration state: column type is DATETIME,
        // not REAL.
        try dbq.read { db in
            let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(sessions_index)")
            let row = cols.first { ($0["name"] as String?) == "file_mtime" }
            let type = (row?["type"] as String?) ?? ""
            XCTAssertFalse(type.uppercased().contains("REAL"),
                           "pre-v8 column type should not be REAL, got \(type)")
        }

        // Run the migration under test.
        try Migrations.v8(dbq)

        try dbq.read { db in
            // (a) column type is now REAL
            let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(sessions_index)")
            let row = cols.first { ($0["name"] as String?) == "file_mtime" }
            let type = (row?["type"] as String?) ?? ""
            XCTAssertTrue(type.uppercased().contains("REAL"),
                          "post-v8 file_mtime should be REAL, got \(type)")

            // (b) row count is preserved
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions_index") ?? -1
            XCTAssertEqual(count, 2)

            // (c) values converted correctly via julianday math
            let m1 = try Double.fetchOne(db, sql: """
                SELECT file_mtime FROM sessions_index
                WHERE session_id = '11111111-1111-1111-1111-111111111111'
                """) ?? -1
            XCTAssertEqual(m1, 86400.0, accuracy: 0.001,
                           "1970-01-02 should round-trip to 86400 epoch seconds")

            let m2 = try Double.fetchOne(db, sql: """
                SELECT file_mtime FROM sessions_index
                WHERE session_id = '22222222-2222-2222-2222-222222222222'
                """) ?? -1
            XCTAssertEqual(m2, 1776866400.0, accuracy: 0.01,
                           "2026-04-22 14:00:00 UTC should round-trip to 1776866400 epoch seconds")

            // Other columns survive unchanged.
            let r1 = try Row.fetchOne(db, sql: """
                SELECT title, message_count, token_count, file_size_bytes,
                       total_input_tokens, total_output_tokens, model
                FROM sessions_index
                WHERE session_id = '11111111-1111-1111-1111-111111111111'
                """)
            XCTAssertEqual(r1?["title"] as String?, "t1")
            XCTAssertEqual(r1?["message_count"] as Int64?, 4)
            XCTAssertEqual(r1?["token_count"] as Int64?, 100)
            XCTAssertEqual(r1?["file_size_bytes"] as Int64?, 512)
            XCTAssertEqual(r1?["total_input_tokens"] as Int64?, 60)
            XCTAssertEqual(r1?["total_output_tokens"] as Int64?, 40)
            XCTAssertEqual(r1?["model"] as String?, "sonnet")

            // The two v1 indexes are recreated on the new table.
            for idx in [
                "sessions_index_on_workspace_id_last_modified_at",
                "sessions_index_on_last_modified_at",
            ] {
                let exists = try Bool.fetchOne(
                    db, sql: "SELECT 1 FROM sqlite_master WHERE type='index' AND name=?",
                    arguments: [idx]
                ) ?? false
                XCTAssertTrue(exists, "\(idx) must be recreated after v8 table swap")
            }
        }

        // Re-running v8 must be a no-op (idempotent guard checks REAL type).
        try Migrations.v8(dbq)
        try dbq.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions_index") ?? -1
            XCTAssertEqual(count, 2, "second v8 run must not duplicate or drop rows")
        }
    }
}
