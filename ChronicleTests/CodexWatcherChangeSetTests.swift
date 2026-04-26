import XCTest
@testable import Chronicle

final class CodexWatcherChangeSetTests: XCTestCase {
    func test_indexTail_emitsEmptyChangedWorkspaces() async {
        // Construct a CodexWatcher and synthesize an indexFileChanged
        // event by writing to a temp index file. Assert the resulting
        // ChangeSet has an EMPTY changedWorkspaces (no junk "sessions" tag).
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-watcher-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let indexFile = tmp.appendingPathComponent("session_index.jsonl")
        FileManager.default.createFile(atPath: indexFile.path, contents: nil)

        let watcher = CodexWatcher(
            sessionsRoot: tmp.appendingPathComponent("sessions"),
            indexFile: indexFile,
            latency: 0.05
        )

        let captured = ChangeSetBox()
        let exp = expectation(description: "watcher delivers ChangeSet on index growth")
        await watcher.start { change in
            // Only the index-tail nudge is interesting here. The
            // FSEvents channel may or may not fire on a temp dir; we
            // only assert against changes that come without changed
            // jsonl URLs or removed jsonl URLs (the index-tail shape).
            if change.changedJsonl.isEmpty && change.removedJsonl.isEmpty {
                await captured.set(change)
                exp.fulfill()
            }
        }
        // Append a line to the index file to trigger the tail.
        try? "line\n".write(to: indexFile, atomically: false, encoding: .utf8)

        await fulfillment(of: [exp], timeout: 2.0)
        await watcher.stop()
        let change = await captured.value
        XCTAssertNotNil(change)
        XCTAssertTrue(change!.changedWorkspaces.isEmpty,
            "Codex index-tail nudges must NOT include the literal 'sessions' string in changedWorkspaces")
    }
}

private actor ChangeSetBox {
    private(set) var value: ChangeSet?
    func set(_ c: ChangeSet) { value = c }
}
