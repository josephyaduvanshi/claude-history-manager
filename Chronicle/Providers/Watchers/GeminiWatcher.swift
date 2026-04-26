import Foundation
import CoreServices

/// Watches Gemini's session storage. Two channels:
///
///  1. **One FSEventStream per project's `chats/` dir** — Gemini writes
///     incrementally with `fs.appendFileSync`, so we have to retry
///     parsing on partial writes. The watcher just nudges; the parser
///     handles the retry. Hard-capped at 32 most-recently-modified
///     project dirs to keep kqueue / fseventsd happy on installs with
///     hundreds of projects.
///
///  2. **One DispatchSource on `~/.gemini/projects.json`** — fires when
///     a new project is registered. Triggers a re-discover so newly
///     added project dirs get a watcher attached without restarting.
///
/// Emits the same `ChangeSet` shape the Claude / Codex watchers do.
public actor GeminiWatcher {
    public typealias ChangeHandler = @Sendable (ChangeSet) async -> Void

    public let projectsFile: URL
    public let latency: TimeInterval
    public let maxConcurrentWatchers: Int

    public init(
        projectsFile: URL = GeminiProvider.projectsFile(),
        latency: TimeInterval = 0.2,
        maxConcurrentWatchers: Int = 32
    ) {
        self.projectsFile = projectsFile
        self.latency = latency
        self.maxConcurrentWatchers = maxConcurrentWatchers
    }

    private var perChatsWatchers: [URL: SessionsWatcher] = [:]
    private var projectsSource: DispatchSourceFileSystemObject?
    private var projectsFD: Int32 = -1
    private var handler: ChangeHandler?

    public func start(onChange: @escaping ChangeHandler) async {
        guard handler == nil else { return }
        handler = onChange
        await attachChatsWatchers()
        attachProjectsTail()
    }

    public func stop() async {
        for (_, w) in perChatsWatchers { await w.stop() }
        perChatsWatchers.removeAll()
        if let src = projectsSource { src.cancel(); projectsSource = nil }
        if projectsFD >= 0 { close(projectsFD); projectsFD = -1 }
        handler = nil
    }

    // MARK: - Chats watchers

    /// Pick the N most-recently-modified project dirs and attach an
    /// FSEvents stream to each `chats/` subdir. Cheaper than watching
    /// every project on a long-lived install.
    private func attachChatsWatchers() async {
        let dirs = GeminiProvider.discoverProjectDirs()
            .sorted { Self.modDate($0) > Self.modDate($1) }
            .prefix(maxConcurrentWatchers)
        let activeChatsURLs = Set(dirs.map { $0.appendingPathComponent("chats", isDirectory: true) })

        // Evict watchers whose dirs fell out of the top-N most-recent set.
        // Without this, a long-lived Chronicle install accumulates watchers
        // for every project ever active.
        for (chats, watcher) in perChatsWatchers where !activeChatsURLs.contains(chats) {
            await watcher.stop()
            perChatsWatchers.removeValue(forKey: chats)
        }

        // Attach watchers for newly-relevant dirs.
        for dir in dirs {
            let chats = dir.appendingPathComponent("chats", isDirectory: true)
            guard FileManager.default.fileExists(atPath: chats.path) else { continue }
            guard perChatsWatchers[chats] == nil else { continue }
            let w = SessionsWatcher(rootURL: chats, latency: latency, extensions: ["json"])
            await w.start { [weak self] change in
                await self?.deliver(change)
            }
            perChatsWatchers[chats] = w
        }
    }

    private static func modDate(_ url: URL) -> Date {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.modificationDate] as? Date) ?? .distantPast
    }

    // MARK: - projects.json tail

    /// Watch projects.json for changes — fires when Gemini registers a
    /// new cwd. We rebuild the project-dir watch list so newly added
    /// projects start streaming events without a Chronicle relaunch.
    private func attachProjectsTail() {
        let fd = open(projectsFile.path, O_EVTONLY)
        guard fd >= 0 else { return }
        projectsFD = fd

        let queue = DispatchQueue(label: "chronicle.gemini-watcher.projects-tail")
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            Task { [weak self] in await self?.refreshChatsWatchers() }
        }
        src.setCancelHandler { [fd] in close(fd) }
        src.resume()
        projectsSource = src
    }

    private func refreshChatsWatchers() async {
        await attachChatsWatchers()
        await handler?(ChangeSet())
    }

    private func deliver(_ change: ChangeSet) async {
        await handler?(change)
    }
}
