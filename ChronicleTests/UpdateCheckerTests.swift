import XCTest
@testable import Chronicle

final class UpdateCheckerTests: XCTestCase {

    // MARK: - Version comparison

    func test_isNewer_semver_basic() {
        XCTAssertTrue(UpdateChecker.isNewer(remote: "1.2.3", than: "1.2.2"))
        XCTAssertTrue(UpdateChecker.isNewer(remote: "2.0.0", than: "1.9.9"))
        XCTAssertFalse(UpdateChecker.isNewer(remote: "1.0.0", than: "1.0.0"))
        XCTAssertFalse(UpdateChecker.isNewer(remote: "0.9.0", than: "1.0.0"))
    }

    func test_isNewer_strips_leading_v() {
        XCTAssertTrue(UpdateChecker.isNewer(remote: "v1.0.1", than: "v1.0.0"))
        XCTAssertTrue(UpdateChecker.isNewer(remote: "V2.0.0", than: "1.0.0"))
    }

    func test_isNewer_ignores_pre_release_suffix() {
        // 1.0.0-beta.1 is not strictly newer than 1.0.0 for our purposes
        // (we use the main stable tag only).
        XCTAssertFalse(UpdateChecker.isNewer(remote: "1.0.0-beta", than: "1.0.0"))
        XCTAssertTrue(UpdateChecker.isNewer(remote: "1.0.1-beta", than: "1.0.0"))
    }

    func test_isNewer_handles_short_or_long_segments() {
        XCTAssertTrue(UpdateChecker.isNewer(remote: "1.0.1", than: "1.0"))
        XCTAssertFalse(UpdateChecker.isNewer(remote: "1.0", than: "1.0.1"))
    }

    // MARK: - End-to-end check with stub HTTP

    func test_check_returns_updateAvailable_when_remote_is_newer() async {
        let stub = StubHTTP(data: Self.canned(tag: "v1.2.0",
                                              bodyNotes: "# v1.2.0\n- Bug fixes"))
        let checker = UpdateChecker(repoPath: "me/repo", httpClient: stub)
        let outcome = await checker.check(currentVersion: "1.0.0")
        guard case .updateAvailable(let release, let cur) = outcome else {
            return XCTFail("expected .updateAvailable, got \(outcome)")
        }
        XCTAssertEqual(cur, "1.0.0")
        XCTAssertEqual(release.tagName, "v1.2.0")
        XCTAssertEqual(release.body?.contains("Bug fixes"), true)
    }

    func test_check_returns_upToDate_when_remote_matches() async {
        let stub = StubHTTP(data: Self.canned(tag: "v1.0.0", bodyNotes: "stable"))
        let checker = UpdateChecker(repoPath: "me/repo", httpClient: stub)
        let outcome = await checker.check(currentVersion: "1.0.0")
        guard case .upToDate(let cur) = outcome else {
            return XCTFail("expected .upToDate")
        }
        XCTAssertEqual(cur, "1.0.0")
    }

    func test_check_returns_upToDate_when_only_prerelease() async {
        var json = Self.canned(tag: "v1.1.0", bodyNotes: "beta")
        // Edit the stub to mark prerelease. Easier to re-encode from scratch.
        json = Self.cannedPrerelease(tag: "v1.1.0")
        let stub = StubHTTP(data: json)
        let checker = UpdateChecker(repoPath: "me/repo", httpClient: stub)
        let outcome = await checker.check(currentVersion: "1.0.0")
        if case .updateAvailable = outcome {
            XCTFail("prerelease should not trigger an update prompt")
        }
    }

    func test_check_surfaces_network_error_as_error_outcome() async {
        let checker = UpdateChecker(
            repoPath: "me/repo",
            httpClient: ThrowingHTTP()
        )
        let outcome = await checker.check(currentVersion: "1.0.0")
        guard case .error = outcome else {
            return XCTFail("expected .error outcome, got \(outcome)")
        }
    }

    // MARK: - Fixtures

    private static func canned(tag: String, bodyNotes: String) -> Data {
        let payload: [String: Any] = [
            "tag_name": tag,
            "name": "Release \(tag)",
            "body": bodyNotes,
            "html_url": "https://github.com/me/repo/releases/tag/\(tag)",
            "published_at": "2026-04-24T00:00:00Z",
            "draft": false,
            "prerelease": false,
        ]
        return try! JSONSerialization.data(withJSONObject: payload, options: [])
    }

    private static func cannedPrerelease(tag: String) -> Data {
        let payload: [String: Any] = [
            "tag_name": tag,
            "name": "Pre-release \(tag)",
            "body": "not yet",
            "html_url": "https://github.com/me/repo/releases/tag/\(tag)",
            "published_at": "2026-04-24T00:00:00Z",
            "draft": false,
            "prerelease": true,
        ]
        return try! JSONSerialization.data(withJSONObject: payload, options: [])
    }
}

// MARK: - Stubs

struct StubHTTP: UpdateHTTPClient {
    let data: Data
    func fetch(_ url: URL) async throws -> Data { data }
}

struct ThrowingHTTP: UpdateHTTPClient {
    func fetch(_ url: URL) async throws -> Data {
        throw URLError(.notConnectedToInternet)
    }
}
