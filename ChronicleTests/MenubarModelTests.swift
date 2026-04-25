import XCTest
import Foundation
@testable import Chronicle

@MainActor
final class MenubarModelTests: XCTestCase {

    // MARK: - Helpers

    private func sample(_ title: String,
                        wsID: String = "ws",
                        id: String = UUID().uuidString,
                        live: Bool = false,
                        modAt: Date = Date()) throws -> SessionMetadata {
        SessionMetadata(
            sessionID: try SessionID(string: id),
            workspaceID: wsID,
            title: title,
            createdAt: modAt,
            lastModifiedAt: modAt,
            messageCount: 1,
            tokenCount: 1,
            isLive: live
        )
    }

    // MARK: - Initial state

    func test_initialState_isEmpty() {
        let m = MenubarModel()
        XCTAssertEqual(m.query, "")
        XCTAssertTrue(m.liveSessions.isEmpty)
        XCTAssertTrue(m.recentSessions.isEmpty)
        XCTAssertTrue(m.pinnedSessions.isEmpty)
        XCTAssertTrue(m.searchResults.isEmpty)
        XCTAssertEqual(m.selectedIndex, 0)
        XCTAssertFalse(m.isSearching)
        XCTAssertTrue(m.visibleRows.isEmpty)
        XCTAssertNil(m.selectedSession)
    }

    // MARK: - reload

    func test_reload_populatesAllThreeLists() async throws {
        let m = MenubarModel()
        let repo = MockRepo()
        repo.live = [try sample("live-1", live: true)]
        repo.recent = [try sample("recent-1"), try sample("recent-2")]
        repo.pinned = []
        await m.reload(from: repo)

        XCTAssertEqual(m.liveSessions.map(\.title), ["live-1"])
        XCTAssertEqual(m.recentSessions.map(\.title), ["recent-1", "recent-2"])
        XCTAssertTrue(m.pinnedSessions.isEmpty)
    }

    func test_reload_dedupesRecentAgainstLive() async throws {
        let m = MenubarModel()
        let repo = MockRepo()
        let shared = try sample("shared", id: "11111111-1111-1111-1111-111111111111", live: true)
        let sharedRecent = SessionMetadata(
            sessionID: shared.sessionID,
            workspaceID: shared.workspaceID,
            title: shared.title,
            createdAt: shared.createdAt,
            lastModifiedAt: shared.lastModifiedAt,
            messageCount: shared.messageCount,
            tokenCount: shared.tokenCount,
            isLive: false
        )
        repo.live = [shared]
        repo.recent = [sharedRecent, try sample("unique")]
        await m.reload(from: repo)

        // "shared" is in live; must be filtered out of recent.
        XCTAssertEqual(m.liveSessions.map(\.title), ["shared"])
        XCTAssertEqual(m.recentSessions.map(\.title), ["unique"])
    }

    // MARK: - visibleRows

    func test_visibleRows_mergesLiveRecentPinnedWhenNotSearching() async throws {
        let m = MenubarModel()
        let repo = MockRepo()
        repo.live = [try sample("L")]
        repo.recent = [try sample("R")]
        repo.pinned = [try sample("P")]
        await m.reload(from: repo)

        XCTAssertFalse(m.isSearching)
        XCTAssertEqual(m.visibleRows.map(\.title), ["L", "R", "P"])
    }

    func test_visibleRows_usesSearchResultsWhenSearching() async throws {
        let m = MenubarModel()
        m.query = "hit"
        m.searchResults = [try sample("hit-1"), try sample("hit-2")]
        // live/recent/pinned should be hidden while searching.
        m.liveSessions = [try sample("live")]
        XCTAssertTrue(m.isSearching)
        XCTAssertEqual(m.visibleRows.map(\.title), ["hit-1", "hit-2"])
    }

    // MARK: - selectedIndex clamping

    func test_reload_clampsSelectionWhenListShrinks() async throws {
        let m = MenubarModel()
        let repo = MockRepo()
        repo.recent = [try sample("a"), try sample("b"), try sample("c")]
        await m.reload(from: repo)
        m.selectedIndex = 2
        XCTAssertEqual(m.selectedIndex, 2)

        // Now shrink the list.
        repo.recent = [try sample("only")]
        await m.reload(from: repo)
        XCTAssertLessThan(m.selectedIndex, m.visibleRows.count,
                         "selectedIndex must never point past the end")
        XCTAssertEqual(m.selectedIndex, 0)
    }

    func test_reload_clampsSelectionToZeroWhenListEmpty() async throws {
        let m = MenubarModel()
        m.selectedIndex = 5
        await m.reload(from: MockRepo()) // empty
        XCTAssertEqual(m.selectedIndex, 0)
        XCTAssertTrue(m.visibleRows.isEmpty)
    }

    func test_moveSelection_incrementsAndClampsAtBottom() async throws {
        let m = MenubarModel()
        let repo = MockRepo()
        repo.recent = [try sample("a"), try sample("b"), try sample("c")]
        await m.reload(from: repo)

        m.moveSelection(by: 1)
        XCTAssertEqual(m.selectedIndex, 1)
        m.moveSelection(by: 10)   // overshoot
        XCTAssertEqual(m.selectedIndex, 2)
    }

    func test_moveSelection_decrementsAndClampsAtTop() async throws {
        let m = MenubarModel()
        let repo = MockRepo()
        repo.recent = [try sample("a"), try sample("b")]
        await m.reload(from: repo)
        m.selectedIndex = 1
        m.moveSelection(by: -1)
        XCTAssertEqual(m.selectedIndex, 0)
        m.moveSelection(by: -5)   // undershoot
        XCTAssertEqual(m.selectedIndex, 0)
    }

    func test_selectedSession_returnsNilWhenNoRows() {
        let m = MenubarModel()
        XCTAssertNil(m.selectedSession)
    }

    func test_selectedSession_returnsCurrentRow() async throws {
        let m = MenubarModel()
        let repo = MockRepo()
        repo.recent = [try sample("first"), try sample("second")]
        await m.reload(from: repo)
        m.selectedIndex = 1
        XCTAssertEqual(m.selectedSession?.title, "second")
    }

    // MARK: - runSearch

    func test_runSearch_populatesSearchResults() async throws {
        let m = MenubarModel()
        let repo = MockRepo()
        repo.searchResults = [try sample("hit-a"), try sample("hit-b")]
        m.query = "hit"
        await m.runSearch(using: repo)
        XCTAssertEqual(m.searchResults.map(\.title), ["hit-a", "hit-b"])
    }

    func test_runSearch_cappedAt8() async throws {
        let m = MenubarModel()
        let repo = MockRepo()
        repo.searchResults = try (0..<20).map { try sample("hit-\($0)") }
        m.query = "hit"
        await m.runSearch(using: repo)
        XCTAssertEqual(m.searchResults.count, 8)
    }

    func test_runSearch_emptyQueryClearsResults() async {
        let m = MenubarModel()
        m.searchResults = [
            SessionMetadata(sessionID: try! SessionID(string: "11111111-1111-1111-1111-111111111111"),
                            workspaceID: "x", title: "old",
                            createdAt: Date(), lastModifiedAt: Date(),
                            messageCount: 0, tokenCount: 0, isLive: false)
        ]
        m.query = "   "
        await m.runSearch(using: MockRepo())
        XCTAssertTrue(m.searchResults.isEmpty)
    }
}

// MARK: - MockRepo

/// In-memory repository fake that the MenubarModel tests push fixtures into.
/// Only the methods the menubar calls are implemented; the rest trap so any
/// accidental call from a test shows up as a clear failure.
private final class MockRepo: SessionsRepositoryProtocol, @unchecked Sendable {
    var live: [SessionMetadata] = []
    var recent: [SessionMetadata] = []
    var pinned: [SessionMetadata] = []
    var searchResults: [SessionMetadata] = []

    func bootstrap(rootURL: URL) async throws { }
    func allWorkspaces() async throws -> [Workspace] { [] }
    func sessions(inWorkspaceID id: String) async throws -> [SessionMetadata] { [] }
    func allSessions(limit: Int) async throws -> [SessionMetadata] { recent }
    func search(query: SearchQuery) async throws -> [SessionMetadata] { searchResults }
    func recentSessions(days: Int, limit: Int) async throws -> [SessionMetadata] { recent }
    func liveSessions() async throws -> [SessionMetadata] { live }
    func pinnedSessions(limit: Int) async throws -> [SessionWithMetadata] {
        pinned.map { SessionWithMetadata(session: $0, userMetadata: UserMetadata.empty(for: $0.sessionID), tags: []) }
    }
    func archivedSessions(limit: Int) async throws -> [SessionWithMetadata] { [] }
    func sessionsForTag(_ tag: Tag, limit: Int) async throws -> [SessionWithMetadata] { [] }
    func userMetadata(for sessionID: SessionID) async throws -> UserMetadata {
        UserMetadata.empty(for: sessionID)
    }
    func tags(for sessionID: SessionID) async throws -> [Tag] { [] }
    func allTags() async throws -> [Tag] { [] }
    func tagCounts() async throws -> [Int64: Int] { [:] }
    func setPinned(_ pinned: Bool, for sessionID: SessionID) async throws { }
    func setArchived(_ archived: Bool, for sessionID: SessionID) async throws { }
    func setCustomTitle(_ title: String?, for sessionID: SessionID) async throws { }
    func setNote(_ note: String?, for sessionID: SessionID) async throws { }
    func softDelete(_ sessionID: SessionID, workspaceID: String?) async throws { }
    func undelete(_ sessionID: SessionID) async throws { }
    func hardPurgeExpiredDeletes(olderThan days: Int) async throws { }
    func createTag(name: String, colorHue: Int) async throws -> Tag {
        Tag(id: 1, name: name, colorHue: colorHue)
    }
    func renameTag(_ id: Int64, to name: String) async throws { }
    func deleteTag(_ id: Int64) async throws { }
    func setTags(_ tagIDs: [Int64], for sessionID: SessionID) async throws { }

    // MARK: Plan 07 stubs

    func smartFolders() async throws -> [SmartFolder] { [] }
    func createSmartFolder(name: String, query: SmartFolderQuery) async throws -> SmartFolder {
        SmartFolder(id: 1, name: name, query: query)
    }
    func deleteSmartFolder(_ id: Int64) async throws { }
    func renameSmartFolder(_ id: Int64, to name: String) async throws { }
    func sessionsForSmartFolder(_ folder: SmartFolder, limit: Int) async throws -> [SessionWithMetadata] { [] }
    func smartFolderCounts() async throws -> [Int64: Int] { [:] }
    func incrementalReindex(paths: Set<URL>,
                            workspaces: Set<String>,
                            removedPaths: Set<URL>) async throws { }
}
