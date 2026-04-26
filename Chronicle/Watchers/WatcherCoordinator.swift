import Foundation

/// Glue that owns the two Plan-07 watchers and feeds their events into the
/// repository + AppState. Lives for the app process' lifetime. The main app
/// creates one at startup and retains it via `@State` on the `App` struct.
///
/// Bug 1: the coordinator now passes its bound `provider` through to
/// `incrementalReindex(...)` so writes are scoped to whichever tree this
/// watcher is watching, rather than `repository.currentProvider` (which
/// reflects the segmented control's selection and changes whenever the
/// user toggles providers).
@MainActor
public final class WatcherCoordinator {
    private let repository: SessionsRepository
    private let projectsRoot: URL
    /// Provider whose on-disk tree this coordinator watches. Today only
    /// `~/.claude/projects/` is wired into the live indexer, so this is
    /// effectively `.claude`. Plumbed as a parameter so the Codex /
    /// Gemini watchers can be wired up later without re-tagging Claude
    /// rows by mistake.
    private let provider: ProviderID
    private let fsWatcher: SessionsWatcher
    private let liveWatcher: LiveSessionsWatcher

    /// Callbacks the UI wires in at construction time; keeps this module
    /// free of direct AppState knowledge.
    public var onFileChange: (@Sendable (ChangeSet) async -> Void)?
    public var onLiveUpdate: (@Sendable ([SessionMetadata]) async -> Void)?

    public init(repository: SessionsRepository,
                projectsRoot: URL,
                provider: ProviderID = .claude) {
        self.repository = repository
        self.projectsRoot = projectsRoot
        self.provider = provider
        self.fsWatcher = SessionsWatcher(rootURL: projectsRoot, latency: 0.25)
        self.liveWatcher = LiveSessionsWatcher(repository: repository, pollInterval: 2.0)
    }

    public func start() {
        let watchedProvider = self.provider
        Task { [fsWatcher, liveWatcher, repository, watchedProvider] in
            // File system watcher; re-parse + update session_flags for any
            // .jsonl that changed, drop rows for any that disappeared.
            await fsWatcher.start { [weak self] change in
                guard let self else { return }
                do {
                    try await repository.incrementalReindex(
                        paths: change.changedJsonl,
                        workspaces: change.changedWorkspaces,
                        removedPaths: change.removedJsonl,
                        provider: watchedProvider
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
