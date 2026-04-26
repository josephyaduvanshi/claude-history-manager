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
        guard active != id else { return }
        if let oldID = active { await stopWatcher(for: oldID) }
        await startWatcher(for: id)
        active = id
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
