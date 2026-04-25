import Foundation
import CoreServices

/// Summary of filesystem activity observed by `SessionsWatcher`. Produced at
/// most once per `latency` window; multiple rapid write/create events for
/// the same jsonl file coalesce into one entry.
public struct ChangeSet: Sendable, Equatable {
    public var changedJsonl: Set<URL>
    public var removedJsonl: Set<URL>
    public var changedWorkspaces: Set<String>

    public init(changedJsonl: Set<URL> = [],
                removedJsonl: Set<URL> = [],
                changedWorkspaces: Set<String> = []) {
        self.changedJsonl = changedJsonl
        self.removedJsonl = removedJsonl
        self.changedWorkspaces = changedWorkspaces
    }

    public var isEmpty: Bool {
        changedJsonl.isEmpty && removedJsonl.isEmpty && changedWorkspaces.isEmpty
    }
}

/// FSEventStream-based watcher over `~/.claude/projects/`. Emits a debounced
/// `ChangeSet` any time .jsonl files are created / modified / renamed /
/// deleted underneath the root. Safe to `start()` once; subsequent `start`
/// calls are no-ops until `stop()` is invoked.
public actor SessionsWatcher {
    // MARK: - Public API

    /// Callback delivered once per coalesced change window. Work dispatched
    /// here runs on the watcher's actor; long-running work should hop off.
    public typealias ChangeHandler = @Sendable (ChangeSet) async -> Void

    /// Root of the watched hierarchy. For Chronicle this is
    /// `~/.claude/projects/`.
    public let rootURL: URL

    /// Maximum delay between the first event of a burst and `onChange` being
    /// fired with the accumulated ChangeSet. Also the FSEventStream latency.
    public let latency: TimeInterval

    public init(rootURL: URL, latency: TimeInterval = 0.2) {
        self.rootURL = rootURL
        self.latency = latency
    }

    /// Start watching. The handler is retained and invoked until `stop()`.
    public func start(onChange: @escaping ChangeHandler) async {
        guard stream == nil else { return }
        handler = onChange
        pending = ChangeSet()
        createStream()
    }

    /// Tear down the FSEventStream and drop the handler. Safe to call when
    /// not running.
    public func stop() async {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        handler = nil
        pending = ChangeSet()
        debounceTask?.cancel()
        debounceTask = nil
    }

    // MARK: - Debounced delivery

    /// Called from the FSEvents C callback (which runs on the run loop that
    /// scheduled the stream). We route the parsed paths into `pending` and
    /// arm a one-shot debounce task.
    fileprivate func ingest(events: [WatcherEvent]) {
        for ev in events {
            if ev.isRemoved {
                pending.removedJsonl.insert(ev.url)
                pending.changedJsonl.remove(ev.url)
            } else {
                pending.changedJsonl.insert(ev.url)
                pending.removedJsonl.remove(ev.url)
            }
            if let ws = workspaceID(for: ev.url) {
                pending.changedWorkspaces.insert(ws)
            }
        }
        scheduleFlush()
    }

    private func scheduleFlush() {
        // Already armed; coalesce into the existing timer.
        if debounceTask != nil { return }
        let latencyNs = UInt64(max(0.01, latency) * 1_000_000_000)
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: latencyNs)
            await self?.flushPending()
        }
    }

    private func flushPending() async {
        debounceTask = nil
        let snapshot = pending
        pending = ChangeSet()
        guard !snapshot.isEmpty, let handler else { return }
        await handler(snapshot)
    }

    // MARK: - FSEventStream plumbing

    private var stream: FSEventStreamRef?
    private var handler: ChangeHandler?
    private var pending: ChangeSet = .init()
    private var debounceTask: Task<Void, Never>?

    private func createStream() {
        // Unretained `self` pointer passed into the C callback. The watcher
        // actor owns the stream and is responsible for invalidating it in
        // `stop()` before we're deallocated, so the unmanaged reference
        // remains valid for the lifetime of the stream.
        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        var context = FSEventStreamContext(
            version: 0,
            info: selfPtr,
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags: UInt32 = UInt32(kFSEventStreamCreateFlagFileEvents)
                          | UInt32(kFSEventStreamCreateFlagNoDefer)
                          | UInt32(kFSEventStreamCreateFlagUseCFTypes)

        let paths = [rootURL.path] as CFArray
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.callback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            return
        }
        // Schedule on a dedicated dispatch queue; we don't want to block the
        // main run loop with filesystem events. The debounce timer already
        // ensures the `onChange` handler is fired infrequently.
        FSEventStreamSetDispatchQueue(s, Self.dispatchQueue)
        FSEventStreamStart(s)
        self.stream = s
    }

    /// Dedicated serial queue for FSEvents callbacks. Keeps every event on a
    /// single background thread so we don't fight with SwiftUI's main queue.
    private static let dispatchQueue = DispatchQueue(label: "chronicle.sessions-watcher.fsevents")

    /// Raw C FSEventStreamCallback. Parses the incoming paths + flags and
    /// hands the structured result to the owning `SessionsWatcher` via its
    /// actor.
    private static let callback: FSEventStreamCallback = {
        (_, info, numEvents, eventPaths, eventFlags, _) in
        guard let info else { return }
        let watcher = Unmanaged<SessionsWatcher>.fromOpaque(info).takeUnretainedValue()

        // eventPaths is either a CFArray of CFString (when kFSEventStreamCreateFlagUseCFTypes
        // is set) or a C array of char*. We set UseCFTypes, so it's a CFArray.
        let cfArray = unsafeBitCast(eventPaths, to: CFArray.self)
        var events: [WatcherEvent] = []
        events.reserveCapacity(numEvents)
        for i in 0..<numEvents {
            let raw = CFArrayGetValueAtIndex(cfArray, i)
            guard let rawPtr = raw else { continue }
            let cfStr = unsafeBitCast(rawPtr, to: CFString.self)
            let path = cfStr as String
            // Filter: only .jsonl files under the watched root.
            guard path.hasSuffix(".jsonl") else { continue }
            let flags = eventFlags[i]
            let url = URL(fileURLWithPath: path)
            let removed = (flags & UInt32(kFSEventStreamEventFlagItemRemoved)) != 0
            // A rename out of the root looks like a removal of the old path.
            // The new path (if any) arrives as a separate event with
            // ItemRenamed + ItemCreated flags, and FSEvents does not
            // guarantee order. We treat ItemRemoved as "gone".
            events.append(WatcherEvent(url: url, isRemoved: removed))
        }
        if events.isEmpty { return }
        Task { await watcher.ingest(events: events) }
    }

    /// Small internal type; keeps the ingest path free of CF calls.
    fileprivate struct WatcherEvent {
        let url: URL
        let isRemoved: Bool
    }

    // MARK: - Helpers

    /// Derives the workspace ID (first path component under `rootURL`) for
    /// a given .jsonl path. Returns nil when the URL isn't under root.
    private func workspaceID(for url: URL) -> String? {
        let rootPath = rootURL.path
        let path = url.path
        guard path.hasPrefix(rootPath) else { return nil }
        let tail = path.dropFirst(rootPath.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let comps = tail.split(separator: "/")
        guard let first = comps.first else { return nil }
        return String(first)
    }
}
