import XCTest
import GRDB
@testable import Chronicle

/// End-to-end isolation checks for the v0.2 multi-provider work.
/// Seeds rows under two providers in the same DB, switches the active
/// provider on a real `SessionsRepository`, and asserts every public
/// read returns only the active provider's rows.
final class MultiProviderScopingTests: XCTestCase {

    // MARK: - Helpers

    private func makeRepo() throws -> (SessionsRepository, DatabaseQueue) {
        let dbq = try DatabaseQueue()
        try Migrations.all(dbq)
        let repo = SessionsRepository(
            database: dbq,
            parser: JsonlParser(),
            decoder: WorkspacePathDecoder()
        )
        return (repo, dbq)
    }

    /// Insert a workspace + session row directly under the given
    /// provider. Bypasses the parser so the test can stage data without
    /// fixture jsonl files.
    private func seed(
        in dbq: DatabaseQueue,
        provider: String,
        workspaceID: String,
        sessionID: String,
        title: String
    ) throws {
        try dbq.write { db in
            try db.execute(sql: """
                INSERT INTO workspaces
                    (id, decoded_path, "group", display_name, indexed_at, provider)
                VALUES (?, ?, 'g', ?, '2026-04-26', ?)
                ON CONFLICT(id) DO UPDATE SET provider = excluded.provider
                """, arguments: [workspaceID, "/p/\(workspaceID)", workspaceID, provider])
            try db.execute(sql: """
                INSERT INTO sessions_index
                    (session_id, workspace_id, title, created_at, last_modified_at,
                     message_count, token_count, file_size_bytes, file_mtime,
                     total_input_tokens, total_output_tokens, model, provider)
                VALUES (?, ?, ?, '2026-04-26', '2026-04-26', 1, 100, 100, 1700000000.0, 50, 50, 'm', ?)
                """, arguments: [sessionID, workspaceID, title, provider])
        }
    }

    // MARK: - Tests

    func test_switchingActiveProvider_returnsOnlyThatProvidersWorkspaces() async throws {
        let (repo, dbq) = try makeRepo()
        try seed(in: dbq, provider: "claude", workspaceID: "ws-claude", sessionID: "00000000-0000-4000-8000-000000000001", title: "claude-only")
        try seed(in: dbq, provider: "codex",  workspaceID: "ws-codex",  sessionID: "00000000-0000-4000-8000-000000000002", title: "codex-only")

        await repo.setActiveProvider(.claude)
        let claudeWS = try await repo.allWorkspaces()
        XCTAssertEqual(claudeWS.map(\.id), ["ws-claude"])

        await repo.setActiveProvider(.codex)
        let codexWS = try await repo.allWorkspaces()
        XCTAssertEqual(codexWS.map(\.id), ["ws-codex"])
    }

    func test_allSessions_isProviderScoped() async throws {
        let (repo, dbq) = try makeRepo()
        try seed(in: dbq, provider: "claude", workspaceID: "w1", sessionID: "00000000-0000-4000-8000-00000000aaaa", title: "claude-session")
        try seed(in: dbq, provider: "codex",  workspaceID: "w2", sessionID: "00000000-0000-4000-8000-00000000bbbb", title: "codex-session")
        try seed(in: dbq, provider: "gemini", workspaceID: "w3", sessionID: "00000000-0000-4000-8000-00000000cccc", title: "gemini-session")

        await repo.setActiveProvider(.gemini)
        let gemini = try await repo.allSessions()
        XCTAssertEqual(gemini.count, 1)
        XCTAssertEqual(gemini.first?.title, "gemini-session")

        await repo.setActiveProvider(.claude)
        let claude = try await repo.allSessions()
        XCTAssertEqual(claude.count, 1)
        XCTAssertEqual(claude.first?.title, "claude-session")
    }

    /// Regression: `SessionMetadata` must carry both `provider` and
    /// `filePath` so the transcript view + preview-stats loader can route
    /// to the right parser without a side-trip to the DB. When this
    /// regressed, "Open as transcript" on a Codex / Gemini session showed
    /// `The file "<sid>.jsonl" couldn't be opened because there is no
    /// such file.` because the call fell back to the Claude
    /// canonical-path overload.
    func test_sessionMetadata_carriesProviderAndFilePath() async throws {
        let (repo, dbq) = try makeRepo()
        // Claude row — file_path NULL is fine, transcript loads via the
        // canonical projectsRoot path.
        try seed(in: dbq, provider: "claude", workspaceID: "w-claude",
                 sessionID: "00000000-0000-4000-8000-0000000c1aa1", title: "claude-row")
        // Codex row — must round-trip the absolute file_path.
        let codexFilePath = "/tmp/chronicle-tests/rollout-codex.jsonl"
        try await dbq.write { db in
            try db.execute(sql: """
                INSERT INTO workspaces (id, decoded_path, "group", display_name, indexed_at, provider)
                VALUES (?, ?, 'g', ?, '2026-04-26', 'codex')
                ON CONFLICT(id) DO NOTHING
                """, arguments: ["w-codex", "/p/codex", "w-codex"])
            try db.execute(sql: """
                INSERT INTO sessions_index
                    (session_id, workspace_id, title, created_at, last_modified_at,
                     message_count, token_count, file_size_bytes, file_mtime,
                     total_input_tokens, total_output_tokens, model, provider, file_path)
                VALUES (?, 'w-codex', 'codex-row', '2026-04-26', '2026-04-26',
                        1, 100, 100, 1700000000.0, 50, 50, 'm', 'codex', ?)
                """, arguments: ["00000000-0000-4000-8000-0000000c0dec", codexFilePath])
        }

        await repo.setActiveProvider(.claude)
        let claudeRows = try await repo.allSessions()
        XCTAssertEqual(claudeRows.count, 1)
        XCTAssertEqual(claudeRows.first?.provider, .claude)
        // Claude rows may legitimately have `file_path = nil`; just
        // confirm the field round-trips.
        XCTAssertNil(claudeRows.first?.filePath)

        await repo.setActiveProvider(.codex)
        let codexRows = try await repo.allSessions()
        XCTAssertEqual(codexRows.count, 1)
        XCTAssertEqual(codexRows.first?.provider, .codex)
        XCTAssertEqual(codexRows.first?.filePath, codexFilePath,
                       "Codex sessions must carry the absolute file_path so the transcript view can route to CodexTranscriptParser")
    }

    func test_totalSessionCount_isProviderScoped() async throws {
        let (repo, dbq) = try makeRepo()
        try seed(in: dbq, provider: "claude", workspaceID: "w1", sessionID: "00000000-0000-4000-8000-000000001111", title: "x")
        try seed(in: dbq, provider: "claude", workspaceID: "w1", sessionID: "00000000-0000-4000-8000-000000002222", title: "y")
        try seed(in: dbq, provider: "codex",  workspaceID: "w2", sessionID: "00000000-0000-4000-8000-000000003333", title: "z")

        await repo.setActiveProvider(.claude)
        let claudeCount = try await repo.totalSessionCount()
        XCTAssertEqual(claudeCount, 2)

        await repo.setActiveProvider(.codex)
        let codexCount = try await repo.totalSessionCount()
        XCTAssertEqual(codexCount, 1)
    }

    func test_sessionCountLast_takesExplicitProvider() async throws {
        let (repo, dbq) = try makeRepo()
        try await dbq.write { db in
            // Two Claude sessions modified within the last day, three
            // Codex sessions modified within the last day.
            let recent = Date().timeIntervalSince1970
            for i in 0..<2 {
                try db.execute(sql: """
                    INSERT INTO workspaces (id, decoded_path, "group", display_name, indexed_at, provider)
                    VALUES (?, ?, 'g', ?, ?, 'claude')
                    ON CONFLICT(id) DO NOTHING
                    """, arguments: ["ws-claude", "/c", "ws-claude", Date()])
                let sid = String(format: "00000000-0000-4000-8000-0000000C0000%X", i + 1)
                try db.execute(sql: """
                    INSERT INTO sessions_index
                        (session_id, workspace_id, title, created_at, last_modified_at,
                         message_count, token_count, file_size_bytes, file_mtime,
                         total_input_tokens, total_output_tokens, model, provider)
                    VALUES (?, 'ws-claude', 't', ?, ?, 1, 0, 0, ?, 0, 0, NULL, 'claude')
                    """, arguments: [sid, Date(), Date(), recent])
            }
            for i in 0..<3 {
                try db.execute(sql: """
                    INSERT INTO workspaces (id, decoded_path, "group", display_name, indexed_at, provider)
                    VALUES (?, ?, 'g', ?, ?, 'codex')
                    ON CONFLICT(id) DO NOTHING
                    """, arguments: ["ws-codex", "/x", "ws-codex", Date()])
                let sid = String(format: "00000000-0000-4000-8000-0000000F0000%X", i + 1)
                try db.execute(sql: """
                    INSERT INTO sessions_index
                        (session_id, workspace_id, title, created_at, last_modified_at,
                         message_count, token_count, file_size_bytes, file_mtime,
                         total_input_tokens, total_output_tokens, model, provider)
                    VALUES (?, 'ws-codex', 't', ?, ?, 1, 0, 0, ?, 0, 0, NULL, 'codex')
                    """, arguments: [sid, Date(), Date(), recent])
            }
        }

        let claude7d = try await repo.sessionCountLast(days: 7, provider: .claude)
        let codex7d  = try await repo.sessionCountLast(days: 7, provider: .codex)
        let gemini7d = try await repo.sessionCountLast(days: 7, provider: .gemini)
        XCTAssertEqual(claude7d, 2)
        XCTAssertEqual(codex7d, 3)
        XCTAssertEqual(gemini7d, 0)
    }

    func test_providerID_iconSymbolAndDisplayNameAreStable() {
        XCTAssertEqual(ProviderID.claude.iconSymbol, "sparkle")
        XCTAssertEqual(ProviderID.codex.iconSymbol, "hexagon")
        XCTAssertEqual(ProviderID.gemini.iconSymbol, "diamond")

        XCTAssertEqual(ProviderID.claude.displayName, "Claude")
        XCTAssertEqual(ProviderID.codex.displayName, "Codex")
        XCTAssertEqual(ProviderID.gemini.displayName, "Gemini")
    }

    /// Two-layer defence against cross-provider metadata bleed.
    ///
    /// The spec calls for "composite unique constraints replace plain
    /// session_id PKs"; the v9 migration takes the pragmatic
    /// interpretation: keep the existing session_id PRIMARY KEY (so
    /// session_ids are globally unique across the DB) and add a
    /// composite (provider, session_id) UNIQUE INDEX. UUIDs are 122
    /// bits of randomness, so a real cross-provider collision is
    /// astronomically unlikely.
    ///
    /// The schema constraint is one defence; the JOIN-clause fix in
    /// every read query (`AND u.provider = s.provider`) is the other.
    /// Either alone is sufficient; both together is belt-and-braces.
    /// This test verifies the schema-side guarantee — attempting to
    /// insert two `sessions_index` rows with the same session_id but
    /// different providers must fail at INSERT time.
    func test_sessionsIndexEnforcesGlobalSessionIDUniqueness() async throws {
        let (_, dbq) = try makeRepo()
        let collidingID = "00000000-0000-4000-8000-bbbbbbbbbbbb"

        // First insert under Claude succeeds.
        try seed(in: dbq, provider: "claude", workspaceID: "w-claude",
                 sessionID: collidingID, title: "claude-row")

        // Second insert under Codex with the same session_id must
        // fail because session_id is the table-level PK, not just
        // a column. Gives the JOIN-side fix room to be defensive
        // future-proofing without ever firing in practice.
        XCTAssertThrowsError(
            try seed(in: dbq, provider: "codex", workspaceID: "w-codex",
                     sessionID: collidingID, title: "codex-row"),
            "Same session_id under a different provider must violate the PK"
        )
    }

    /// Independent of the schema: every read-side LEFT JOIN to
    /// user_metadata now requires `AND u.provider = s.provider`
    /// (or `AND u.provider = st.provider` for the tags-driven join).
    /// This test inserts a sessions_index row under one provider and
    /// a user_metadata row under a DIFFERENT provider sharing the
    /// same session_id — which the schema permits because
    /// user_metadata's PK is session_id alone, but the row was
    /// originally written by a different provider's upsert. Without
    /// the JOIN-side fix, the metadata would leak in. With it,
    /// allSessions sees default-empty metadata.
    func test_crossProviderUserMetadataDoesNotLeakViaJoin() async throws {
        let (repo, dbq) = try makeRepo()
        let sid = "00000000-0000-4000-8000-cccccccccccc"
        // Codex sessions_index row, no metadata of its own.
        try seed(in: dbq, provider: "codex", workspaceID: "w-codex",
                 sessionID: sid, title: "codex-fresh")

        // Hand-write a user_metadata row tagged for a *different*
        // provider but sharing the session_id. This simulates the
        // hypothetical state Gemini's review flagged.
        try await dbq.write { db in
            try db.execute(sql: """
                INSERT INTO user_metadata
                    (session_id, is_pinned, is_archived, is_deleted, deleted_at,
                     custom_title, note, updated_at, provider)
                VALUES (?, 0, 1, 0, NULL, 'leaked-claude-title', NULL, ?, 'claude')
                """, arguments: [sid,
                                 Int64(Date().timeIntervalSince1970)])
        }

        await repo.setActiveProvider(.codex)
        let codex = try await repo.allSessions()
        XCTAssertEqual(codex.count, 1,
                       "Codex row must surface despite Claude metadata existing for the same session_id")
        XCTAssertEqual(codex.first?.title, "codex-fresh",
                       "JOIN must NOT pull the Claude custom_title across providers")
    }

    func test_pinnedSessions_isProviderScoped() async throws {
        let (repo, dbq) = try makeRepo()
        try seed(in: dbq, provider: "claude", workspaceID: "w", sessionID: "00000000-0000-4000-8000-00000000a001", title: "claude-pin")
        try seed(in: dbq, provider: "codex",  workspaceID: "w", sessionID: "00000000-0000-4000-8000-00000000b001", title: "codex-pin")

        // Pin both via the repository — the upsert is provider-scoped
        // by the active provider.
        await repo.setActiveProvider(.claude)
        try await repo.setPinned(true, for: try SessionID(string: "00000000-0000-4000-8000-00000000a001"))

        await repo.setActiveProvider(.codex)
        try await repo.setPinned(true, for: try SessionID(string: "00000000-0000-4000-8000-00000000b001"))

        let codexPinned = try await repo.pinnedSessions()
        XCTAssertEqual(codexPinned.map { $0.session.title }, ["codex-pin"])

        await repo.setActiveProvider(.claude)
        let claudePinned = try await repo.pinnedSessions()
        XCTAssertEqual(claudePinned.map { $0.session.title }, ["claude-pin"])
    }

    func test_incrementalReindex_codexProvider_parsesAndPersistsAsCodex() async throws {
        let (repo, dbq) = try makeRepo()
        let fixture = Bundle.module.url(
            forResource: "sample-session",
            withExtension: "jsonl",
            subdirectory: "Fixtures/Providers/codex"
        )
        XCTAssertNotNil(fixture, "Codex sample-session.jsonl fixture must be present")
        let url = fixture!

        // Step B of incrementalReindex now derives parent workspaces rows
        // from the union of caller-supplied `workspaces` and every
        // `pending.workspaceID`, so watchers can pass `workspaces: []` and
        // the per-file parse output drives parent-row discovery on its
        // own. Phase 3b's FSEvents watchers rely on this contract — they
        // can't pre-compute the right wsID without double-parsing every
        // changed file.
        try await repo.incrementalReindex(
            paths: [url],
            workspaces: [],
            removedPaths: [],
            provider: .codex
        )

        let count = try await dbq.read { db -> Int in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sessions_index WHERE provider = 'codex'"
            ) ?? 0
        }
        XCTAssertGreaterThan(count, 0,
            "incrementalReindex with provider: .codex must produce codex-tagged sessions_index rows")
    }

    func test_incrementalReindex_geminiProvider_parsesAndPersistsAsGemini() async throws {
        let (repo, dbq) = try makeRepo()
        let fixture = Bundle.module.url(
            forResource: "sample-session",
            withExtension: "json",
            subdirectory: "Fixtures/Providers/gemini"
        )
        XCTAssertNotNil(fixture, "Gemini sample-session.json fixture must be present")
        let url = fixture!

        // The Gemini incremental branch now derives the wsID as
        // `gemini:<project_dir_lastPathComponent>` (matching the bootstrap
        // path), so the wsID is deterministic from the fixture path and
        // does not depend on ~/.gemini/projects.json. Step B's union-derive
        // change picks the parent workspaces row up from the parse-derived
        // pending entries, so `workspaces: []` is sufficient.
        try await repo.incrementalReindex(
            paths: [url],
            workspaces: [],
            removedPaths: [],
            provider: .gemini
        )

        let count = try await dbq.read { db -> Int in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sessions_index WHERE provider = 'gemini'"
            ) ?? 0
        }
        XCTAssertGreaterThan(count, 0,
            "incrementalReindex with provider: .gemini must produce gemini-tagged sessions_index rows")
    }

    func test_knownFilePaths_returnsOnlyForRequestedProvider() async throws {
        let (repo, dbq) = try makeRepo()
        try seed(in: dbq, provider: "codex", workspaceID: "codex:/a", sessionID: "s1", title: "x")
        try seed(in: dbq, provider: "gemini", workspaceID: "gemini:/b", sessionID: "s2", title: "y")
        try await dbq.write { db in
            try db.execute(sql: "UPDATE sessions_index SET file_path = ? WHERE session_id = ?",
                           arguments: ["/path/to/codex/s1.jsonl", "s1"])
            try db.execute(sql: "UPDATE sessions_index SET file_path = ? WHERE session_id = ?",
                           arguments: ["/path/to/gemini/s2.json", "s2"])
        }
        let codexPaths = await repo.knownFilePaths(provider: .codex)
        let geminiPaths = await repo.knownFilePaths(provider: .gemini)
        XCTAssertEqual(codexPaths, ["/path/to/codex/s1.jsonl"])
        XCTAssertEqual(geminiPaths, ["/path/to/gemini/s2.json"])
    }

    func test_catchupCodex_indexesOnlyNewFiles() async throws {
        let (repo, dbq) = try makeRepo()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-catchup-\(UUID().uuidString)/2026/04/26", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent().deletingLastPathComponent()) }

        let f1 = tmp.appendingPathComponent("rollout-2026-04-26T10-00-00-019dc100-0000-0000-0000-000000000001.jsonl")
        let f2 = tmp.appendingPathComponent("rollout-2026-04-26T11-00-00-019dc101-0000-0000-0000-000000000002.jsonl")
        let body = #"{"type":"session_meta","timestamp":"2026-04-26T10:00:00Z","payload":{"cwd":"/tmp/p","model_provider":"openai","cli_version":"0.120"}}"# + "\n"
        try body.write(to: f1, atomically: true, encoding: .utf8)
        try body.write(to: f2, atomically: true, encoding: .utf8)

        let sessionsRoot = tmp.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

        try await repo.bootstrapCodex(sessionsRoot: sessionsRoot, progress: nil)
        let initialCount = try await dbq.read { db -> Int in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions_index WHERE provider='codex'") ?? 0
        }
        XCTAssertEqual(initialCount, 2)

        let f3 = tmp.appendingPathComponent("rollout-2026-04-26T12-00-00-019dc102-0000-0000-0000-000000000003.jsonl")
        try body.write(to: f3, atomically: true, encoding: .utf8)

        try await repo.catchupCodex(sessionsRoot: sessionsRoot)

        let finalCount = try await dbq.read { db -> Int in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions_index WHERE provider='codex'") ?? 0
        }
        XCTAssertEqual(finalCount, 3)
    }

    func test_catchupGemini_indexesOnlyNewFiles() async throws {
        let (repo, dbq) = try makeRepo()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemini-catchup-\(UUID().uuidString)", isDirectory: true)
        let projectDir = tmp.appendingPathComponent("project1")
        let chats = projectDir.appendingPathComponent("chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        func writeFixture(_ name: String, sessionId: String) throws {
            let url = chats.appendingPathComponent(name)
            let json: [String: Any] = [
                "sessionId": sessionId,
                "messages": [["type": "user", "content": "hi", "timestamp": "2026-04-25T12:00:00Z"]]
            ]
            try JSONSerialization.data(withJSONObject: json).write(to: url)
        }
        try writeFixture("session-2026-04-25T12-00-aaaaaaaa.json", sessionId: "0e6a1a77-1234-5678-90ab-aaaaaaaaaaaa")
        try writeFixture("session-2026-04-25T13-00-bbbbbbbb.json", sessionId: "0e6a1a77-1234-5678-90ab-bbbbbbbbbbbb")

        try await repo.bootstrapGemini(tmpRoot: tmp, progress: nil)
        let initial = try await dbq.read { db -> Int in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions_index WHERE provider='gemini'") ?? 0
        }
        XCTAssertEqual(initial, 2)

        try writeFixture("session-2026-04-25T14-00-cccccccc.json", sessionId: "0e6a1a77-1234-5678-90ab-cccccccccccc")
        try await repo.catchupGemini(tmpRoot: tmp)
        let final = try await dbq.read { db -> Int in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions_index WHERE provider='gemini'") ?? 0
        }
        XCTAssertEqual(final, 3)
    }
}
