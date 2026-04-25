import XCTest
import GRDB
@testable import Chronicle

/// Validates the v10 migration:
///  - Adds a nullable `file_path` column to `sessions_index`
///  - Existing rows default to NULL
///  - Idempotent on re-run
final class V10MigrationTests: XCTestCase {

    func test_v10_addsFilePathColumnToSessionsIndex() throws {
        let dbq = try DatabaseQueue()
        try Migrations.all(dbq)

        try dbq.read { db in
            let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(sessions_index)")
                .compactMap { $0["name"] as String? }
            XCTAssertTrue(
                cols.contains("file_path"),
                "sessions_index should have a `file_path` column after v10"
            )
        }
    }

    func test_v10_filePathDefaultsToNullForPreV10Rows() throws {
        let dbq = try DatabaseQueue()

        // Build a v9-shaped DB (everything before v10).
        try Migrations.v1(dbq)
        try Migrations.v2(dbq)
        try Migrations.v3(dbq)
        try Migrations.v4(dbq)
        try Migrations.v5(dbq)
        try Migrations.v6(dbq)
        try Migrations.v7(dbq)
        try Migrations.v8(dbq)
        try Migrations.v9(dbq)

        // Seed a pre-v10 row that won't mention `file_path`.
        try dbq.write { db in
            try db.execute(sql: """
                INSERT INTO workspaces
                    (id, decoded_path, "group", display_name, indexed_at,
                     cwd, git_branch, claude_version, provider)
                VALUES ('ws-A', '/Users/x/A', 'group-A', 'A', '2024-01-01',
                        '/Users/x/A', 'main', '1.0.0', 'claude')
                """)
            try db.execute(sql: """
                INSERT INTO sessions_index
                    (session_id, workspace_id, title, created_at, last_modified_at,
                     message_count, token_count, file_size_bytes, file_mtime,
                     total_input_tokens, total_output_tokens, model, provider)
                VALUES ('00000000-0000-4000-8000-000000000010', 'ws-A', 'pre-v10',
                        '2024-01-01', '2024-01-01', 5, 100, 1024, 1700000000.0,
                        50, 50, 'claude-sonnet-4', 'claude')
                """)
        }

        // Run v10.
        try Migrations.v10(dbq)

        try dbq.read { db in
            let path: String? = try String.fetchOne(
                db,
                sql: "SELECT file_path FROM sessions_index WHERE session_id = ?",
                arguments: ["00000000-0000-4000-8000-000000000010"]
            )
            XCTAssertNil(path, "Pre-v10 rows should land with NULL file_path")
        }
    }

    func test_v10_isIdempotent() throws {
        let dbq = try DatabaseQueue()
        try Migrations.all(dbq)
        // Second run is a no-op (no error, column not duplicated).
        XCTAssertNoThrow(try Migrations.v10(dbq))
        try dbq.read { db in
            let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(sessions_index)")
                .compactMap { $0["name"] as String? }
            // Column appears exactly once.
            let occurrences = cols.filter { $0 == "file_path" }.count
            XCTAssertEqual(occurrences, 1)
        }
    }

    func test_v10_acceptsAbsolutePathInsert() throws {
        let dbq = try DatabaseQueue()
        try Migrations.all(dbq)

        try dbq.write { db in
            try db.execute(sql: """
                INSERT INTO workspaces
                    (id, decoded_path, "group", display_name, indexed_at, provider)
                VALUES ('codex:cwd', '/Users/x/repo', 'group', 'repo',
                        '2026-01-01', 'codex')
                """)
            try db.execute(sql: """
                INSERT INTO sessions_index
                    (session_id, workspace_id, title, created_at, last_modified_at,
                     message_count, token_count, file_size_bytes, file_mtime,
                     total_input_tokens, total_output_tokens, model, provider, file_path)
                VALUES ('019dbf9b-c76b-7421-91aa-7a82b8705487', 'codex:cwd', 'codex',
                        '2026-04-24', '2026-04-24', 4, 2800, 100, 1700000000.0,
                        2500, 300, 'openai', 'codex',
                        '/Users/x/.codex/sessions/2026/04/24/rollout-x.jsonl')
                """)
        }

        try dbq.read { db in
            let p: String? = try String.fetchOne(
                db,
                sql: "SELECT file_path FROM sessions_index WHERE provider = 'codex'"
            )
            XCTAssertEqual(
                p,
                "/Users/x/.codex/sessions/2026/04/24/rollout-x.jsonl",
                "file_path should round-trip the absolute URL string written at index time"
            )
        }
    }
}
