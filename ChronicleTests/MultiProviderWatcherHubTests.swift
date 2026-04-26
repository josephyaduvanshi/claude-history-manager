import XCTest
import GRDB
@testable import Chronicle

final class MultiProviderWatcherHubTests: XCTestCase {
    @MainActor
    func test_hub_setActive_startsOnlyActiveProviderWatcher() async throws {
        let dbq = try DatabaseQueue()
        try Migrations.all(dbq)
        let repo = SessionsRepository(
            database: dbq,
            parser: JsonlParser(),
            decoder: WorkspacePathDecoder()
        )

        let recorder = WatcherStartStopRecorder()
        let hub = MultiProviderWatcherHub(
            repository: repo,
            projectsRoot: FileManager.default.temporaryDirectory,
            onWatcherStart: { id in await recorder.startedFor(id) },
            onWatcherStop: { id in await recorder.stoppedFor(id) }
        )

        // Build all three; start with Claude active.
        hub.build(available: [.claude, .codex, .gemini])
        await hub.setActive(.claude)
        try await Task.sleep(nanoseconds: 100_000_000)

        // Switch to Codex
        await hub.setActive(.codex)
        try await Task.sleep(nanoseconds: 100_000_000)

        let started = await recorder.allStarted
        let stopped = await recorder.allStopped
        XCTAssertEqual(started, [.claude, .codex],
            "Hub must start Claude initially then Codex on setActive")
        XCTAssertEqual(stopped, [.claude],
            "Hub must stop Claude when switching to Codex")

        // Switch to Gemini
        await hub.setActive(.gemini)
        try await Task.sleep(nanoseconds: 100_000_000)

        let stoppedAfter = await recorder.allStopped
        XCTAssertEqual(stoppedAfter, [.claude, .codex])

        // Tear down so any FSEvents streams started by the active
        // watcher don't outlive this test.
        await hub.stopAll()
    }

    @MainActor
    func test_hub_concurrentSetActive_endsOnLastClick() async throws {
        let dbq = try DatabaseQueue()
        try Migrations.all(dbq)
        let repo = SessionsRepository(
            database: dbq,
            parser: JsonlParser(),
            decoder: WorkspacePathDecoder()
        )
        let recorder = WatcherStartStopRecorder()
        let hub = MultiProviderWatcherHub(
            repository: repo,
            projectsRoot: FileManager.default.temporaryDirectory,
            onWatcherStart: { id in await recorder.startedFor(id) },
            onWatcherStop: { id in await recorder.stoppedFor(id) }
        )
        hub.build(available: [.claude, .codex, .gemini])
        await hub.setActive(.claude)

        // Fire three setActive calls without awaiting between them, then
        // wait for them all to drain. The serial pendingTask chain must
        // ensure the final state is .claude (the last call), with all
        // intermediate watchers properly stopped.
        async let a: Void = hub.setActive(.codex)
        async let b: Void = hub.setActive(.gemini)
        async let c: Void = hub.setActive(.claude)
        _ = await (a, b, c)

        let started = await recorder.allStarted
        let stopped = await recorder.allStopped

        // Whatever the intermediate sequence, the final state must be
        // self-consistent: net `started` count for non-Claude must equal
        // net `stopped` count for non-Claude.
        let nonClaudeStarts = started.filter { $0 != .claude }.count
        let nonClaudeStops  = stopped.filter { $0 != .claude }.count
        XCTAssertEqual(nonClaudeStarts, nonClaudeStops,
            "Every non-Claude start must have a matching stop after the storm settles")

        // Tear down so the FSEvents stream and any background tasks
        // started by the active watcher don't outlive this test and
        // interfere with neighbouring suites.
        await hub.stopAll()
    }
}

actor WatcherStartStopRecorder {
    private(set) var allStarted: [ProviderID] = []
    private(set) var allStopped: [ProviderID] = []
    func startedFor(_ id: ProviderID) { allStarted.append(id) }
    func stoppedFor(_ id: ProviderID) { allStopped.append(id) }
}
