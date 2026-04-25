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
}
