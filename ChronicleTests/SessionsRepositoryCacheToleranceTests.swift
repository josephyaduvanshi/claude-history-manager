import XCTest
import GRDB
@testable import Chronicle

/// Exercises the 0.05s cache-hit tolerance window in
/// `SessionsRepository.indexWorkspace(...)`. The check at
/// `abs(cached.mtime.timeIntervalSince(mtime)) < 0.05` decides whether a
/// jsonl file's `(size, mtime)` matches its cached `sessions_index` row
/// closely enough to skip re-parsing entirely.
///
/// We invoke the static `indexWorkspace` helper directly so the test can
/// observe the `skipped` / `parsed` counters without spinning up the full
/// async bootstrap pipeline.
final class SessionsRepositoryCacheToleranceTests: XCTestCase {

    /// Build a one-file workspace folder under tmp containing a single jsonl
    /// with a known sessionId. Returns the folder URL and the jsonl URL.
    private func makeWorkspaceFolder() throws -> (folder: URL, jsonl: URL, sessionID: String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("-w", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let sid = "11111111-1111-1111-1111-111111111111"
        let jsonl = tmp.appendingPathComponent("\(sid).jsonl")
        let body = #"{"type":"user","message":{"role":"user","content":"hi"},"timestamp":"2026-04-22T14:00:00Z","sessionId":"\#(sid)"}"#
        try body.write(to: jsonl, atomically: true, encoding: .utf8)
        return (tmp, jsonl, sid)
    }

    /// 49ms delta between the cached mtime and the on-disk mtime is INSIDE
    /// the `< 0.05` (50ms) tolerance, so the parser must skip the file.
    func test_indexWorkspace_skipsFile_whenMtimeDeltaIs49ms_withinTolerance() throws {
        let (folder, jsonl, sid) = try makeWorkspaceFolder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

        // Stamp the jsonl with a fixed mtime so the test is deterministic.
        let onDiskMtime = Date(timeIntervalSince1970: 1_776_434_400)
        try FileManager.default.setAttributes(
            [.modificationDate: onDiskMtime], ofItemAtPath: jsonl.path
        )

        let attrs = try jsonl.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = attrs.fileSize ?? 0
        // Cache: mtime is 49ms BEHIND the on-disk mtime → |delta| = 0.049 < 0.05
        let cached = SessionsRepository.CachedFileAttrs(
            size: size,
            mtime: onDiskMtime.addingTimeInterval(-0.049)
        )

        let result = SessionsRepository.indexWorkspace(
            folder: folder,
            parser: JsonlParser(),
            decoder: WorkspacePathDecoder(),
            cachedAttrs: [sid: cached]
        )

        XCTAssertEqual(result.skipped, 1, "49ms delta is inside the 50ms tolerance — must skip")
        XCTAssertEqual(result.parsed, 0)
        XCTAssertTrue(result.seenSessionIDs.contains(sid),
                      "skipped files must still be reported in seenSessionIDs so the reaper doesn't drop them")
    }

    /// 51ms delta is OUTSIDE the `< 0.05` tolerance, so the parser must
    /// re-read and re-parse the file.
    func test_indexWorkspace_reparsesFile_whenMtimeDeltaIs51ms_outsideTolerance() throws {
        let (folder, jsonl, sid) = try makeWorkspaceFolder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

        let onDiskMtime = Date(timeIntervalSince1970: 1_776_434_400)
        try FileManager.default.setAttributes(
            [.modificationDate: onDiskMtime], ofItemAtPath: jsonl.path
        )

        let attrs = try jsonl.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = attrs.fileSize ?? 0
        // Cache: mtime is 51ms BEHIND on-disk → |delta| = 0.051 > 0.05
        let cached = SessionsRepository.CachedFileAttrs(
            size: size,
            mtime: onDiskMtime.addingTimeInterval(-0.051)
        )

        let result = SessionsRepository.indexWorkspace(
            folder: folder,
            parser: JsonlParser(),
            decoder: WorkspacePathDecoder(),
            cachedAttrs: [sid: cached]
        )

        XCTAssertEqual(result.parsed, 1, "51ms delta is outside the 50ms tolerance — must re-parse")
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(result.data.sessions.count, 1,
                       "re-parsed file should produce a parsed session entry")
    }

    /// Sanity check: when the size differs, the file must be re-parsed
    /// regardless of mtime delta — guards against a future refactor that
    /// accidentally narrows the cache check to mtime only.
    func test_indexWorkspace_reparsesFile_whenSizeDiffers_evenWithExactMtime() throws {
        let (folder, jsonl, sid) = try makeWorkspaceFolder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

        let onDiskMtime = Date(timeIntervalSince1970: 1_776_434_400)
        try FileManager.default.setAttributes(
            [.modificationDate: onDiskMtime], ofItemAtPath: jsonl.path
        )

        let attrs = try jsonl.resourceValues(forKeys: [.fileSizeKey])
        let size = attrs.fileSize ?? 0
        // Same mtime, different size → must re-parse.
        let cached = SessionsRepository.CachedFileAttrs(size: size + 1, mtime: onDiskMtime)

        let result = SessionsRepository.indexWorkspace(
            folder: folder,
            parser: JsonlParser(),
            decoder: WorkspacePathDecoder(),
            cachedAttrs: [sid: cached]
        )

        XCTAssertEqual(result.parsed, 1)
        XCTAssertEqual(result.skipped, 0)
    }
}
