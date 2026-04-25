import XCTest
import GRDB
@testable import Chronicle

final class StatsTests: XCTestCase {

    private func fixturesRoot() -> URL {
        Bundle.module.url(forResource: "Fixtures/sample-sessions",
                          withExtension: nil)!
    }

    private func makeRepo() throws -> SessionsRepository {
        let dbq = try DatabaseQueue()
        try Migrations.all(dbq)
        return SessionsRepository(database: dbq,
                                   parser: JsonlParser(),
                                   decoder: WorkspacePathDecoder())
    }

    // MARK: - statsByWorkspace

    func test_statsByWorkspace_emptyDB_returnsEmpty() async throws {
        let repo = try makeRepo()
        let stats = try await repo.statsByWorkspace()
        XCTAssertTrue(stats.isEmpty)
    }

    func test_statsByWorkspace_orderedByTokensDesc_fromFixtures() async throws {
        let repo = try makeRepo()
        try await repo.bootstrap(rootURL: fixturesRoot())
        let stats = try await repo.statsByWorkspace()
        XCTAssertFalse(stats.isEmpty)
        for i in 1..<stats.count {
            XCTAssertGreaterThanOrEqual(
                stats[i - 1].totalTokens, stats[i].totalTokens,
                "rows must be ordered by totalTokens DESC")
        }
    }

    func test_statsByWorkspace_sumsTokensAcrossWorkspace() async throws {
        let repo = try makeRepo()
        try await repo.bootstrap(rootURL: fixturesRoot())
        let stats = try await repo.statsByWorkspace()

        // Manually recompute per-workspace token totals from the known
        // bootstrap output and compare.
        for row in stats {
            let sessions = try await repo.sessions(inWorkspaceID: row.workspaceID,
                                                    includeArchived: true,
                                                    includeDeleted: false)
            let expected = sessions.reduce(0) { $0 + $1.tokenCount }
            XCTAssertEqual(row.totalTokens, expected,
                           "row for \(row.workspaceID) must sum tokens across its sessions")
            XCTAssertEqual(row.sessionCount, sessions.count,
                           "row for \(row.workspaceID) must count its sessions")
        }
    }

    func test_statsByWorkspace_costIsNonNegativeAndMatchesPerSessionPricing() async throws {
        let repo = try makeRepo()
        try await repo.bootstrap(rootURL: fixturesRoot())
        let stats = try await repo.statsByWorkspace()
        for row in stats {
            XCTAssertGreaterThanOrEqual(row.estimatedCostUSD, 0)
            // Recompute via per-session attribution — the repo no longer
            // averages a single blended-Sonnet rate over the whole workspace.
            let sessions = try await repo.sessions(inWorkspaceID: row.workspaceID,
                                                    includeArchived: true,
                                                    includeDeleted: false)
            var expected: Double = 0
            for s in sessions {
                let i = s.inputTokens > 0 ? s.inputTokens : s.tokenCount / 2
                let o = s.outputTokens > 0 ? s.outputTokens : (s.tokenCount - s.tokenCount / 2)
                expected += ModelPricing.cost(inputTokens: i, outputTokens: o, model: s.model)
            }
            XCTAssertEqual(row.estimatedCostUSD, expected, accuracy: 0.00001)
        }
    }

    // MARK: - totalStats

    func test_totalStats_sumsAcrossAllWorkspaces() async throws {
        let repo = try makeRepo()
        try await repo.bootstrap(rootURL: fixturesRoot())
        let totals = try await repo.totalStats()
        let perWorkspace = try await repo.statsByWorkspace()

        XCTAssertEqual(totals.sessions,
                       perWorkspace.reduce(0) { $0 + $1.sessionCount })
        XCTAssertEqual(totals.tokens,
                       perWorkspace.reduce(0) { $0 + $1.totalTokens })
        XCTAssertEqual(totals.estimatedCostUSD,
                       perWorkspace.reduce(0.0) { $0 + $1.estimatedCostUSD },
                       accuracy: 0.01)
    }

    func test_totalStats_emptyDB_returnsZeros() async throws {
        let repo = try makeRepo()
        let totals = try await repo.totalStats()
        XCTAssertEqual(totals.sessions, 0)
        XCTAssertEqual(totals.tokens, 0)
        XCTAssertEqual(totals.estimatedCostUSD, 0, accuracy: 0.0001)
    }

    // MARK: - hourWeekdayHeatmap

    func test_hourWeekdayHeatmap_emitsFullGrid_24x7() async throws {
        let repo = try makeRepo()
        try await repo.bootstrap(rootURL: fixturesRoot())
        let cells = try await repo.hourWeekdayHeatmap(days: 10_000)
        XCTAssertEqual(cells.count, 24 * 7)

        // Every (weekday, hour) pair appears exactly once.
        var seen = Set<Int>()
        for c in cells {
            XCTAssertTrue((1...7).contains(c.weekday))
            XCTAssertTrue((0...23).contains(c.hour))
            XCTAssertGreaterThanOrEqual(c.count, 0)
            seen.insert(c.weekday * 100 + c.hour)
        }
        XCTAssertEqual(seen.count, 24 * 7)
    }

    func test_hourWeekdayHeatmap_countMatchesNumberOfSessionsInWindow() async throws {
        let repo = try makeRepo()
        try await repo.bootstrap(rootURL: fixturesRoot())

        // Sum of cells equals total non-deleted sessions inside the window.
        let cells = try await repo.hourWeekdayHeatmap(days: 10_000)
        let cellSum = cells.reduce(0) { $0 + $1.count }

        let totals = try await repo.totalStats()
        XCTAssertEqual(cellSum, totals.sessions,
                       "heatmap cells should sum to the total session count for a huge window")
    }

    func test_hourWeekdayHeatmap_zeroDaysReturnsEmptyCountsButFullGrid() async throws {
        let repo = try makeRepo()
        try await repo.bootstrap(rootURL: fixturesRoot())
        let cells = try await repo.hourWeekdayHeatmap(days: 0)
        XCTAssertEqual(cells.count, 24 * 7)
    }

    // MARK: - calendarHeatmap

    func test_calendarHeatmap_fillsEveryDayIncludingZeros() async throws {
        let repo = try makeRepo()
        try await repo.bootstrap(rootURL: fixturesRoot())
        let days = 90
        let cells = try await repo.calendarHeatmap(days: days)
        XCTAssertEqual(cells.count, days)

        // Oldest -> newest ordering.
        for i in 1..<cells.count {
            XCTAssertLessThan(cells[i - 1].date, cells[i].date,
                              "calendarHeatmap must be ordered oldest -> newest")
        }

        // Every cell is a start-of-day value in the local calendar.
        let cal = Calendar.current
        for c in cells {
            XCTAssertEqual(c.date, cal.startOfDay(for: c.date))
            XCTAssertGreaterThanOrEqual(c.sessionCount, 0)
            XCTAssertGreaterThanOrEqual(c.tokenCount, 0)
        }
    }

    func test_calendarHeatmap_sessionTokens_matchTotalsForHugeWindow() async throws {
        let repo = try makeRepo()
        try await repo.bootstrap(rootURL: fixturesRoot())
        // 10k-day window covers all fixture activity.
        let cells = try await repo.calendarHeatmap(days: 10_000)

        let totalSessions = cells.reduce(0) { $0 + $1.sessionCount }
        let totalTokens = cells.reduce(0) { $0 + $1.tokenCount }

        let totals = try await repo.totalStats()
        XCTAssertEqual(totalSessions, totals.sessions)
        XCTAssertEqual(totalTokens, totals.tokens)
    }
}
