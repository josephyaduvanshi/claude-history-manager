import XCTest
import GRDB
@testable import Chronicle

/// Exercises the Plan 07 smart-folder repository surface: CRUD, built-in
/// seeding, counts, and the per-smart-folder session queries.
final class SmartFolderRepositoryTests: XCTestCase {
    private func makeRepo() throws -> SessionsRepository {
        let dbq = try DatabaseQueue()
        try Migrations.all(dbq)
        return SessionsRepository(database: dbq, parser: JsonlParser(),
                                  decoder: WorkspacePathDecoder())
    }

    // Helper — insert a synthetic session_index row without bootstrapping real jsonl.
    private func insertSession(into repo: SessionsRepository,
                               id: String,
                               workspace: String = "-Users-test-flutter-app",
                               lastModified: Date = Date()) async throws {
        try await repo.writeForTests { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO workspaces (id, decoded_path, "group", display_name, indexed_at)
                VALUES (?, ?, 'flutter', ?, ?)
                """, arguments: [workspace, "/Users/test/flutter-app", "flutter-app", Date()])
            try db.execute(sql: """
                INSERT OR REPLACE INTO sessions_index
                    (session_id, workspace_id, title, created_at, last_modified_at,
                     message_count, token_count, file_size_bytes, file_mtime)
                VALUES (?, ?, 'a title', ?, ?, 2, 100, 0, ?)
                """, arguments: [id, workspace, lastModified, lastModified, lastModified])
        }
    }

    private func insertFlag(into repo: SessionsRepository, sessionID: String, flag: String) async throws {
        try await repo.writeForTests { db in
            try db.execute(sql: "INSERT OR IGNORE INTO session_flags (session_id, flag_name) VALUES (?, ?)",
                           arguments: [sessionID, flag])
        }
    }

    // MARK: - Built-ins

    func test_ensureBuiltInSmartFolders_seedsAllFour() async throws {
        let repo = try makeRepo()
        try await repo.ensureBuiltInSmartFolders()
        let folders = try await repo.smartFolders()
        XCTAssertEqual(folders.count, 4)
        XCTAssertEqual(Set(folders.map(\.name)),
                       Set(["Today", "This week", "Used `git push`", "Errored sessions"]))
        XCTAssertTrue(folders.allSatisfy(\.isBuiltIn))
    }

    func test_ensureBuiltInSmartFolders_isIdempotent() async throws {
        let repo = try makeRepo()
        try await repo.ensureBuiltInSmartFolders()
        try await repo.ensureBuiltInSmartFolders()
        let folders = try await repo.smartFolders()
        XCTAssertEqual(folders.count, 4, "re-seeding must not duplicate")
    }

    // MARK: - CRUD

    func test_createSmartFolder_appendsSortOrderAtEnd() async throws {
        let repo = try makeRepo()
        try await repo.ensureBuiltInSmartFolders()
        let f = try await repo.createSmartFolder(name: "My stuff", query: .lastNDays(3))
        XCTAssertFalse(f.isBuiltIn)
        XCTAssertEqual(f.name, "My stuff")
        XCTAssertEqual(f.query, .lastNDays(3))
        let all = try await repo.smartFolders()
        XCTAssertTrue(all.last?.id == f.id, "new folder should sort to the end")
    }

    func test_createSmartFolder_rejectsEmptyName() async throws {
        let repo = try makeRepo()
        do {
            _ = try await repo.createSmartFolder(name: "   ", query: .today)
            XCTFail("expected SmartFolderError.emptyName")
        } catch SessionsRepository.SmartFolderError.emptyName {
            // expected
        }
    }

    func test_deleteSmartFolder_removesRow() async throws {
        let repo = try makeRepo()
        let f = try await repo.createSmartFolder(name: "temp", query: .today)
        try await repo.deleteSmartFolder(f.id)
        let remaining = try await repo.smartFolders()
        XCTAssertFalse(remaining.contains(where: { $0.id == f.id }))
    }

    func test_renameSmartFolder_updatesNameInPlace() async throws {
        let repo = try makeRepo()
        let f = try await repo.createSmartFolder(name: "temp", query: .today)
        try await repo.renameSmartFolder(f.id, to: "renamed")
        let row = try await repo.smartFolders().first { $0.id == f.id }
        XCTAssertEqual(row?.name, "renamed")
    }

    // MARK: - sessionsForSmartFolder

    func test_sessionsForSmartFolder_today_filtersByStartOfDay() async throws {
        let repo = try makeRepo()
        try await repo.ensureBuiltInSmartFolders()
        let today = Calendar.current.startOfDay(for: Date()).addingTimeInterval(3600) // mid-morning today
        let yesterday = today.addingTimeInterval(-48 * 3600)
        try await insertSession(into: repo, id: "11111111-1111-1111-1111-111111111111", lastModified: today)
        try await insertSession(into: repo, id: "22222222-2222-2222-2222-222222222222", lastModified: yesterday)

        let todayFolder = try await repo.smartFolders().first { $0.query == .today }!
        let rows = try await repo.sessionsForSmartFolder(todayFolder)
        XCTAssertEqual(rows.map(\.session.sessionID.description),
                       ["11111111-1111-1111-1111-111111111111"])
    }

    func test_sessionsForSmartFolder_usedGitPush_filtersByFlag() async throws {
        let repo = try makeRepo()
        try await repo.ensureBuiltInSmartFolders()
        try await insertSession(into: repo, id: "11111111-1111-1111-1111-111111111111")
        try await insertSession(into: repo, id: "22222222-2222-2222-2222-222222222222")
        try await insertFlag(into: repo, sessionID: "11111111-1111-1111-1111-111111111111", flag: "git_push")

        let folder = try await repo.smartFolders().first { $0.query == .usedGitPush }!
        let rows = try await repo.sessionsForSmartFolder(folder)
        XCTAssertEqual(rows.map(\.session.sessionID.description),
                       ["11111111-1111-1111-1111-111111111111"])
    }

    func test_sessionsForSmartFolder_erroredSessions_filtersByFlag() async throws {
        let repo = try makeRepo()
        try await repo.ensureBuiltInSmartFolders()
        try await insertSession(into: repo, id: "11111111-1111-1111-1111-111111111111")
        try await insertSession(into: repo, id: "22222222-2222-2222-2222-222222222222")
        try await insertFlag(into: repo, sessionID: "22222222-2222-2222-2222-222222222222", flag: "errored")

        let folder = try await repo.smartFolders().first { $0.query == .erroredSessions }!
        let rows = try await repo.sessionsForSmartFolder(folder)
        XCTAssertEqual(rows.map(\.session.sessionID.description),
                       ["22222222-2222-2222-2222-222222222222"])
    }

    func test_smartFolderCounts_matchesFilterSize() async throws {
        let repo = try makeRepo()
        try await repo.ensureBuiltInSmartFolders()
        try await insertSession(into: repo, id: "11111111-1111-1111-1111-111111111111",
                                lastModified: Date())
        try await insertSession(into: repo, id: "22222222-2222-2222-2222-222222222222",
                                lastModified: Date().addingTimeInterval(-100_000))
        try await insertFlag(into: repo, sessionID: "11111111-1111-1111-1111-111111111111", flag: "git_push")

        let counts = try await repo.smartFolderCounts()
        let folders = try await repo.smartFolders()
        let gitPushFolder = folders.first { $0.query == .usedGitPush }!
        XCTAssertEqual(counts[gitPushFolder.id], 1)
    }

    // MARK: - incrementalReindex

    func test_incrementalReindex_insertsNewSession_andFlags() async throws {
        let repo = try makeRepo()
        let fixtureRoot = Bundle.module.url(forResource: "Fixtures/sample-sessions",
                                            withExtension: nil)!
        let wsFolder = fixtureRoot.appendingPathComponent("-Users-test-flutter-app")
        let jsonl = wsFolder.appendingPathComponent("11111111-1111-1111-1111-111111111111.jsonl")

        let repoWithRoot = SessionsRepository(database: try DatabaseQueueFactory.makeInMemory(),
                                              parser: JsonlParser(),
                                              decoder: WorkspacePathDecoder(),
                                              projectsRoot: fixtureRoot)
        try await repoWithRoot.incrementalReindex(paths: [jsonl],
                                                  workspaces: ["-Users-test-flutter-app"],
                                                  removedPaths: [])
        let sessions = try await repoWithRoot.sessions(inWorkspaceID: "-Users-test-flutter-app")
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.title, "Add Stripe checkout to subscription flow")
    }

    func test_incrementalReindex_removedPaths_dropsRow() async throws {
        let repo = try makeRepo()
        try await insertSession(into: repo, id: "11111111-1111-1111-1111-111111111111")
        let fakeURL = URL(fileURLWithPath: "/tmp/11111111-1111-1111-1111-111111111111.jsonl")
        try await repo.incrementalReindex(paths: [],
                                           workspaces: [],
                                           removedPaths: [fakeURL])
        let sessions = try await repo.sessions(inWorkspaceID: "-Users-test-flutter-app")
        XCTAssertTrue(sessions.isEmpty)
    }

    func test_incrementalReindex_isIdempotent() async throws {
        let fixtureRoot = Bundle.module.url(forResource: "Fixtures/sample-sessions",
                                            withExtension: nil)!
        let wsFolder = fixtureRoot.appendingPathComponent("-Users-test-flutter-app")
        let jsonl = wsFolder.appendingPathComponent("11111111-1111-1111-1111-111111111111.jsonl")

        let repo = SessionsRepository(database: try DatabaseQueueFactory.makeInMemory(),
                                      parser: JsonlParser(),
                                      decoder: WorkspacePathDecoder(),
                                      projectsRoot: fixtureRoot)
        try await repo.incrementalReindex(paths: [jsonl],
                                          workspaces: ["-Users-test-flutter-app"],
                                          removedPaths: [])
        try await repo.incrementalReindex(paths: [jsonl],
                                          workspaces: ["-Users-test-flutter-app"],
                                          removedPaths: [])
        let sessions = try await repo.sessions(inWorkspaceID: "-Users-test-flutter-app")
        XCTAssertEqual(sessions.count, 1, "reapplying incrementalReindex must not duplicate")
    }
}

/// Thin helpers exposed only to the test target so we can seed fake data
/// without bootstrapping real jsonl directories.
enum DatabaseQueueFactory {
    static func makeInMemory() throws -> DatabaseQueue {
        let dbq = try DatabaseQueue()
        try Migrations.all(dbq)
        return dbq
    }
}

extension SessionsRepository {
    /// Test-only accessor. Writes through the underlying GRDB writer so test
    /// helpers can seed rows directly without round-tripping through real jsonl.
    func writeForTests(_ block: @Sendable @escaping (GRDB.Database) throws -> Void) async throws {
        try await databaseForTests.write(block)
    }
}
