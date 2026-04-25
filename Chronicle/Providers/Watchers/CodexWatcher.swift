import Foundation
import CoreServices

/// Watches Codex's session storage for new and in-progress sessions.
///
/// Two channels:
///
///  1. **Tail of `~/.codex/session_index.jsonl`** — Codex appends one
///     line per new session as soon as it starts, so a `DispatchSource`
///     on the file gives near-instant new-session notifications without
///     scanning the date-bucketed `sessions/` tree. Cheaper than
///     FSEventStream over a directory of thousands of files.
///
///  2. **FSEvents over `~/.codex/sessions/`** — for in-progress writes
///     to existing rollout files. The tail-of-index approach above only
///     fires when a session starts; live-token-count updates land in
///     the rollout file and are picked up here. Reuses the existing
///     `SessionsWatcher` from v0.1.x with a different root.
///
/// The watcher emits a `ChangeSet` (same shape as the Claude watcher's),
/// so the indexer's incremental-reindex pipeline doesn't need to learn
/// new types.
public actor CodexWatcher {
    public typealias ChangeHandler = @Sendable (ChangeSet) async -> Void

    public let sessionsRoot: URL
    public let indexFile: URL
    public let latency: TimeInterval

    public init(
        sessionsRoot: URL = CodexWatcher.defaultSessionsRoot(),
        indexFile: URL = CodexWatcher.defaultIndexFile(),
        latency: TimeInterval = 0.2
    ) {
        self.sessionsRoot = sessionsRoot
        self.indexFile = indexFile
        self.latency = latency
    }

    public static func defaultSessionsRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    public static func defaultIndexFile() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/session_index.jsonl", isDirectory: false)
    }

    private var fsWatcher: SessionsWatcher?
    private var indexSource: DispatchSourceFileSystemObject?
    private var indexFD: Int32 = -1
    private var lastIndexSize: UInt64 = 0
    private var handler: ChangeHandler?

    /// Begin watching. Re-entrant: a second `start` call before `stop`
    /// is a no-op. The handler is retained until `stop()`.
    public func start(onChange: @escaping ChangeHandler) async {
        guard fsWatcher == nil else { return }
        handler = onChange

        // Channel 1: FSEvents tree watch via the existing SessionsWatcher.
        // Same coalescing semantics as the Claude path so the indexer
        // can use the same incrementalReindex entry point.
        let fs = SessionsWatcher(rootURL: sessionsRoot, latency: latency)
        await fs.start { [weak self] change in
            await self?.deliver(change)
        }
        fsWatcher = fs

        // Channel 2: tail the session_index.jsonl file. We only use this
        // to know that *something new appeared*; the actual rollout file
        // is picked up via the FSEvents channel above. So the index tail
        // doesn't have to parse new lines — it just nudges the indexer.
        attachIndexTail()
    }

    public func stop() async {
        await fsWatcher?.stop()
        fsWatcher = nil
        if let src = indexSource {
            src.cancel()
            indexSource = nil
        }
        if indexFD >= 0 {
            close(indexFD)
            indexFD = -1
        }
        handler = nil
    }

    // MARK: - Index tail

    /// Open `session_index.jsonl` as a kqueue-backed DispatchSource so
    /// any append fires our handler. The watch is best-effort: if the
    /// file doesn't exist yet (no Codex sessions ever recorded) we just
    /// skip — the FSEvents channel still catches activity inside
    /// `sessions/` once the user runs `codex` for the first time.
    private func attachIndexTail() {
        let path = indexFile.path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        indexFD = fd

        // Snapshot current size so we don't re-emit historical lines.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? UInt64 {
            lastIndexSize = size
        }

        let queue = DispatchQueue(label: "chronicle.codex-watcher.index-tail")
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.extend, .write, .delete, .rename],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            Task { [weak self] in await self?.indexFileChanged() }
        }
        src.setCancelHandler { [fd] in close(fd) }
        src.resume()
        indexSource = src
    }

    /// One nudge per index-file change. We don't read line content here
    /// — the FSEvents channel will pick up the new rollout file and
    /// send an entry through `deliver`. This keeps the index tail
    /// allocation-free in the hot path.
    private func indexFileChanged() async {
        // Guard against spurious wake-ups: only fire if the file grew.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: indexFile.path),
           let size = attrs[.size] as? UInt64 {
            if size > lastIndexSize {
                lastIndexSize = size
                // Surface a minimal ChangeSet — the indexer will re-scan
                // sessionsRoot and pick up the new rollout file.
                await handler?(ChangeSet(changedWorkspaces: [sessionsRoot.lastPathComponent]))
            } else if size < lastIndexSize {
                // Truncation: file rotated. Reset the size cursor and
                // let the next event fire normally.
                lastIndexSize = size
            }
        }
    }

    private func deliver(_ change: ChangeSet) async {
        await handler?(change)
    }
}
