import XCTest
import GRDB
@testable import Chronicle

final class SessionsRepositorySearchTests: XCTestCase {
    private func fixturesRoot() -> URL {
        Bundle.module.url(forResource: "Fixtures/sample-sessions",
                          withExtension: nil)!
    }

    private func makeRepo(withFts: Bool = false) throws -> (SessionsRepository, DatabaseQueue) {
        let dbq = try DatabaseQueue()
        try Migrations.all(dbq)
        let fts: FtsIndex? = withFts ? FtsIndex(database: dbq, projectsRoot: fixturesRoot()) : nil
        let repo = SessionsRepository(database: dbq,
                                      parser: JsonlParser(),
                                      decoder: WorkspacePathDecoder(),
                                      ftsIndex: fts)
        return (repo, dbq)
    }

    // MARK: - empty

    func test_search_emptyQuery_returnsAllRecentSessions() async throws {
        let (repo, _) = try makeRepo()
        try await repo.bootstrap(rootURL: fixturesRoot())

        let results = try await repo.search(query: SearchQuery())
        XCTAssertEqual(results.count, 2, "empty query returns everything across all workspaces")
    }

    func test_allSessions_returnsOrderedByLastModified() async throws {
        let (repo, _) = try makeRepo()
        try await repo.bootstrap(rootURL: fixturesRoot())
        let results = try await repo.allSessions(limit: 500)
        XCTAssertEqual(results.count, 2)
        // Rust session has newer timestamp than flutter.
        XCTAssertEqual(results.first?.workspaceID, "-Users-test-rust-app")
    }

    // MARK: - titleText LIKE

    func test_search_titleText_matchesCaseInsensitively() async throws {
        let (repo, _) = try makeRepo()
        try await repo.bootstrap(rootURL: fixturesRoot())

        let q = SearchQueryParser.parse("stripe")
        let results = try await repo.search(query: q)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.workspaceID, "-Users-test-flutter-app")
    }

    func test_search_titleText_allWordsAreANDed() async throws {
        let (repo, _) = try makeRepo()
        try await repo.bootstrap(rootURL: fixturesRoot())

        // Both words appear in the flutter title.
        let both = try await repo.search(query: SearchQueryParser.parse("stripe checkout"))
        XCTAssertEqual(both.count, 1)

        // Only one word matches — should still be the flutter session.
        let one = try await repo.search(query: SearchQueryParser.parse("stripe nonexistentword"))
        XCTAssertEqual(one.count, 0, "AND semantics — missing word must exclude the row")
    }

    func test_search_titleText_escapesLikeWildcards() async throws {
        let (repo, _) = try makeRepo()
        try await repo.bootstrap(rootURL: fixturesRoot())

        // `%` in user input must be treated as literal — not a wildcard.
        let results = try await repo.search(query: SearchQueryParser.parse("%%%"))
        XCTAssertEqual(results.count, 0)
    }

    // MARK: - /in:

    func test_search_inFilter_limitsToMatchingWorkspace() async throws {
        let (repo, _) = try makeRepo()
        try await repo.bootstrap(rootURL: fixturesRoot())

        let q = SearchQueryParser.parse("/in:flutter")
        let results = try await repo.search(query: q)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.workspaceID, "-Users-test-flutter-app")
    }

    func test_search_inFilter_unknownWorkspace_returnsEmpty() async throws {
        let (repo, _) = try makeRepo()
        try await repo.bootstrap(rootURL: fixturesRoot())

        let q = SearchQueryParser.parse("/in:nonexistent")
        let results = try await repo.search(query: q)
        XCTAssertEqual(results.count, 0)
    }

    // MARK: - /today / time window

    func test_search_today_filtersByStartOfDay() async throws {
        let (repo, dbq) = try makeRepo()
        try await repo.bootstrap(rootURL: fixturesRoot())

        // Push both sessions back 10 days so /today returns nothing.
        try await dbq.write { db in
            let tenDaysAgo = Date().addingTimeInterval(-10 * 24 * 3600)
            try db.execute(sql: "UPDATE sessions_index SET last_modified_at = ?",
                           arguments: [tenDaysAgo])
        }
        let todayQ = SearchQueryParser.parse("/today")
        let todayResults = try await repo.search(query: todayQ)
        XCTAssertEqual(todayResults.count, 0)

        // Bring the flutter one into today's window.
        try await dbq.write { db in
            try db.execute(sql: "UPDATE sessions_index SET last_modified_at = ? WHERE workspace_id = ?",
                           arguments: [Date(), "-Users-test-flutter-app"])
        }
        let after = try await repo.search(query: todayQ)
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.first?.workspaceID, "-Users-test-flutter-app")
    }

    func test_search_last30Days_filtersCorrectly() async throws {
        let (repo, dbq) = try makeRepo()
        try await repo.bootstrap(rootURL: fixturesRoot())
        // Move flutter to 40 days ago, rust to 5 days ago.
        try await dbq.write { db in
            try db.execute(sql: "UPDATE sessions_index SET last_modified_at = ? WHERE workspace_id = ?",
                           arguments: [Date().addingTimeInterval(-40 * 24 * 3600), "-Users-test-flutter-app"])
            try db.execute(sql: "UPDATE sessions_index SET last_modified_at = ? WHERE workspace_id = ?",
                           arguments: [Date().addingTimeInterval(-5 * 24 * 3600), "-Users-test-rust-app"])
        }
        let results = try await repo.search(query: SearchQueryParser.parse("/last30days"))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.workspaceID, "-Users-test-rust-app")
    }

    // MARK: - /full:

    func test_search_fullText_populatesFtsAndReturnsBodyMatches() async throws {
        let (repo, dbq) = try makeRepo(withFts: true)
        try await repo.bootstrap(rootURL: fixturesRoot())

        // Pre-condition — nothing indexed yet.
        let before = try await dbq.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_fts") ?? -1
        }
        XCTAssertEqual(before, 0)

        let q = SearchQueryParser.parse("/full: stripe")
        let results = try await repo.search(query: q)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.workspaceID, "-Users-test-flutter-app")

        // Post-condition — FTS was populated on demand.
        let after = try await dbq.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_fts") ?? -1
        }
        XCTAssertGreaterThan(after, 0)
    }

    func test_search_fullText_matchesBodyNotTitle() async throws {
        // `tokio::select` only appears in the rust body.
        let (repo, _) = try makeRepo(withFts: true)
        try await repo.bootstrap(rootURL: fixturesRoot())
        let q = SearchQueryParser.parse("/full: tokio")
        let results = try await repo.search(query: q)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.workspaceID, "-Users-test-rust-app")
    }

    // MARK: - /tag: (captured but unused until plan 06)

    func test_search_quotedTagIsCaptured_butFilterIsPassThrough() async throws {
        let q = SearchQueryParser.parse(#"/tag:"client work""#)
        XCTAssertEqual(q.tags, ["client work"])

        let (repo, _) = try makeRepo()
        try await repo.bootstrap(rootURL: fixturesRoot())
        // Tag filter is currently a no-op. Confirm the query still returns full
        // results rather than silently returning [].
        let results = try await repo.search(query: q)
        XCTAssertEqual(results.count, 2)
    }

    // MARK: - cancellation

    func test_search_cancellationBeforeFtsEnsureIndexed_throws() async throws {
        let (repo, _) = try makeRepo(withFts: true)
        try await repo.bootstrap(rootURL: fixturesRoot())

        let q = SearchQueryParser.parse("/full: stripe")
        let task = Task<[SessionMetadata], Error> {
            try await repo.search(query: q)
        }
        task.cancel()

        do {
            _ = try await task.value
            // Depending on scheduling, the task may finish before the cancel
            // lands — either outcome is acceptable, but we assert at least
            // that no unexpected error was thrown.
        } catch is CancellationError {
            // expected when cancellation lands in time.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - escapeLike / sanitizeFtsMatch

    func test_escapeLike_escapesSpecials() {
        XCTAssertEqual(SessionsRepository.escapeLike("a_b%c"), "a\\_b\\%c")
        XCTAssertEqual(SessionsRepository.escapeLike("back\\slash"), "back\\\\slash")
    }

    func test_sanitizeFtsMatch_wrapsEachWordInQuotes() {
        XCTAssertEqual(SessionsRepository.sanitizeFtsMatch("hello world"),
                       "\"hello\" \"world\"")
        XCTAssertEqual(SessionsRepository.sanitizeFtsMatch("a-b c.d"),
                       "\"a-b\" \"c.d\"")
    }
}
