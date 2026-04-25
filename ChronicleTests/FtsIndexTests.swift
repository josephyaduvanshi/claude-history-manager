import XCTest
import GRDB
@testable import Chronicle

final class FtsIndexTests: XCTestCase {
    private func fixturesRoot() -> URL {
        Bundle.module.url(forResource: "Fixtures/sample-sessions",
                          withExtension: nil)!
    }

    private func makeDB() throws -> DatabaseQueue {
        let dbq = try DatabaseQueue()
        try Migrations.all(dbq)
        return dbq
    }

    // MARK: - ensureIndexed

    func test_ensureIndexed_populatesFtsForRequestedWorkspace() async throws {
        let dbq = try makeDB()
        let index = FtsIndex(database: dbq, projectsRoot: fixturesRoot())
        try await index.ensureIndexed(workspaceIDs: ["-Users-test-flutter-app"])

        try await dbq.read { db in
            let hits = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM transcript_fts WHERE transcript_fts MATCH 'stripe'
                """) ?? 0
            XCTAssertGreaterThan(hits, 0, "body matching 'stripe' should be indexed")

            let wsOnly = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM transcript_fts WHERE workspace_id = 'wsp-other'
                """) ?? -1
            XCTAssertEqual(wsOnly, 0, "no other workspace should have been touched")
        }
    }

    func test_ensureIndexed_reportsProgressMonotonically() async throws {
        let dbq = try makeDB()
        let index = FtsIndex(database: dbq, projectsRoot: fixturesRoot())
        let progressValues: LockedArray = LockedArray()
        try await index.ensureIndexed(workspaceIDs: [
            "-Users-test-flutter-app",
            "-Users-test-rust-app",
        ]) { value in
            progressValues.append(value)
        }
        let all = progressValues.snapshot()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.last, 1.0)
        XCTAssertEqual(all, all.sorted())
    }

    func test_ensureIndexed_skipsAlreadyIndexedWorkspaces() async throws {
        let dbq = try makeDB()
        let index = FtsIndex(database: dbq, projectsRoot: fixturesRoot())

        try await index.ensureIndexed(workspaceIDs: ["-Users-test-flutter-app"])
        let before = try await dbq.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_fts WHERE workspace_id = ?",
                             arguments: ["-Users-test-flutter-app"]) ?? 0
        }
        // Second call with the same workspace should be a no-op — no duplicate rows.
        try await index.ensureIndexed(workspaceIDs: ["-Users-test-flutter-app"])
        let after = try await dbq.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_fts WHERE workspace_id = ?",
                             arguments: ["-Users-test-flutter-app"]) ?? 0
        }
        XCTAssertEqual(before, after, "already-indexed workspaces must not duplicate")
    }

    func test_ensureIndexed_forceRebuild_replacesRows() async throws {
        let dbq = try makeDB()
        let index = FtsIndex(database: dbq, projectsRoot: fixturesRoot())

        try await index.ensureIndexed(workspaceIDs: ["-Users-test-flutter-app"])
        let before = try await dbq.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_fts WHERE workspace_id = ?",
                             arguments: ["-Users-test-flutter-app"]) ?? 0
        }
        try await index.ensureIndexed(workspaceIDs: ["-Users-test-flutter-app"], forceRebuild: true)
        let after = try await dbq.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_fts WHERE workspace_id = ?",
                             arguments: ["-Users-test-flutter-app"]) ?? 0
        }
        XCTAssertEqual(before, after)
    }

    func test_ensureIndexed_writesFtsStateRow() async throws {
        let dbq = try makeDB()
        let index = FtsIndex(database: dbq, projectsRoot: fixturesRoot())
        try await index.ensureIndexed(workspaceIDs: ["-Users-test-flutter-app"])

        let exists = try await dbq.read { db in
            try Bool.fetchOne(db,
                              sql: "SELECT 1 FROM fts_state WHERE workspace_id = ?",
                              arguments: ["-Users-test-flutter-app"]) ?? false
        }
        XCTAssertTrue(exists)
    }

    func test_isIndexed_reflectsFtsStateRow() async throws {
        let dbq = try makeDB()
        let index = FtsIndex(database: dbq, projectsRoot: fixturesRoot())
        let before = await index.isIndexed(workspaceID: "-Users-test-flutter-app")
        XCTAssertFalse(before)
        try await index.ensureIndexed(workspaceIDs: ["-Users-test-flutter-app"])
        let after = await index.isIndexed(workspaceID: "-Users-test-flutter-app")
        XCTAssertTrue(after)
    }

    func test_ensureIndexed_emptyList_isNoOp() async throws {
        let dbq = try makeDB()
        let index = FtsIndex(database: dbq, projectsRoot: fixturesRoot())
        try await index.ensureIndexed(workspaceIDs: [])
        let count = try await dbq.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_fts") ?? -1
        }
        XCTAssertEqual(count, 0)
    }
}

// Tiny helper for progress-callback collection across async boundaries.
private final class LockedArray: @unchecked Sendable {
    private var values: [Double] = []
    private let lock = NSLock()

    func append(_ v: Double) {
        lock.lock(); defer { lock.unlock() }
        values.append(v)
    }
    func snapshot() -> [Double] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}
