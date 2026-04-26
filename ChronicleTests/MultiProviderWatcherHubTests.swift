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
    }
}

actor WatcherStartStopRecorder {
    private(set) var allStarted: [ProviderID] = []
    private(set) var allStopped: [ProviderID] = []
    func startedFor(_ id: ProviderID) { allStarted.append(id) }
    func stoppedFor(_ id: ProviderID) { allStopped.append(id) }
}
