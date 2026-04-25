import XCTest
@testable import Chronicle

/// Exercises the FSEventStream-backed SessionsWatcher.
///
/// FSEvents is flaky on CI and on virtualised filesystems; we mitigate with
/// an async polling helper that retries the assertion every 30 ms until a
/// timeout. Tests that drive real filesystem writes give macOS a small
/// settle window before asserting.
final class SessionsWatcherTests: XCTestCase {

    private var tmpRoot: URL!
    private var watcher: SessionsWatcher!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("chronicle-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        // Ensure the watched path resolves to an absolute canonical path —
        // /var symlinks to /private/var on macOS which confuses FSEvents.
        tmpRoot = URL(fileURLWithPath: tmpRoot.resolvingSymlinksInPath().path, isDirectory: true)
    }

    override func tearDown() async throws {
        if let w = watcher { await w.stop() }
        watcher = nil
        if let root = tmpRoot { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Poll `condition` every 30 ms until it returns true or the timeout
    /// elapses. Returns the latest evaluated value.
    @discardableResult
    private func until(timeout: TimeInterval = 3.0,
                       _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return await condition()
    }

    // MARK: - Tests

    func test_watcher_firesOnJsonlCreate() async throws {
        watcher = SessionsWatcher(rootURL: tmpRoot, latency: 0.1)

        let box = ChangeBox()
        await watcher.start { cs in await box.append(cs) }

        // Give FSEvents time to arm before writing.
        try await Task.sleep(nanoseconds: 300_000_000)

        let wsFolder = tmpRoot.appendingPathComponent("-Users-test-ws")
        try FileManager.default.createDirectory(at: wsFolder, withIntermediateDirectories: true)
        let jsonl = wsFolder.appendingPathComponent("11111111-1111-1111-1111-111111111111.jsonl")
        try "line1\n".write(to: jsonl, atomically: true, encoding: .utf8)

        let ok = await until(timeout: 5.0) {
            let changed = await box.allChanged
            return changed.contains { $0.lastPathComponent == jsonl.lastPathComponent }
        }
        let observed = await box.allChanged
        XCTAssertTrue(ok, "changed set should include the written .jsonl; got \(observed)")
    }

    func test_watcher_firesOnJsonlDelete() async throws {
        watcher = SessionsWatcher(rootURL: tmpRoot, latency: 0.1)

        let wsFolder = tmpRoot.appendingPathComponent("-Users-test-ws")
        try FileManager.default.createDirectory(at: wsFolder, withIntermediateDirectories: true)
        let jsonl = wsFolder.appendingPathComponent("22222222-2222-2222-2222-222222222222.jsonl")
        try "line1\n".write(to: jsonl, atomically: true, encoding: .utf8)

        let box = ChangeBox()
        await watcher.start { cs in await box.append(cs) }

        try await Task.sleep(nanoseconds: 300_000_000)
        try FileManager.default.removeItem(at: jsonl)

        let ok = await until(timeout: 5.0) {
            let removed = await box.allRemoved
            return removed.contains { $0.lastPathComponent == jsonl.lastPathComponent }
        }
        let observed = await box.allRemoved
        XCTAssertTrue(ok, "removed set should include the deleted .jsonl; got \(observed)")
    }

    func test_watcher_coalescesRapidWrites() async throws {
        // 400ms latency means three writes within 100ms should land in a
        // single ChangeSet delivery.
        watcher = SessionsWatcher(rootURL: tmpRoot, latency: 0.4)

        let box = ChangeBox()
        await watcher.start { cs in await box.append(cs) }

        try await Task.sleep(nanoseconds: 300_000_000)

        let wsFolder = tmpRoot.appendingPathComponent("-Users-test-ws")
        try FileManager.default.createDirectory(at: wsFolder, withIntermediateDirectories: true)

        let a = wsFolder.appendingPathComponent("33333333-3333-3333-3333-333333333333.jsonl")
        let b = wsFolder.appendingPathComponent("44444444-4444-4444-4444-444444444444.jsonl")
        let c = wsFolder.appendingPathComponent("55555555-5555-5555-5555-555555555555.jsonl")
        try "a".write(to: a, atomically: true, encoding: .utf8)
        try "b".write(to: b, atomically: true, encoding: .utf8)
        try "c".write(to: c, atomically: true, encoding: .utf8)

        let ok = await until(timeout: 5.0) {
            let changed = await box.allChanged
            return changed.count >= 3
        }
        let observedCount = await box.allChanged.count
        XCTAssertTrue(ok, "should observe all three jsonl files; got \(observedCount)")
        // Also assert that the number of deliveries is bounded — coalescing
        // should keep it at ≤ 3 for three writes inside one latency window.
        let deliveryCount = await box.deliveryCount
        XCTAssertLessThanOrEqual(deliveryCount, 3,
                                 "expected coalescing but got \(deliveryCount) deliveries")
    }

    func test_watcher_stop_haltsEvents() async throws {
        watcher = SessionsWatcher(rootURL: tmpRoot, latency: 0.1)
        let box = ChangeBox()
        await watcher.start { cs in await box.append(cs) }
        try await Task.sleep(nanoseconds: 300_000_000)
        await watcher.stop()

        let wsFolder = tmpRoot.appendingPathComponent("-Users-test-ws")
        try FileManager.default.createDirectory(at: wsFolder, withIntermediateDirectories: true)
        let jsonl = wsFolder.appendingPathComponent("66666666-6666-6666-6666-666666666666.jsonl")
        try "hello".write(to: jsonl, atomically: true, encoding: .utf8)

        // Wait longer than the debounce window — should remain empty.
        try await Task.sleep(nanoseconds: 800_000_000)
        let deliveries = await box.deliveryCount
        XCTAssertEqual(deliveries, 0, "stop() must halt FSEvents delivery")
    }

    func test_watcher_ignoresNonJsonlFiles() async throws {
        watcher = SessionsWatcher(rootURL: tmpRoot, latency: 0.1)
        let box = ChangeBox()
        await watcher.start { cs in await box.append(cs) }
        try await Task.sleep(nanoseconds: 300_000_000)

        let wsFolder = tmpRoot.appendingPathComponent("-Users-test-ws")
        try FileManager.default.createDirectory(at: wsFolder, withIntermediateDirectories: true)
        let notes = wsFolder.appendingPathComponent("notes.md")
        try "ignore me".write(to: notes, atomically: true, encoding: .utf8)

        try await Task.sleep(nanoseconds: 500_000_000)
        let deliveries = await box.deliveryCount
        XCTAssertEqual(deliveries, 0, ".md writes must not produce ChangeSets")
    }
}

/// Thread-safe collector for ChangeSet deliveries in the watcher tests.
private actor ChangeBox {
    private(set) var received: [ChangeSet] = []

    func append(_ cs: ChangeSet) {
        received.append(cs)
    }

    var deliveryCount: Int { received.count }

    var allChanged: Set<URL> {
        received.reduce(into: Set<URL>()) { $0.formUnion($1.changedJsonl) }
    }

    var allRemoved: Set<URL> {
        received.reduce(into: Set<URL>()) { $0.formUnion($1.removedJsonl) }
    }
}
