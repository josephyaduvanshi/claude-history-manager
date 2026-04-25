import XCTest
@testable import Chronicle

/// Tests for `MenubarHotkeys.resumeLastSession` — the decision logic that
/// fires when the user hits ⌘⇧⏎. Carbon's real hotkey registration is
/// bypassed (it needs a runloop); we feed the static method a stub
/// repository + launcher and assert it hands off to the launcher correctly.
@MainActor
final class MenubarHotkeysTests: XCTestCase {

    // MARK: - Doubles

    /// Minimal repo stub — only the two methods resumeLastSession calls.
    private final class StubRepo: SessionsRepositoryProtocol, @unchecked Sendable {
        var sessions: [SessionMetadata] = []
        var workspaces: [Workspace] = []
        var sessionsError: Error?
        var workspacesError: Error?

        func bootstrap(rootURL: URL) async throws { }
        func allWorkspaces() async throws -> [Workspace] {
            if let e = workspacesError { throw e }
            return workspaces
        }
        func sessions(inWorkspaceID id: String) async throws -> [SessionMetadata] { [] }
        func allSessions(limit: Int) async throws -> [SessionMetadata] {
            if let e = sessionsError { throw e }
            return Array(sessions.prefix(limit))
        }
        func search(query: SearchQuery) async throws -> [SessionMetadata] { [] }
        func recentSessions(days: Int, limit: Int) async throws -> [SessionMetadata] { sessions }
        func liveSessions() async throws -> [SessionMetadata] { [] }
        func pinnedSessions(limit: Int) async throws -> [SessionWithMetadata] { [] }
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

    private final class RecordingLauncher: SessionLauncherProtocol, @unchecked Sendable {
        struct Invocation: Equatable {
            let terminal: Terminal
            let sessionID: String
            let workingDirectory: String
        }
        let lock = NSLock()
        var _invocations: [Invocation] = []
        var invocations: [Invocation] {
            lock.lock(); defer { lock.unlock() }
            return _invocations
        }

        func buildCommand(terminal: Terminal, sessionID: String, workingDirectory: String) -> LaunchCommand {
            LaunchCommand(executable: "noop", arguments: [])
        }
        func launch(terminal: Terminal, sessionID: String, workingDirectory: String) async throws {
            lock.lock(); defer { lock.unlock() }
            _invocations.append(Invocation(terminal: terminal, sessionID: sessionID, workingDirectory: workingDirectory))
        }
    }

    // MARK: - Helpers

    private func fixtureSession(id: String, wsID: String = "ws-1") throws -> SessionMetadata {
        SessionMetadata(
            sessionID: try SessionID(string: id),
            workspaceID: wsID,
            title: "s",
            createdAt: Date(),
            lastModifiedAt: Date(),
            messageCount: 1,
            tokenCount: 1,
            isLive: false
        )
    }

    // MARK: - Tests

    func test_resumeLastSession_happyPath_launchesMostRecent() async throws {
        let repo = StubRepo()
        let sid = "11111111-1111-1111-1111-111111111111"
        repo.sessions = [try fixtureSession(id: sid)]
        repo.workspaces = [Workspace(id: "ws-1", decodedPath: "/Users/me/proj", group: "g", displayName: "proj")]

        let launcher = RecordingLauncher()
        var errors: [String] = []
        await MenubarHotkeys.resumeLastSession(
            repository: repo,
            launcher: launcher,
            terminalPreference: nil,
            onError: { errors.append($0) }
        )

        XCTAssertTrue(errors.isEmpty, "no errors on happy path: \(errors)")
        XCTAssertEqual(launcher.invocations.count, 1)
        XCTAssertEqual(launcher.invocations.first?.sessionID, sid)
        XCTAssertEqual(launcher.invocations.first?.workingDirectory, "/Users/me/proj")
    }

    func test_resumeLastSession_noSessions_reportsError() async {
        let repo = StubRepo() // empty
        let launcher = RecordingLauncher()
        var errors: [String] = []
        await MenubarHotkeys.resumeLastSession(
            repository: repo,
            launcher: launcher,
            terminalPreference: nil,
            onError: { errors.append($0) }
        )
        XCTAssertTrue(launcher.invocations.isEmpty)
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors[0].localizedCaseInsensitiveContains("no sessions"))
    }

    func test_resumeLastSession_workspaceMissing_reportsError() async throws {
        let repo = StubRepo()
        let sid = "22222222-2222-2222-2222-222222222222"
        repo.sessions = [try fixtureSession(id: sid, wsID: "orphan")]
        repo.workspaces = [] // no matching workspace

        let launcher = RecordingLauncher()
        var errors: [String] = []
        await MenubarHotkeys.resumeLastSession(
            repository: repo,
            launcher: launcher,
            terminalPreference: nil,
            onError: { errors.append($0) }
        )
        XCTAssertTrue(launcher.invocations.isEmpty)
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors[0].localizedCaseInsensitiveContains("workspace"))
    }

    func test_resumeLastSession_repositoryThrows_reportsError() async {
        let repo = StubRepo()
        struct Boom: Error, LocalizedError {
            var errorDescription: String? { "db offline" }
        }
        repo.sessionsError = Boom()

        let launcher = RecordingLauncher()
        var errors: [String] = []
        await MenubarHotkeys.resumeLastSession(
            repository: repo,
            launcher: launcher,
            terminalPreference: nil,
            onError: { errors.append($0) }
        )
        XCTAssertTrue(launcher.invocations.isEmpty)
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors[0].contains("db offline"))
    }

    // MARK: - Coordinator construction

    func test_init_buildsWithoutRegistering() {
        let repo = StubRepo()
        let launcher = RecordingLauncher()
        let hk = MenubarHotkeys(
            repository: repo,
            launcher: launcher,
            onToggleMenubar: { },
            onError: { _ in }
        )
        // No assertions — we're verifying the init path doesn't crash
        // before registerAll() is called. Useful because SwiftUI often
        // constructs @State coordinators before the view appears.
        XCTAssertNotNil(hk)
    }
}
