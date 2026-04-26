import XCTest
@testable import Chronicle

final class SessionsWatcherExtensionFilterTests: XCTestCase {
    /// Verify the watcher accepts a configurable set of file extensions
    /// (Phase 3a: Gemini sessions are .json, not .jsonl).
    @MainActor
    func test_sessionsWatcher_acceptsConfiguredExtensions() throws {
        // Stage two files in a temp dir: one .jsonl (Claude/Codex shape)
        // and one .json (Gemini shape). With extensions: ["json"], only
        // the .json file should be visible to the watcher's
        // workspaceID-derivation helper. With the default ["jsonl"],
        // only the .jsonl file is visible.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("chronicle-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Default watcher (jsonl)
        let jsonlWatcher = SessionsWatcher(rootURL: tmp, latency: 0.1)
        XCTAssertTrue(jsonlWatcher.acceptsExtension("jsonl"))
        XCTAssertFalse(jsonlWatcher.acceptsExtension("json"))

        // Configured watcher (json)
        let jsonWatcher = SessionsWatcher(rootURL: tmp, latency: 0.1, extensions: ["json"])
        XCTAssertTrue(jsonWatcher.acceptsExtension("json"))
        XCTAssertFalse(jsonWatcher.acceptsExtension("jsonl"))
    }
}
