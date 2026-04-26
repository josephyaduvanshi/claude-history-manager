import Foundation

/// Owns one watcher per available provider. Only the active provider's
/// watcher runs; switching providers stops the old watcher and starts
/// the new one. File-change events from any active provider fan into a
/// single onFileChange callback so the UI's smart-folder-counts refresh
/// works regardless of which provider fired.
@MainActor
public final class MultiProviderWatcherHub {
    private let repository: SessionsRepository
    private let projectsRoot: URL

    private let onWatcherStart: (@Sendable (ProviderID) async -> Void)?
    private let onWatcherStop: (@Sendable (ProviderID) async -> Void)?

    public var onFileChange: (@Sendable () async -> Void)?
    public var onClaudeLiveUpdate: (@Sendable ([SessionMetadata]) async -> Void)?

    private var claudeCoord: WatcherCoordinator?
    private var codexWatcher: CodexWatcher?
    private var geminiWatcher: GeminiWatcher?
    private var active: ProviderID?
    private var pendingTask: Task<Void, Never>?
    private var pendingTarget: ProviderID?

    public init(
        repository: SessionsRepository,
        projectsRoot: URL,
        onWatcherStart: (@Sendable (ProviderID) async -> Void)? = nil,
        onWatcherStop: (@Sendable (ProviderID) async -> Void)? = nil
    ) {
        self.repository = repository
        self.projectsRoot = projectsRoot
        self.onWatcherStart = onWatcherStart
        self.onWatcherStop = onWatcherStop
    }

    public func build(available: [ProviderID]) {
        if available.contains(.claude) {
            let coord = WatcherCoordinator(
                repository: repository,
                projectsRoot: projectsRoot,
                provider: .claude
            )
            coord.onFileChange = { [weak self] _ in
                await self?.onFileChange?()
            }
            coord.onLiveUpdate = { [weak self] live in
                await self?.onClaudeLiveUpdate?(live)
            }
            self.claudeCoord = coord
        }
        if available.contains(.codex) {
            self.codexWatcher = CodexWatcher()
        }
        if available.contains(.gemini) {
            self.geminiWatcher = GeminiWatcher()
        }
    }

    public func setActive(_ id: ProviderID) async {
        // Compare against the pending target if a switch is in flight,
        // otherwise the current `active`. This makes the early-out
        // accurate during a storm of overlapping setActive calls — e.g.
        // a rapid (codex, gemini, claude) burst from `claude` must
        // settle at claude, not silently drop the third click because
        // `active` hadn't been mutated yet.
        let intent = pendingTarget ?? active
        guard intent != id else { return }
        pendingTarget = id
        let previous = pendingTask
        let task = Task { @MainActor [weak self] in
            // Wait for the prior pending switch (if any) to fully drain
            // before mutating any state. This serialises overlapping
            // setActive calls so two of them can't both observe the same
            // `active` and produce duplicate watchers.
            await previous?.value
            guard let self else { return }
            if self.active == id { return }   // a later setActive already won
            let oldID = self.active
            // Mark intent immediately so a subsequent setActive's guard
            // doesn't double-stop the same provider.
            self.active = id
            if let oldID { await self.stopWatcher(for: oldID) }
            await self.startWatcher(for: id)
        }
        pendingTask = task
        await task.value
        // If this task was the most recently scheduled one, drop the
        // pending pointers so the next setActive sees a clean slate.
        if pendingTask == task {
            pendingTask = nil
            pendingTarget = nil
        }
    }

    public func stopAll() async {
        if let oldID = active { await stopWatcher(for: oldID) }
        active = nil
    }

    private func startWatcher(for id: ProviderID) async {
        switch id {
        case .claude:
            claudeCoord?.start()
        case .codex:
            await codexWatcher?.start { [weak self] change in
                guard let self else { return }
                do {
                    try await self.repository.incrementalReindex(
                        paths: change.changedJsonl,
                        workspaces: change.changedWorkspaces,
                        removedPaths: change.removedJsonl,
                        provider: .codex
                    )
                } catch {
                    // Non-fatal; one bad file shouldn't stop the watcher.
                }
                await self.onFileChange?()
            }
        case .gemini:
            await geminiWatcher?.start { [weak self] change in
                guard let self else { return }
                do {
                    try await self.repository.incrementalReindex(
                        paths: change.changedJsonl,
                        workspaces: change.changedWorkspaces,
                        removedPaths: change.removedJsonl,
                        provider: .gemini
                    )
                } catch {}
                await self.onFileChange?()
            }
        }
        await onWatcherStart?(id)
    }

    private func stopWatcher(for id: ProviderID) async {
        switch id {
        case .claude:
            await claudeCoord?.stop()
        case .codex:
            await codexWatcher?.stop()
        case .gemini:
            await geminiWatcher?.stop()
        }
        await onWatcherStop?(id)
    }
}
