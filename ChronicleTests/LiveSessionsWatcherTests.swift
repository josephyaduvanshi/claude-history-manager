import XCTest
@testable import Chronicle

/// Exercises LiveSessionsWatcher using canned ps + lsof output via a stub
/// process runner. Real ps/lsof invocations are avoided entirely.
final class LiveSessionsWatcherTests: XCTestCase {

    // MARK: - Pure-function parsers

    func test_parseClaudePIDs_pickProgramDirectlyNamedClaude() {
        let out = """
        12345 claude --resume abc
        23456 /bin/zsh -i
        """
        XCTAssertEqual(LiveSessionsWatcher.parseClaudePIDs(psOutput: out), [12345])
    }

    func test_parseClaudePIDs_nodeWrapper() {
        let out = """
        777 node /usr/local/bin/claude --resume abc
        888 bash -c "echo hi"
        """
        XCTAssertEqual(LiveSessionsWatcher.parseClaudePIDs(psOutput: out), [777])
    }

    func test_parseClaudePIDs_ignoresUnrelatedProcesses() {
        let out = """
        1 /sbin/launchd
        42 /usr/libexec/containermanagerd
        """
        XCTAssertEqual(LiveSessionsWatcher.parseClaudePIDs(psOutput: out), [])
    }

    func test_parseLsofCwd_extractsFromFOutput() {
        let output = """
        p777
        n/Users/jyaduvanshi/Code/flutter-app
        """
        XCTAssertEqual(LiveSessionsWatcher.parseLsofCwd(output), "/Users/jyaduvanshi/Code/flutter-app")
    }

    func test_parseLsofCwd_returnsNilForEmpty() {
        XCTAssertNil(LiveSessionsWatcher.parseLsofCwd(""))
    }

    func test_matchWorkspace_prefersLongestPrefix() {
        let a = Workspace(id: "a", decodedPath: "/Users/x/Code", group: "c", displayName: "Code")
        let b = Workspace(id: "b", decodedPath: "/Users/x/Code/flutter", group: "flutter", displayName: "flutter")
        let match = LiveSessionsWatcher.matchWorkspace(
            forCWD: "/Users/x/Code/flutter/apps/thing",
            in: [a, b]
        )
        XCTAssertEqual(match?.id, "b")
    }

    func test_matchWorkspace_nilWhenNoAncestor() {
        let a = Workspace(id: "a", decodedPath: "/Users/x/Code", group: "c", displayName: "Code")
        let match = LiveSessionsWatcher.matchWorkspace(
            forCWD: "/tmp/random",
            in: [a]
        )
        XCTAssertNil(match)
    }

    // MARK: - End-to-end with stub runner

    private func makeSession(id: String, workspaceID: String, modifiedAgo: TimeInterval) -> SessionMetadata {
        SessionMetadata(
            sessionID: try! SessionID(string: id),
            workspaceID: workspaceID,
            title: "t",
            createdAt: Date().addingTimeInterval(-modifiedAgo),
            lastModifiedAt: Date().addingTimeInterval(-modifiedAgo),
            messageCount: 2,
            tokenCount: 100,
            isLive: false
        )
    }

    func test_tickOnce_noClaudeProcesses_returnsEmpty() async throws {
        let runner = ProcessRunnerStub()
        runner.stdoutForExecutable = { exec, _ in
            if exec.hasSuffix("ps") { return "1 launchd\n200 zsh -i" }
            return ""
        }
        let repo = FakeRepo()
        let w = LiveSessionsWatcher(repository: repo, runner: runner, pollInterval: 10)
        let live = await w.tickOnce()
        XCTAssertEqual(live, [])
    }

    func test_tickOnce_matchingProcess_liveSessionFound() async throws {
        let runner = ProcessRunnerStub()
        runner.stdoutForExecutable = { exec, args in
            if exec.hasSuffix("ps") {
                return "777 claude --resume abcdefab-1111-2222-3333-444444444444"
            }
            if exec.hasSuffix("lsof") {
                return "p777\nn/Users/me/flutter-app\n"
            }
            return ""
        }

        let repo = FakeRepo()
        repo.workspacesByID = [
            "flutter": Workspace(id: "flutter", decodedPath: "/Users/me/flutter-app",
                                 group: "flutter", displayName: "flutter-app"),
        ]
        let hot = makeSession(id: "11111111-1111-1111-1111-111111111111",
                              workspaceID: "flutter", modifiedAgo: 5)
        let cold = makeSession(id: "22222222-2222-2222-2222-222222222222",
                               workspaceID: "flutter", modifiedAgo: 300)
        repo.sessionsByWSID = ["flutter": [hot, cold]]

        let w = LiveSessionsWatcher(repository: repo, runner: runner, pollInterval: 10, liveWindowSeconds: 30)
        let live = await w.tickOnce()
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(live.first?.sessionID.description, "11111111-1111-1111-1111-111111111111")
        XCTAssertTrue(live.first?.isLive ?? false)
    }

    func test_tickOnce_cwdOutsideAnyWorkspace_dropsEntry() async throws {
        let runner = ProcessRunnerStub()
        runner.stdoutForExecutable = { exec, _ in
            if exec.hasSuffix("ps") { return "777 claude --resume x" }
            if exec.hasSuffix("lsof") { return "p777\nn/elsewhere\n" }
            return ""
        }
        let repo = FakeRepo()
        repo.workspacesByID = [
            "flutter": Workspace(id: "flutter", decodedPath: "/Users/me/flutter-app",
                                 group: "flutter", displayName: "flutter-app"),
        ]
        let w = LiveSessionsWatcher(repository: repo, runner: runner, pollInterval: 10)
        let live = await w.tickOnce()
        XCTAssertTrue(live.isEmpty)
    }

    func test_tickOnce_multipleSessions_sortedByLastModified() async throws {
        let runner = ProcessRunnerStub()
        runner.stdoutForExecutable = { exec, _ in
            if exec.hasSuffix("ps") { return "777 claude --resume x" }
            if exec.hasSuffix("lsof") { return "p777\nn/Users/me/flutter-app\n" }
            return ""
        }
        let repo = FakeRepo()
        repo.workspacesByID = [
            "flutter": Workspace(id: "flutter", decodedPath: "/Users/me/flutter-app",
                                 group: "flutter", displayName: "flutter-app"),
        ]
        let s1 = makeSession(id: "11111111-1111-1111-1111-111111111111",
                             workspaceID: "flutter", modifiedAgo: 20)
        let s2 = makeSession(id: "22222222-2222-2222-2222-222222222222",
                             workspaceID: "flutter", modifiedAgo: 2)
        repo.sessionsByWSID = ["flutter": [s1, s2]]

        let w = LiveSessionsWatcher(repository: repo, runner: runner, pollInterval: 10, liveWindowSeconds: 30)
        let live = await w.tickOnce()
        XCTAssertEqual(live.map(\.sessionID.description),
                       ["22222222-2222-2222-2222-222222222222",
                        "11111111-1111-1111-1111-111111111111"])
    }
}

// MARK: - Stub runner

private final class ProcessRunnerStub: StdoutProcessRunner, @unchecked Sendable {
    var stdoutForExecutable: @Sendable (String, [String]) -> String = { _, _ in "" }
    func runCapturingStdout(executable: String, arguments: [String]) async throws -> String {
        stdoutForExecutable(executable, arguments)
    }
}

// MARK: - FakeRepo

/// Minimal repository fake — only the methods LiveSessionsWatcher calls.
private final class FakeRepo: SessionsRepositoryProtocol, @unchecked Sendable {
    var workspacesByID: [String: Workspace] = [:]
    var sessionsByWSID: [String: [SessionMetadata]] = [:]

    func bootstrap(rootURL: URL) async throws { }
    func allWorkspaces() async throws -> [Workspace] {
        Array(workspacesByID.values)
    }
    func sessions(inWorkspaceID id: String) async throws -> [SessionMetadata] {
        sessionsByWSID[id] ?? []
    }
    func allSessions(limit: Int) async throws -> [SessionMetadata] { [] }
    func search(query: SearchQuery) async throws -> [SessionMetadata] { [] }
    func recentSessions(days: Int, limit: Int) async throws -> [SessionMetadata] { [] }
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
