import XCTest
@testable import Chronicle

final class MenubarModelReloadTests: XCTestCase {
    @MainActor
    func test_reload_runsAllReadsInParallel() async {
        let repo = ParallelTimingRepo(perReadDelayNs: 50_000_000)
        let model = MenubarModel()
        let start = ContinuousClock.now
        await model.reload(from: repo)
        let elapsed = ContinuousClock.now - start
        XCTAssertLessThan(
            elapsed, .milliseconds(120),
            "MenubarModel.reload should run reads concurrently; took \(elapsed)"
        )
    }
}

/// Actor fake that sleeps for a fixed duration on each of the four reads
/// MenubarModel.reload performs. Sequential execution would total
/// ~`4 * perReadDelayNs`; parallel via `async let` should finish in
/// ~`perReadDelayNs`. The test asserts the parallel bound.
actor ParallelTimingRepo: SessionsReadProtocol, WorkspaceRepositoryProtocol, UserMetadataRepositoryProtocol {
    let perReadDelayNs: UInt64
    init(perReadDelayNs: UInt64) { self.perReadDelayNs = perReadDelayNs }

    // MARK: - SessionsReadProtocol (the four MenubarModel.reload calls)

    func liveSessions() async throws -> [SessionMetadata] {
        try await Task.sleep(nanoseconds: perReadDelayNs); return []
    }
    func recentSessions(days: Int, limit: Int) async throws -> [SessionMetadata] {
        try await Task.sleep(nanoseconds: perReadDelayNs); return []
    }
    func pinnedSessions(limit: Int) async throws -> [SessionWithMetadata] {
        try await Task.sleep(nanoseconds: perReadDelayNs); return []
    }
    func totalSessionCount() async throws -> Int {
        try await Task.sleep(nanoseconds: perReadDelayNs); return 0
    }

    // MARK: - SessionsReadProtocol remaining

    func sessions(inWorkspaceID id: String) async throws -> [SessionMetadata] {
        fatalError("unused in this test")
    }
    func allSessions(limit: Int) async throws -> [SessionMetadata] {
        fatalError("unused in this test")
    }
    func search(query: SearchQuery) async throws -> [SessionMetadata] {
        fatalError("unused in this test")
    }

    // MARK: - WorkspaceRepositoryProtocol remaining

    func bootstrap(
        rootURL: URL,
        progress: (@Sendable (_ fraction: Double, _ message: String) -> Void)?
    ) async throws {
        fatalError("unused in this test")
    }
    func allWorkspaces() async throws -> [Workspace] {
        fatalError("unused in this test")
    }

    // MARK: - UserMetadataRepositoryProtocol remaining

    func userMetadata(for sessionID: SessionID) async throws -> UserMetadata {
        fatalError("unused in this test")
    }
    func archivedSessions(limit: Int) async throws -> [SessionWithMetadata] {
        fatalError("unused in this test")
    }
    func archivedCount() async throws -> Int {
        fatalError("unused in this test")
    }
    func setPinned(_ pinned: Bool, for sessionID: SessionID) async throws {
        fatalError("unused in this test")
    }
    func setArchived(_ archived: Bool, for sessionID: SessionID) async throws {
        fatalError("unused in this test")
    }
    func setNote(_ note: String?, for sessionID: SessionID) async throws {
        fatalError("unused in this test")
    }
    func setCustomTitle(_ title: String?, for sessionID: SessionID) async throws {
        fatalError("unused in this test")
    }
    func softDelete(_ sessionID: SessionID, workspaceID: String?) async throws {
        fatalError("unused in this test")
    }
    func undelete(_ sessionID: SessionID) async throws {
        fatalError("unused in this test")
    }
}
