import Foundation

/// Glue that owns the two Plan-07 watchers and feeds their events into the
/// repository + AppState. Lives for the app process' lifetime. The main app
/// creates one at startup and retains it via `@State` on the `App` struct.
@MainActor
public final class WatcherCoordinator {
    private let repository: SessionsRepository
    private let projectsRoot: URL
    private let fsWatcher: SessionsWatcher
    private let liveWatcher: LiveSessionsWatcher

    /// Callbacks the UI wires in at construction time; keeps this module
    /// free of direct AppState knowledge.
    public var onFileChange: (@Sendable (ChangeSet) async -> Void)?
    public var onLiveUpdate: (@Sendable ([SessionMetadata]) async -> Void)?

    public init(repository: SessionsRepository,
                projectsRoot: URL) {
        self.repository = repository
        self.projectsRoot = projectsRoot
        self.fsWatcher = SessionsWatcher(rootURL: projectsRoot, latency: 0.25)
        self.liveWatcher = LiveSessionsWatcher(repository: repository, pollInterval: 2.0)
    }

    public func start() {
        Task { [fsWatcher, liveWatcher, repository] in
            // File system watcher; re-parse + update session_flags for any
            // .jsonl that changed, drop rows for any that disappeared.
            await fsWatcher.start { [weak self] change in
                guard let self else { return }
                do {
                    try await repository.incrementalReindex(
                        paths: change.changedJsonl,
                        workspaces: change.changedWorkspaces,
                        removedPaths: change.removedJsonl
                    )
                } catch {
                    // Non-fatal: one bad file shouldn't stop the watcher.
                }
                await self.onFileChange?(change)
            }

            // Live process watcher; just fan the list out to the UI layer.
            await liveWatcher.start { [weak self] live in
                await self?.onLiveUpdate?(live)
            }
        }
    }

    public func stop() async {
        await fsWatcher.stop()
        await liveWatcher.stop()
    }
}
