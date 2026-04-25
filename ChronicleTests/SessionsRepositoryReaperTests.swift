import XCTest
import GRDB
@testable import Chronicle

/// Stress-tests the bootstrap orphan reaper at the chunk boundary.
///
/// The reaper deletes `sessions_index` rows whose jsonl no longer exists on
/// disk, chunked at 500 IDs per DELETE to stay under SQLite's default 999-arg
/// limit. With 1500 orphans we cross the 500-row boundary three times,
/// catching off-by-one bugs in the loop bounds.
///
/// Per the implementer's deliberate spec deviation, only `sessions_index`
/// and `session_flags` rows are deleted — `user_metadata` rows survive so
/// notes/tags persist across accidental file removals.
final class SessionsRepositoryReaperTests: XCTestCase {

    /// Build a SessionsRepository with all migrations applied against a
    /// fresh in-memory DB.
    private func makeRepo() throws -> SessionsRepository {
        let dbq = try DatabaseQueue()
        try Migrations.all(dbq)
        return SessionsRepository(database: dbq, parser: JsonlParser(),
                                  decoder: WorkspacePathDecoder())
    }

    /// Create an empty workspace folder under tmp so bootstrap discovers a
    /// folder (otherwise it throws `noWorkspacesFound`) but finds no jsonl
    /// files. That triggers the reaper to compare cached vs seen and drop
    /// the orphans.
    private func makeEmptyWorkspaceRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // One empty workspace folder so bootstrap doesn't throw.
        let ws = root.appendingPathComponent("-w", isDirectory: true)
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        return root
    }

    /// Seed `sessions_index` + `session_flags` with N rows whose jsonl files
    /// don't exist anywhere on disk. Returns the list of session_ids written.
    @discardableResult
    private func seedOrphans(_ repo: SessionsRepository, count: Int, workspaceID: String) async throws -> [String] {
        let ids: [String] = (0..<count).map { i in
            // Synthesize a UUID-shaped string so SessionID parsing doesn't
            // matter for the SQL we issue here.
            String(format: "00000000-0000-0000-0000-%012d", i)
        }
        try await repo.databaseForTests.write { db in
            // Insert a workspace row so the FK on sessions_index is happy.
            try db.execute(sql: """
                INSERT OR IGNORE INTO workspaces (id, decoded_path, "group", display_name, indexed_at)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [workspaceID, "/w", "g", "w", Date()])

            for sid in ids {
                try db.execute(sql: """
                    INSERT INTO sessions_index
                        (session_id, workspace_id, title, created_at, last_modified_at,
                         message_count, token_count, file_size_bytes, file_mtime,
                         total_input_tokens, total_output_tokens, model)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        sid, workspaceID, "orphan",
                        Date(), Date(),
                        1, 10, 100,
                        Date().timeIntervalSince1970,
                        5, 5, NSNull(),
                    ])
                try db.execute(sql: """
                    INSERT INTO session_flags (session_id, flag_name) VALUES (?, ?)
                    """, arguments: [sid, "git_push"])
            }
        }
        return ids
    }

    func test_bootstrapReaper_deletes1500OrphansAcrossChunkBoundary() async throws {
        let repo = try makeRepo()
        let root = try makeEmptyWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let workspaceID = "-w"
        let orphanCount = 1500
        let ids = try await seedOrphans(repo, count: orphanCount, workspaceID: workspaceID)

        // Pick one session_id and write a user_metadata row for it. That row
        // must SURVIVE the reaper (deliberate deviation: notes/tags outlive
        // accidental file removals).
        let preservedSID = ids[750]  // mid-chunk so we cross batch boundaries
        let nowEpoch = Int(Date().timeIntervalSince1970)
        try await repo.databaseForTests.write { db in
            try db.execute(sql: """
                INSERT INTO user_metadata
                    (session_id, is_pinned, is_archived, is_deleted, deleted_at,
                     custom_title, note, updated_at)
                VALUES (?, 1, 0, 0, NULL, 'pinned note', 'survives reap', ?)
                """, arguments: [preservedSID, nowEpoch])
        }

        // Sanity: rows are present pre-bootstrap.
        let before = try await repo.databaseForTests.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions_index") ?? -1
        }
        XCTAssertEqual(before, orphanCount, "sanity: seeded rows should be present")

        // Run bootstrap against an empty workspace folder. The cachedAttrs
        // snapshot will contain all 1500 orphan ids; seenSessionIDs will be
        // empty (no jsonls); the reaper should drop every orphan.
        try await repo.bootstrap(rootURL: root)

        // (a) all 1500 sessions_index rows are gone.
        let remainingSessions = try await repo.databaseForTests.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions_index") ?? -1
        }
        XCTAssertEqual(remainingSessions, 0,
                       "all 1500 orphans must be deleted (chunked DELETE must cover every batch)")

        // (b) chunked DELETE works across the 500-row batch boundary —
        // already proven by (a) since any off-by-one would leave rows behind.
        // Spot-check three IDs at offsets 0, 500, 1000, 1499 to be extra sure.
        for offset in [0, 499, 500, 999, 1000, 1499] {
            let sid = ids[offset]
            let exists = try await repo.databaseForTests.read { db in
                try Bool.fetchOne(
                    db,
                    sql: "SELECT 1 FROM sessions_index WHERE session_id = ?",
                    arguments: [sid]
                ) ?? false
            }
            XCTAssertFalse(exists, "session at offset \(offset) (\(sid)) should be reaped")
        }

        // (b cont.) session_flags rows for orphans are also cleaned up.
        let remainingFlags = try await repo.databaseForTests.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_flags") ?? -1
        }
        XCTAssertEqual(remainingFlags, 0,
                       "session_flags rows for orphans must be deleted alongside sessions_index rows")

        // (c) user_metadata row for the preserved session_id SURVIVES the
        // reaper (deliberate deviation from spec — notes/tags outlive
        // accidental file removals).
        let metadataSurvived = try await repo.databaseForTests.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT 1 FROM user_metadata WHERE session_id = ?",
                arguments: [preservedSID]
            ) ?? false
        }
        XCTAssertTrue(metadataSurvived,
                      "user_metadata MUST survive bootstrap reap so notes/tags persist across accidental file removals")

        // The preserved metadata row's content is intact.
        let preservedNote = try await repo.databaseForTests.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT note FROM user_metadata WHERE session_id = ?",
                arguments: [preservedSID]
            )
        }
        XCTAssertEqual(preservedNote, "survives reap")
    }
}
