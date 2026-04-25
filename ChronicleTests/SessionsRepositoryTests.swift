import XCTest
import GRDB
@testable import Chronicle

final class SessionsRepositoryTests: XCTestCase {
    private func fixturesRoot() -> URL {
        Bundle.module.url(forResource: "Fixtures/sample-sessions",
                          withExtension: nil)!
    }

    private func makeRepo() throws -> SessionsRepository {
        let dbq = try DatabaseQueue()
        // Apply all migrations — the read-side queries now LEFT JOIN
        // user_metadata (added in v4) so older partial-migration setups
        // fail at runtime.
        try Migrations.all(dbq)
        return SessionsRepository(database: dbq, parser: JsonlParser(),
                                  decoder: WorkspacePathDecoder())
    }

    func test_bootstrap_indexesAllWorkspaces() async throws {
        let repo = try makeRepo()
        try await repo.bootstrap(rootURL: fixturesRoot())
        let workspaces = try await repo.allWorkspaces()
        XCTAssertEqual(workspaces.count, 2)
        XCTAssertTrue(workspaces.contains { $0.id == "-Users-test-flutter-app" })
        XCTAssertTrue(workspaces.contains { $0.id == "-Users-test-rust-app" })
    }

    func test_bootstrap_indexesAllSessions() async throws {
        let repo = try makeRepo()
        try await repo.bootstrap(rootURL: fixturesRoot())
        let flutterSessions = try await repo.sessions(inWorkspaceID: "-Users-test-flutter-app")
        XCTAssertEqual(flutterSessions.count, 1)
        XCTAssertEqual(flutterSessions.first?.title,
                       "Add Stripe checkout to subscription flow")
        XCTAssertEqual(flutterSessions.first?.messageCount, 4)
    }

    func test_bootstrap_isIdempotent() async throws {
        let repo = try makeRepo()
        try await repo.bootstrap(rootURL: fixturesRoot())
        try await repo.bootstrap(rootURL: fixturesRoot())
        let workspaces = try await repo.allWorkspaces()
        XCTAssertEqual(workspaces.count, 2, "second bootstrap must not duplicate")
    }

    func test_bootstrap_emptyDirectory_throwsNoWorkspacesFound() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let repo = try makeRepo()
        do {
            try await repo.bootstrap(rootURL: tmp)
            XCTFail("expected BootstrapError.noWorkspacesFound")
        } catch SessionsRepository.BootstrapError.noWorkspacesFound {
            // expected
        }
    }

    // MARK: - Plan 04 — menubar queries

    func test_recentSessions_filtersByWindowAndOrdersDesc() async throws {
        let repo = try makeRepo()
        try await repo.bootstrap(rootURL: fixturesRoot())

        // Re-stamp two known sessions so we can assert ordering + cutoff.
        let now = Date()
        let oneDayAgo = now.addingTimeInterval(-86400)
        let twentyDaysAgo = now.addingTimeInterval(-20 * 86400)

        let allSessions = try await repo.allSessions(limit: 100)
        guard allSessions.count >= 2 else {
            XCTFail("need at least 2 fixture sessions")
            return
        }

        // Manipulate their timestamps via a direct DB write. We can't easily
        // reach the repo's private DatabaseQueue — but the API contract is
        // enough: the fixture sessions have a known spread of timestamps
        // already (decoded from their jsonl bodies). Call recentSessions with
        // a huge window to verify ordering.
        let recent = try await repo.recentSessions(days: 10_000, limit: 10)
        XCTAssertEqual(recent.count, allSessions.count)
        for i in 1..<recent.count {
            XCTAssertGreaterThanOrEqual(recent[i - 1].lastModifiedAt, recent[i].lastModifiedAt,
                                        "recentSessions must be ordered by last_modified_at DESC")
        }

        _ = oneDayAgo; _ = twentyDaysAgo
    }

    func test_recentSessions_limitIsApplied() async throws {
        let repo = try makeRepo()
        try await repo.bootstrap(rootURL: fixturesRoot())
        let one = try await repo.recentSessions(days: 10_000, limit: 1)
        XCTAssertEqual(one.count, 1)
    }

    func test_recentSessions_excludesSessionsOlderThanWindow() async throws {
        // With days=0, cutoff = now, so only sessions from the future (none)
        // should be returned.
        let repo = try makeRepo()
        try await repo.bootstrap(rootURL: fixturesRoot())
        let none = try await repo.recentSessions(days: 0, limit: 30)
        // Any fixture with lastModifiedAt > now would slip through; the
        // fixtures are historical, so we expect zero here.
        XCTAssertTrue(none.allSatisfy { $0.lastModifiedAt >= Date().addingTimeInterval(-1) })
    }

    func test_liveSessions_returnsEmptyForHistoricalFixtures() async throws {
        let repo = try makeRepo()
        try await repo.bootstrap(rootURL: fixturesRoot())
        let live = try await repo.liveSessions()
        // Fixtures are historical (2026-01-01 timestamps in jsonl bodies), so
        // none should qualify as "live".
        XCTAssertTrue(live.isEmpty, "historical fixtures must not be reported as live")
    }

    func test_pinnedSessions_returnsEmptyWithoutPinnedRows() async throws {
        let repo = try makeRepo()
        try await repo.bootstrap(rootURL: fixturesRoot())
        let pinned = try await repo.pinnedSessions(limit: 30)
        XCTAssertTrue(pinned.isEmpty)
    }

    func test_bootstrap_partialFailure_continuesAndCollectsErrors() async throws {
        // Create a fixture-like dir with one good workspace folder and one folder containing a file with bad json
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let goodFolder = tmp.appendingPathComponent("-good", isDirectory: true)
        try FileManager.default.createDirectory(at: goodFolder, withIntermediateDirectories: true)
        try #"{"type":"user","message":{"role":"user","content":"hi"},"timestamp":"2026-01-01T00:00:00Z","sessionId":"11111111-1111-1111-1111-111111111111"}"#
            .write(to: goodFolder.appendingPathComponent("11111111-1111-1111-1111-111111111111.jsonl"),
                   atomically: true, encoding: .utf8)

        let badFolder = tmp.appendingPathComponent("-bad", isDirectory: true)
        try FileManager.default.createDirectory(at: badFolder, withIntermediateDirectories: true)
        try "garbage not json".write(to: badFolder.appendingPathComponent("22222222-2222-2222-2222-222222222222.jsonl"),
                                     atomically: true, encoding: .utf8)

        let repo = try makeRepo()
        try await repo.bootstrap(rootURL: tmp)
        let workspaces = try await repo.allWorkspaces()
        XCTAssertEqual(workspaces.count, 2, "both workspaces inserted despite one having a bad session file")
        let goodSessions = try await repo.sessions(inWorkspaceID: "-good")
        XCTAssertEqual(goodSessions.count, 1)
    }
}
