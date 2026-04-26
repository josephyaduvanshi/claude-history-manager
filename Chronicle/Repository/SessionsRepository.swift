import Foundation
import GRDB

/// Composite repository protocol.
///
/// R1 of the SOLID refactor split the (formerly) monolithic surface into
/// five focused sub-protocols (`WorkspaceRepositoryProtocol`,
/// `SessionsReadProtocol`, `TagsRepositoryProtocol`,
/// `SmartFolderRepositoryProtocol`, `UserMetadataRepositoryProtocol` , 
/// see `SessionsRepositoryProtocols.swift`). The composite inherits all
/// five so callers that need the full surface still get one type to depend
/// on, while narrower callers can name only the sub-protocol they need.
///
/// Methods that don't fit cleanly into any sub-protocol; incremental
/// reindex, hard-purge of expired deletes, the Plan 08 stats surface, and
/// `tagCounts()`, live directly on the composite. The single concrete
/// `SessionsRepository` actor below conforms to the composite, which by
/// inheritance means it conforms to every sub-protocol for free.
public protocol SessionsRepositoryProtocol:
    WorkspaceRepositoryProtocol,
    SessionsReadProtocol,
    TagsRepositoryProtocol,
    SmartFolderRepositoryProtocol,
    UserMetadataRepositoryProtocol,
    Sendable
{
    func tagCounts() async throws -> [Int64: Int]

    func hardPurgeExpiredDeletes(olderThan days: Int) async throws

    /// Incrementally re-parses the given paths and updates `sessions_index`
    /// + `session_flags`. Rows for `removedPaths` are dropped (workspace FK
    /// preserved). Idempotent: re-applying the same paths does not duplicate.
    ///
    /// Implementations writing into a multi-provider DB should prefer the
    /// `provider:`-tagged overload below so the watcher coordinator's writes
    /// are scoped to the provider it's watching for, rather than picking up
    /// whichever provider happens to be active at flush time.
    func incrementalReindex(paths: Set<URL>,
                            workspaces: Set<String>,
                            removedPaths: Set<URL>) async throws

    /// Provider-scoped variant of `incrementalReindex`. The filesystem
    /// watcher passes the provider it is dedicated to (e.g. `.claude` for
    /// the `~/.claude/projects/` watcher) so writes never get mis-tagged
    /// with the active provider.
    ///
    /// Default implementation forwards to the legacy 3-arg version so test
    /// stubs that predate this overload keep working unmodified.
    func incrementalReindex(paths: Set<URL>,
                            workspaces: Set<String>,
                            removedPaths: Set<URL>,
                            provider: ProviderID) async throws

    // MARK: - Plan 08 — Stats

    /// Per-workspace summary, ordered by total tokens descending.
    func statsByWorkspace() async throws -> [WorkspaceStats]
    /// 24×7 heatmap buckets across the last `days` days (local TZ).
    func hourWeekdayHeatmap(days: Int) async throws -> [HeatmapCell]
    /// One cell per day for the last `days` days (oldest → newest).
    func calendarHeatmap(days: Int) async throws -> [CalendarHeatmapCell]
    /// Totals for the header trio: sessions · tokens · estimated USD cost.
    func totalStats() async throws -> (sessions: Int, tokens: Int, estimatedCostUSD: Double)
    /// Tokens + cost split by model. Sonnet vs Opus etc.
    func statsByModel() async throws -> [(model: String, tokens: Int, cost: Double)]
}

/// Default no-op implementations so test stubs don't have to implement the
/// Plan 08 Stats surface. The real `SessionsRepository` provides concrete
/// SQL-backed implementations in `Stats/SessionsRepository+Stats.swift`.
public extension SessionsRepositoryProtocol {
    /// Default forwarder so older conformers (test mocks) that only
    /// implement the 3-arg `incrementalReindex` keep compiling. Drops
    /// the explicit provider hint, which is fine for tests that don't
    /// exercise the multi-provider scoping invariant.
    func incrementalReindex(paths: Set<URL>,
                            workspaces: Set<String>,
                            removedPaths: Set<URL>,
                            provider: ProviderID) async throws {
        try await incrementalReindex(
            paths: paths,
            workspaces: workspaces,
            removedPaths: removedPaths
        )
    }

    /// Default stub for test repositories; real impl overrides.
    func totalSessionCount() async throws -> Int { 0 }

    /// Default stub so test repositories don't have to implement
    /// `archivedCount()` on the `UserMetadataRepositoryProtocol` surface.
    /// The real `SessionsRepository` overrides this with a SQL count.
    func archivedCount() async throws -> Int { 0 }

    func statsByWorkspace() async throws -> [WorkspaceStats] { [] }
    func hourWeekdayHeatmap(days: Int = 90) async throws -> [HeatmapCell] { [] }
    func calendarHeatmap(days: Int = 90) async throws -> [CalendarHeatmapCell] { [] }
    func totalStats() async throws -> (sessions: Int, tokens: Int, estimatedCostUSD: Double) {
        (0, 0, 0.0)
    }
    func statsByModel() async throws -> [(model: String, tokens: Int, cost: Double)] { [] }
}

public actor SessionsRepository: SessionsRepositoryProtocol {
    // MARK: - Errors

    public enum BootstrapError: LocalizedError {
        case targetDirectoryUnreadableOrEmpty(URL)
        case noWorkspacesFound(URL)

        public var errorDescription: String? {
            switch self {
            case .targetDirectoryUnreadableOrEmpty(let url):
                return """
                    Cannot read directory at \(url.path). \
                    Grant Full Disk Access to Chronicle in \
                    System Settings → Privacy & Security → Full Disk Access.
                    """
            case .noWorkspacesFound(let url):
                return """
                    No workspace folders found at \(url.path). \
                    Ensure ~/.claude/projects/ contains at least one project folder.
                    """
            }
        }
    }

    // MARK: - Properties

    private let database: any DatabaseWriter
    private let parser: JsonlParser
    private let decoder: WorkspacePathDecoder
    private let fm = FileManager.default

    /// Root of `~/.claude/projects/`, used to locate a session's `.jsonl`
    /// file when soft-deleting (so the file can be moved to Trash). Nil when
    /// the repository is constructed without a concrete projects root (unit
    /// tests that don't exercise soft-delete supply nil and softDelete
    /// gracefully no-ops the filesystem step).
    private let projectsRoot: URL?

    /// Test-only vendor of the underlying DatabaseWriter so test helpers can
    /// seed fake rows without round-tripping through real jsonl. Not intended
    /// for production use.
    internal var databaseForTests: any DatabaseWriter { database }

    /// Optional FTS index. When set, `search(query:)` can answer `/full:` queries
    /// by transparently indexing-on-demand. Nil in tests or when FTS is unused.
    private let ftsIndex: FtsIndex?

    /// Errors collected during the most recent bootstrap run (per-workspace / per-file failures).
    private var _bootstrapErrors: [String] = []

    /// Provider whose data this repository is currently reading and writing.
    /// AppState calls `setActiveProvider(_:)` whenever the user clicks a
    /// segmented-control button. Defaults to `.claude` so v0.1.x callers
    /// (and existing tests that don't know about providers) keep working.
    ///
    /// Internal SQL gates `INSERT` payloads on this value and adds
    /// `WHERE provider = ?` to reads, so swapping providers cleanly swaps
    /// the data surface without touching any public API.
    private var currentProvider: ProviderID = .claude

    // MARK: - Init

    public init(database: any DatabaseWriter,
                parser: JsonlParser,
                decoder: WorkspacePathDecoder,
                ftsIndex: FtsIndex? = nil,
                projectsRoot: URL? = nil) {
        self.database = database
        self.parser = parser
        self.decoder = decoder
        self.ftsIndex = ftsIndex
        self.projectsRoot = projectsRoot
    }

    /// Switch the active provider for subsequent reads and writes. Called
    /// from `AppState.switchTo(_:)` whenever the user picks a different
    /// provider in the segmented control or menubar tile grid.
    public func setActiveProvider(_ id: ProviderID) {
        self.currentProvider = id
    }

    /// Test/diagnostic accessor — returns whichever provider is currently
    /// scoping queries. Used by `MultiProviderMigrationTests` to assert
    /// the default is `.claude`.
    public func activeProvider() -> ProviderID {
        currentProvider
    }

    /// Absolute on-disk path of a session's transcript file, recorded
    /// at index time. Returns `nil` for Claude rows (which fall back to
    /// the canonical `projectsRoot/<workspaceID>/<sessionID>.jsonl`
    /// path) and for any session indexed before v10. Used by
    /// `TranscriptRepository` so it can re-open Codex / Gemini files
    /// whose locations aren't reconstructible from
    /// `(workspace_id, sessionID)` alone.
    public func sessionFilePath(
        forSessionID sessionID: SessionID,
        provider: ProviderID
    ) async throws -> String? {
        let providerKey = provider.rawValue
        let sid = sessionID.description
        return try await database.read { [providerKey, sid] db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT file_path FROM sessions_index
                    WHERE provider = ? AND session_id = ?
                    """,
                arguments: [providerKey, sid]
            )
        }
    }

    // MARK: - Protocol

    public func bootstrap(rootURL: URL) async throws {
        try await bootstrap(rootURL: rootURL, progress: nil)
    }

    // MARK: - Parallel indexing helpers (Bug 8)

    /// One workspace's parsed results. Sendable so TaskGroup can return it.
    struct WorkspaceData: Sendable {
        let id: String
        let decoded: WorkspacePathDecoder.Result
        let indexedAt: Date
        let sessions: [ParsedSession]
        /// Authoritative cwd / gitBranch / version sniffed out of the first
        /// jsonl in this workspace that actually had it. Nil when no jsonl
        /// in the workspace recorded a cwd field.
        let metadata: JsonlParser.WorkspaceMetadata?
    }

    struct ParsedSession: Sendable {
        let metadata: SessionMetadata
        let size: Int
        let mtime: Date
        let flags: Set<String>
        /// Absolute on-disk path of the session's transcript file, recorded
        /// at index time. Required for Codex / Gemini because their on-disk
        /// layout isn't reconstructible from `(workspace_id, sessionID)`.
        /// Nil for Claude sessions, which still resolve via the canonical
        /// `projectsRoot/<workspaceID>/<sessionID>.jsonl` path.
        let filePath: String?

        init(
            metadata: SessionMetadata,
            size: Int,
            mtime: Date,
            flags: Set<String>,
            filePath: String? = nil
        ) {
            self.metadata = metadata
            self.size = size
            self.mtime = mtime
            self.flags = flags
            self.filePath = filePath
        }
    }

    struct WorkspaceParseResult: Sendable {
        let data: WorkspaceData
        let errors: [String]
        /// Number of jsonl files whose `(size, mtime)` matched the cached
        /// `sessions_index` row and were therefore not re-parsed.
        let skipped: Int
        /// Number of jsonl files that were actually parsed (cache miss or
        /// content changed since last bootstrap).
        let parsed: Int
        /// Every session_id observed on disk in this workspace this run
        /// (regardless of skip vs parse). Used by the bootstrap reaper to
        /// drop orphan rows whose jsonl no longer exists.
        let seenSessionIDs: Set<String>
    }

    /// Pure helper that writes one parsed workspace + its sessions into the
    /// supplied open `Database`. Used by `bootstrap` so a single transaction
    /// can fold all 35 workspaces into one BEGIN/COMMIT (one fsync) instead
    /// of one transaction per workspace.
    ///
    /// The `provider` argument scopes every write to the active provider so
    /// re-running bootstrap for Codex / Gemini doesn't clobber Claude rows
    /// (and vice versa). Existing v0.1.x rows already have `provider='claude'`
    /// thanks to the v9 column default, so passing `.claude` here continues
    /// to upsert the same rows.
    static func writeWorkspace(
        _ wd: WorkspaceData,
        provider: ProviderID,
        into db: GRDB.Database
    ) throws {
        let providerKey = provider.rawValue
        try db.execute(
            sql: """
            INSERT INTO workspaces
                (id, decoded_path, "group", display_name, indexed_at,
                 cwd, git_branch, claude_version, provider)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                decoded_path = excluded.decoded_path,
                "group" = excluded."group",
                display_name = excluded.display_name,
                indexed_at = excluded.indexed_at,
                cwd = COALESCE(excluded.cwd, workspaces.cwd),
                git_branch = COALESCE(excluded.git_branch, workspaces.git_branch),
                claude_version = COALESCE(excluded.claude_version, workspaces.claude_version),
                provider = excluded.provider
            """,
            arguments: [
                wd.id,
                wd.decoded.decodedPath,
                wd.decoded.group,
                wd.decoded.displayName,
                wd.indexedAt,
                wd.metadata?.cwd,
                wd.metadata?.gitBranch,
                wd.metadata?.version,
                providerKey,
            ]
        )

        for entry in wd.sessions {
            let m = entry.metadata
            try db.execute(sql: """
                INSERT INTO sessions_index
                    (session_id, workspace_id, title, created_at, last_modified_at,
                     message_count, token_count, file_size_bytes, file_mtime,
                     total_input_tokens, total_output_tokens, model, provider, file_path)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(session_id) DO UPDATE SET
                    title = excluded.title,
                    last_modified_at = excluded.last_modified_at,
                    message_count = excluded.message_count,
                    token_count = excluded.token_count,
                    file_size_bytes = excluded.file_size_bytes,
                    file_mtime = excluded.file_mtime,
                    total_input_tokens = excluded.total_input_tokens,
                    total_output_tokens = excluded.total_output_tokens,
                    model = COALESCE(excluded.model, sessions_index.model),
                    provider = excluded.provider,
                    file_path = COALESCE(excluded.file_path, sessions_index.file_path)
                """,
                arguments: [m.sessionID.description, wd.id, m.title,
                            m.createdAt, m.lastModifiedAt,
                            m.messageCount, m.tokenCount, entry.size,
                            // file_mtime is REAL (epoch seconds) since v8; bind as
                            // Double so APFS sub-second precision survives the round
                            // trip. (GRDB's default Date binding is ISO-8601 TEXT,
                            // which truncates to 1ms granularity.)
                            entry.mtime.timeIntervalSince1970,
                            m.inputTokens, m.outputTokens, m.model,
                            providerKey,
                            // NULL for Claude (the canonical projectsRoot path is
                            // sufficient); the absolute URL string for Codex and
                            // Gemini, whose on-disk layouts aren't reconstructible
                            // from `(workspace_id, sessionID)` alone.
                            entry.filePath])

            let sid = m.sessionID.description
            try db.execute(sql: "DELETE FROM session_flags WHERE session_id = ? AND provider = ?",
                           arguments: [sid, providerKey])
            for flag in entry.flags {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO session_flags (session_id, flag_name, provider) VALUES (?, ?, ?)
                    """, arguments: [sid, flag, providerKey])
            }
        }
    }

    /// Per-file attrs cached from the previous bootstrap (read out of
    /// sessions_index at the start of each run). Used to skip re-parsing files
    /// whose `(size, mtime)` haven't changed since they were last indexed.
    /// Keyed by session_id (= jsonl filename without extension).
    struct CachedFileAttrs: Sendable {
        let size: Int
        let mtime: Date
    }

    /// Pure helper that parses one workspace's jsonl files. Runs off-actor
    /// inside TaskGroup tasks so N workspaces parse concurrently. Takes the
    /// parser + decoder as arguments (copied by value) rather than reading
    /// them through actor-isolated `self`.
    ///
    /// `cachedAttrs` lets us skip parsing files whose size + mtime haven't
    /// changed since the last bootstrap; those rows are already in DB. Pass
    /// an empty dict to force-reparse everything (cold start / repair).
    ///
    /// `cachedWorkspaceMeta` lets us skip the metadata sniff pass entirely
    /// when the workspaces table already has cwd/gitBranch/version for this
    /// workspace id. The metadata sniff reads the top-5 largest jsonl files
    /// per workspace and is the dominant cost on warm boots when those files
    /// are large. New workspaces (no cache entry) still fall through to the
    /// existing sniff path.
    static func indexWorkspace(
        folder: URL,
        parser: JsonlParser,
        decoder: WorkspacePathDecoder,
        cachedAttrs: [String: CachedFileAttrs],
        cachedWorkspaceMeta: [String: JsonlParser.WorkspaceMetadata] = [:]
    ) -> WorkspaceParseResult {
        let id = folder.lastPathComponent
        let decoded = decoder.decode(id)
        let now = Date()
        let fm = FileManager.default

        var errors: [String] = []
        var sessionEntries: [ParsedSession] = []
        var workspaceMeta: JsonlParser.WorkspaceMetadata? = nil
        var skippedCount = 0
        var parsedCount = 0
        var seenSessionIDs: Set<String> = []

        let sessionFiles: [URL]
        do {
            sessionFiles = try fm.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
            ).filter { url in
                guard url.pathExtension == "jsonl" else { return false }
                // Skip non-UUID filenames (e.g. `agent-<id>.jsonl` subagent
                // transcripts). SessionID requires UUID-shaped IDs and would
                // otherwise spam parse errors for every non-conforming file.
                let stem = url.deletingPathExtension().lastPathComponent
                return UUID(uuidString: stem) != nil
            }
        } catch {
            errors.append("Could not list sessions in \(id): \(error.localizedDescription)")
            return WorkspaceParseResult(
                data: WorkspaceData(id: id, decoded: decoded, indexedAt: now,
                                    sessions: [], metadata: nil),
                errors: errors,
                skipped: 0,
                parsed: 0,
                seenSessionIDs: []
            )
        }

        // Pre-compute size-sorted file list so both the metadata sniff path
        // and the cache-hit branch refresh can cheaply pick the largest jsonl.
        // Larger files are more likely to actually contain `cwd` / `gitBranch`
        // since permission-mode-only stubs tend to be tiny.
        let sortedForMeta = sessionFiles.sorted { lhs, rhs in
            let lSize = (try? lhs.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            let rSize = (try? rhs.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return lSize > rSize
        }

        // Fast path; if the workspaces table already has authoritative cwd
        // for this workspace id, reuse cwd + claude_version (those rarely
        // change). gitBranch, however, mutates on every `git switch`, so we
        // still re-sniff it from the SINGLE largest jsonl on every bootstrap.
        // The sniff is one bounded 32 KB read via `extractWorkspaceMetadata`
        //; dramatically cheaper than the cold-path 5-file scan, but still
        // catches branch changes that happened while the app was closed.
        if let cached = cachedWorkspaceMeta[id], cached.cwd != nil {
            var freshBranch: String? = nil
            if let largest = sortedForMeta.first,
               let fresh = parser.extractWorkspaceMetadata(url: largest) {
                freshBranch = fresh.gitBranch
            }
            workspaceMeta = JsonlParser.WorkspaceMetadata(
                cwd: cached.cwd,
                // Use the freshly-sniffed branch when present; otherwise fall
                // back to whatever was cached (e.g. no jsonls in workspace,
                // or sniff failed). This keeps the branch live across
                // `git switch` calls performed while Chronicle was closed.
                gitBranch: freshBranch ?? cached.gitBranch,
                version: cached.version
            )
        } else {
            // Cold path; pull workspace metadata from the largest jsonl that
            // has any. Bigger sessions are more likely to actually contain a
            // `cwd` field; the first file alphabetically may be a
            // permission-mode-only stub.
            for candidate in sortedForMeta.prefix(5) {
                if let meta = parser.extractWorkspaceMetadata(url: candidate),
                   (meta.cwd != nil || meta.gitBranch != nil || meta.version != nil) {
                    workspaceMeta = meta
                    if meta.cwd != nil { break }
                }
            }
        }

        for file in sessionFiles {
            let attrs = (try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]))
            let size = attrs?.fileSize ?? 0
            let mtime = attrs?.contentModificationDate ?? now

            // Skip parsing if (size, mtime) match the cached row. DB already
            // has correct data for this session, no need to re-read or re-write.
            // 50ms tolerance is well within APFS mtime resolution now that
            // `file_mtime` is stored as REAL (epoch seconds) instead of
            // ISO-8601 TEXT; the previous 1.0s slop existed only because
            // GRDB's TEXT serialization rounded sub-second precision away.
            let sessionID = file.deletingPathExtension().lastPathComponent
            seenSessionIDs.insert(sessionID)
            if let cached = cachedAttrs[sessionID],
               cached.size == size,
               abs(cached.mtime.timeIntervalSince(mtime)) < 0.05 {
                skippedCount += 1
                continue
            }

            do {
                let (metadata, flags) = try parser.parseWithFlags(url: file, workspaceID: id)
                sessionEntries.append(
                    ParsedSession(metadata: metadata, size: size, mtime: mtime, flags: flags)
                )
                parsedCount += 1
            } catch {
                errors.append(
                    "Parse error in \(id)/\(file.lastPathComponent): \(error.localizedDescription)"
                )
            }
        }

        return WorkspaceParseResult(
            data: WorkspaceData(id: id, decoded: decoded, indexedAt: now,
                                sessions: sessionEntries, metadata: workspaceMeta),
            errors: errors,
            skipped: skippedCount,
            parsed: parsedCount,
            seenSessionIDs: seenSessionIDs
        )
    }

    /// Overload that reports incremental progress. Callback is invoked on
    /// the repository's actor context (caller should hop to MainActor if
    /// mutating SwiftUI state). `progress` ranges [0, 1]; `message` is a
    /// human-readable "Indexed N of M workspaces" line.
    public func bootstrap(
        rootURL: URL,
        progress: (@Sendable (_ fraction: Double, _ message: String) -> Void)?
    ) async throws {
        _bootstrapErrors = []

        // ── Step A: Scan filesystem OUTSIDE the write lock ───────────────────
        progress?(0.0, "Scanning \(rootURL.path)")
        let folders: [URL]
        do {
            folders = try fm.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        } catch {
            throw BootstrapError.targetDirectoryUnreadableOrEmpty(rootURL)
        }

        guard !folders.isEmpty else {
            throw BootstrapError.noWorkspacesFound(rootURL)
        }

        // Snapshot what's already indexed so the parser can skip unchanged
        // files. One small SELECT; cheap. Subsequent boots become near-instant
        // because no jsonl content has to be read at all for unchanged files.
        //
        // Bug 1: this method walks `~/.claude/projects/`, so the data it
        // produces is unambiguously Claude. Hardcode `.claude` here instead
        // of reading `currentProvider`, otherwise a user who toggled to Codex
        // before relaunch would see this bootstrap pull cached attrs scoped
        // to Codex (always empty → full re-parse) and write Claude rows
        // tagged as Codex.
        let cachedAttrs: [String: CachedFileAttrs]
        let providerKey = ProviderID.claude.rawValue
        do {
            cachedAttrs = try await database.read { [providerKey] db in
                var map: [String: CachedFileAttrs] = [:]
                let cursor = try Row.fetchCursor(
                    db,
                    sql: "SELECT session_id, file_size_bytes, file_mtime FROM sessions_index WHERE provider = ?",
                    arguments: [providerKey]
                )
                while let row = try cursor.next() {
                    let sid: String = row[0]
                    let size: Int = row[1] ?? 0
                    // file_mtime is REAL (epoch seconds) since v8; read as
                    // Double and rebuild the Date locally so we keep
                    // sub-millisecond precision. Falls back to .distantPast
                    // on older rows that haven't been re-stamped yet (their
                    // (size, mtime) won't match anyway, so they re-parse).
                    let mtime: Date
                    if let secs: Double = row[2] {
                        mtime = Date(timeIntervalSince1970: secs)
                    } else {
                        mtime = .distantPast
                    }
                    map[sid] = CachedFileAttrs(size: size, mtime: mtime)
                }
                return map
            }
        } catch {
            cachedAttrs = [:]
        }

        AppLogger.app.info("Bootstrap cache: loaded \(cachedAttrs.count) entries from sessions_index")

        // Load already-known workspace metadata from the workspaces table so
        // indexWorkspace can skip the per-workspace metadata sniff (which
        // otherwise reads the top-5 largest jsonl files for every workspace).
        // Only rows with at least one non-nil field are useful; a NULL row
        // means we still need to sniff, so filter at the SQL level.
        let cachedWorkspaceMeta: [String: JsonlParser.WorkspaceMetadata]
        do {
            cachedWorkspaceMeta = try await database.read { [providerKey] db in
                var map: [String: JsonlParser.WorkspaceMetadata] = [:]
                let cursor = try Row.fetchCursor(
                    db,
                    sql: """
                        SELECT id, cwd, git_branch, claude_version
                        FROM workspaces
                        WHERE provider = ?
                          AND (cwd IS NOT NULL
                               OR git_branch IS NOT NULL
                               OR claude_version IS NOT NULL)
                        """,
                    arguments: [providerKey]
                )
                while let row = try cursor.next() {
                    let wid: String = row[0]
                    let cwd: String? = row[1]
                    let branch: String? = row[2]
                    let version: String? = row[3]
                    map[wid] = JsonlParser.WorkspaceMetadata(
                        cwd: cwd,
                        gitBranch: branch,
                        version: version
                    )
                }
                return map
            }
        } catch {
            cachedWorkspaceMeta = [:]
        }

        AppLogger.app.info(
            "Bootstrap cache: loaded \(cachedWorkspaceMeta.count) workspace metadata entries"
        )

        // ── Diagnostic: GRDB Date round-trip check ──────────────────────────
        // Pick the first cached entry, locate its jsonl on disk, and compare
        // the stored mtime against the live FS mtime. If they don't compare
        // equal (within sub-second tolerance), Date precision through GRDB's
        // ISO8601 datetime serialization is busting the skip-on-mtime cache.
        if let (sampleSID, sampleCached) = cachedAttrs.first {
            var foundFS: Date? = nil
            for folder in folders {
                let candidate = folder.appendingPathComponent("\(sampleSID).jsonl")
                if let attrs = try? candidate.resourceValues(forKeys: [.contentModificationDateKey]),
                   let m = attrs.contentModificationDate {
                    foundFS = m
                    break
                }
            }
            if let fs = foundFS {
                let stored = sampleCached.mtime
                let exact = stored == fs
                let delta = stored.timeIntervalSince(fs)
                AppLogger.app.info(
                    "Sample cache check: stored=\(stored), fs=\(fs), match=\(exact), deltaSeconds=\(delta)"
                )
            } else {
                AppLogger.app.info(
                    "Sample cache check: could not locate jsonl on disk for session_id=\(sampleSID)"
                )
            }
        }

        // ── Step B: Parse session files in PARALLEL ──────────────────────────
        // Each workspace's jsonl parsing is pure file I/O + CPU work; no
        // shared mutable state across workspaces; so we fan out across a
        // bounded TaskGroup. Files whose (size, mtime) match the cached
        // sessions_index row are skipped entirely (no read, no write).
        let originalFolders = folders
        let indexTotal = originalFolders.count
        let maxConcurrency = min(8, ProcessInfo.processInfo.activeProcessorCount)

        // Capture Sendable values explicitly so the detached tasks don't
        // close over `self` (which is an actor and would serialize).
        let parserCopy = parser
        let decoderCopy = decoder
        let cachedAttrsCopy = cachedAttrs
        let cachedWorkspaceMetaCopy = cachedWorkspaceMeta

        var workspaceDataList: [WorkspaceData] = []
        workspaceDataList.reserveCapacity(indexTotal)
        var collectedErrors: [String] = []
        var completed = 0
        var totalSkipped = 0
        var totalParsed = 0
        // Union of every session_id we observed on disk this run. Used by the
        // post-write reaper to drop sessions_index rows whose jsonl is gone.
        var seenSessionIDs: Set<String> = []

        try await withThrowingTaskGroup(of: WorkspaceParseResult.self) { group in
            var iterator = originalFolders.makeIterator()

            // Prime the pool up to the concurrency ceiling.
            var inFlight = 0
            func enqueueNext() {
                guard let folder = iterator.next() else { return }
                inFlight += 1
                group.addTask {
                    Self.indexWorkspace(folder: folder,
                                        parser: parserCopy,
                                        decoder: decoderCopy,
                                        cachedAttrs: cachedAttrsCopy,
                                        cachedWorkspaceMeta: cachedWorkspaceMetaCopy)
                }
            }
            for _ in 0..<min(maxConcurrency, indexTotal) { enqueueNext() }

            while let result = try await group.next() {
                inFlight -= 1
                workspaceDataList.append(result.data)
                collectedErrors.append(contentsOf: result.errors)
                totalSkipped += result.skipped
                totalParsed += result.parsed
                seenSessionIDs.formUnion(result.seenSessionIDs)
                completed += 1
                // Progress covers the 0.0..0.5 range. DB write pass covers 0.5..1.0.
                let frac = Double(completed) / Double(indexTotal) * 0.5
                progress?(frac, "Indexed \(completed) of \(indexTotal) workspaces")
                enqueueNext()
            }
        }

        _bootstrapErrors.append(contentsOf: collectedErrors)

        let totalFiles = totalSkipped + totalParsed
        AppLogger.app.info(
            "Bootstrap parse pass: skipped=\(totalSkipped), parsed=\(totalParsed) of \(totalFiles) files"
        )

        // ── Step C: Write all workspaces in ONE transaction ──────────────────
        // Previously each workspace got its own database.write {}; that's one
        // BEGIN/COMMIT per workspace and one fsync per COMMIT, which dominated
        // the bootstrap wall-clock (~10s splash for 35 workspaces). Folding
        // every workspace + its sessions into a single transaction collapses
        // 35 fsyncs into 1. Per-workspace failures are still tolerated: if a
        // single workspace's writes throw, we rethrow inside the closure to
        // roll back its mutations only by reattempting that workspace alone
        // in a fallback pass, while keeping the fast path for the rest.
        let wdTotal = max(1, Double(workspaceDataList.count))
        var failedWorkspaces: [WorkspaceData] = []
        // Bug 1: the Claude bootstrap walks `~/.claude/projects/` and is
        // unambiguously Claude data. Pin the provider tag to `.claude`
        // here rather than reading `currentProvider`, otherwise a user
        // who relaunched while Codex was selected would have these rows
        // mis-tagged as Codex.
        let activeProvider: ProviderID = .claude

        do {
            try await database.write { [activeProvider] db in
                for (idx, wd) in workspaceDataList.enumerated() {
                    // Per-workspace SAVEPOINT so a single bad workspace can
                    // roll back without aborting the whole bulk transaction.
                    do {
                        try db.inSavepoint {
                            try Self.writeWorkspace(wd, provider: activeProvider, into: db)
                            return .commit
                        }
                    } catch {
                        failedWorkspaces.append(wd)
                    }
                    let frac = 0.5 + Double(idx + 1) / wdTotal * 0.5
                    progress?(frac, "Indexed \(idx + 1) of \(workspaceDataList.count) workspaces")
                }
            }
        } catch {
            // The whole bulk transaction failed; fall back to per-workspace
            // writes so we still index whatever we can.
            _bootstrapErrors.append(
                "Bulk bootstrap transaction failed (\(error.localizedDescription)); falling back per-workspace."
            )
            failedWorkspaces = workspaceDataList
        }

        for wd in failedWorkspaces {
            do {
                try await database.write { [activeProvider] db in
                    try Self.writeWorkspace(wd, provider: activeProvider, into: db)
                }
            } catch {
                _bootstrapErrors.append(
                    "DB write failed for workspace \(wd.id): \(error.localizedDescription)"
                )
            }
        }

        // ── Step C.5: Reap orphan rows ──────────────────────────────────────
        // A jsonl deleted while Chronicle was closed leaves its sessions_index
        // row behind forever; the parse pass only knows about files that
        // exist. Compare what we actually saw on disk this run against the
        // cache snapshot (which mirrors what was in DB at boot start) and
        // drop any session_id present in the DB but absent from disk.
        //
        // Skip on cold start (cachedAttrs empty); there's nothing in DB to
        // reap and we'd otherwise nuke every just-written row whose
        // workspace failed to list. New files added DURING this run are
        // correctly NOT in cachedAttrs (they were inserted by Step C), so
        // they survive the diff.
        if !cachedAttrs.isEmpty {
            let cachedKeys = Set(cachedAttrs.keys)
            let orphans = cachedKeys.subtracting(seenSessionIDs)
            if !orphans.isEmpty {
                let orphanList = Array(orphans)
                do {
                    try await database.write { [providerKey] db in
                        // Chunk to keep the SQL placeholder count well under
                        // SQLite's default 999 limit even on extreme
                        // databases. Hard-delete from sessions_index +
                        // session_flags only; leave user_metadata intact so
                        // notes/tags survive accidental file removals.
                        // Scope every delete to `provider = ?` so reaping
                        // Claude orphans never touches Codex / Gemini rows.
                        let chunkSize = 500
                        var i = 0
                        while i < orphanList.count {
                            let end = min(i + chunkSize, orphanList.count)
                            let chunk = Array(orphanList[i..<end])
                            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                            var args: [DatabaseValueConvertible] = chunk
                            args.append(providerKey)
                            try db.execute(
                                sql: "DELETE FROM session_flags WHERE session_id IN (\(placeholders)) AND provider = ?",
                                arguments: StatementArguments(args)
                            )
                            try db.execute(
                                sql: "DELETE FROM sessions_index WHERE session_id IN (\(placeholders)) AND provider = ?",
                                arguments: StatementArguments(args)
                            )
                            i = end
                        }
                    }
                    AppLogger.app.info("Bootstrap reaper: removed \(orphans.count) orphan rows")
                } catch {
                    _bootstrapErrors.append(
                        "Bootstrap reaper failed: \(error.localizedDescription)"
                    )
                }
            } else {
                AppLogger.app.info("Bootstrap reaper: removed 0 orphan rows")
            }
        }

        // ── Step D: Seed built-in smart folders (idempotent) ─────────────────
        do {
            try await ensureBuiltInSmartFolders()
        } catch {
            _bootstrapErrors.append("Could not seed built-in smart folders: \(error.localizedDescription)")
        }

        progress?(1.0, "Indexed \(workspaceDataList.count) workspaces")
    }

    /// Returns errors collected during the most recent bootstrap run.
    /// These are non-fatal per-workspace / per-file failures that did not abort the overall bootstrap.
    ///
    /// Intentionally concrete-only: called via `as? SessionsRepository` from
    /// AppView's bootstrap path as a diagnostic surface. Not part of any
    /// sub-protocol; collaborators that operate over the segregated
    /// repository surfaces have no reason to read indexer warnings.
    public func recentBootstrapErrors() async -> [String] {
        _bootstrapErrors
    }

    public func allWorkspaces() async throws -> [Workspace] {
        let providerKey = currentProvider.rawValue
        return try await database.read { [providerKey] db in
            let rows = try Row.fetchAll(db,
                sql: #"""
                    SELECT id, decoded_path, "group", display_name,
                           cwd, git_branch, claude_version
                    FROM workspaces
                    WHERE provider = ?
                    ORDER BY "group", display_name
                    """#,
                arguments: [providerKey])
            return rows.map { row in
                Workspace(
                    id: row["id"],
                    decodedPath: row["decoded_path"],
                    group: row["group"],
                    displayName: row["display_name"],
                    cwd: row["cwd"],
                    gitBranch: row["git_branch"],
                    claudeVersion: row["claude_version"]
                )
            }
        }
    }

    public func sessions(inWorkspaceID id: String,
                         includeArchived: Bool = false,
                         includeDeleted: Bool = false) async throws -> [SessionMetadata] {
        let providerKey = currentProvider.rawValue
        return try await database.read { [providerKey] db in
            var sql = """
                SELECT s.session_id, s.workspace_id,
                       COALESCE(u.custom_title, s.title) AS title,
                       s.created_at, s.last_modified_at,
                       s.message_count, s.token_count,
                       s.total_input_tokens, s.total_output_tokens, s.model,
                       s.provider, s.file_path
                FROM sessions_index s
                LEFT JOIN user_metadata u ON u.session_id = s.session_id AND u.provider = s.provider
                WHERE s.provider = ?
                  AND s.workspace_id = ?
                """
            if !includeDeleted {
                sql += "\n  AND COALESCE(u.is_deleted, 0) = 0"
            }
            if !includeArchived {
                sql += "\n  AND COALESCE(u.is_archived, 0) = 0"
            }
            sql += "\nORDER BY s.last_modified_at DESC"
            let rows = try Row.fetchAll(db, sql: sql, arguments: [providerKey, id])
            return try rows.map { try Self.mapSession(from: $0) }
        }
    }

    // Protocol-conforming overload (defaults to the organisation-aware view).
    public func sessions(inWorkspaceID id: String) async throws -> [SessionMetadata] {
        try await sessions(inWorkspaceID: id, includeArchived: false, includeDeleted: false)
    }

    /// Returns the most-recently-modified sessions across all workspaces.
    /// Excludes soft-deleted and archived rows; applies custom-title coalescing.
    public func allSessions(limit: Int = 500) async throws -> [SessionMetadata] {
        let providerKey = currentProvider.rawValue
        return try await database.read { [providerKey] db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.session_id, s.workspace_id,
                       COALESCE(u.custom_title, s.title) AS title,
                       s.created_at, s.last_modified_at,
                       s.message_count, s.token_count,
                       s.total_input_tokens, s.total_output_tokens, s.model,
                       s.provider, s.file_path
                FROM sessions_index s
                LEFT JOIN user_metadata u ON u.session_id = s.session_id AND u.provider = s.provider
                WHERE s.provider = ?
                  AND COALESCE(u.is_deleted, 0) = 0
                  AND COALESCE(u.is_archived, 0) = 0
                ORDER BY s.last_modified_at DESC
                LIMIT ?
                """, arguments: [providerKey, limit])
            return try rows.map { try Self.mapSession(from: $0) }
        }
    }

    // MARK: - Menubar queries (Plan 04)

    /// The window within which a session is considered "live" for the menubar's
    /// Live section; i.e. the interval since the last jsonl write. 60 s is a
    /// reasonable proxy for "claude is actively writing to this file"; Plan 08
    /// will replace this with FS-event-driven detection.
    public static let liveWindowSeconds: TimeInterval = 60

    /// Returns up to `limit` sessions modified within the last `days` days,
    /// ordered by `last_modified_at DESC`. Sessions whose `last_modified_at`
    /// is within the live window get `isLive = true` so the caller can render
    /// them with a live indicator.
    public func recentSessions(days: Int, limit: Int = 30) async throws -> [SessionMetadata] {
        let cutoff = Date().addingTimeInterval(-Double(max(0, days)) * 24 * 3600)
        let liveCutoff = Date().addingTimeInterval(-Self.liveWindowSeconds)
        let providerKey = currentProvider.rawValue
        return try await database.read { [providerKey] db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.session_id, s.workspace_id,
                       COALESCE(u.custom_title, s.title) AS title,
                       s.created_at, s.last_modified_at,
                       s.message_count, s.token_count,
                       s.total_input_tokens, s.total_output_tokens, s.model,
                       s.provider, s.file_path
                FROM sessions_index s
                LEFT JOIN user_metadata u ON u.session_id = s.session_id AND u.provider = s.provider
                WHERE s.provider = ?
                  AND s.last_modified_at >= ?
                  AND COALESCE(u.is_deleted, 0) = 0
                  AND COALESCE(u.is_archived, 0) = 0
                ORDER BY s.last_modified_at DESC
                LIMIT ?
                """, arguments: [providerKey, cutoff, limit])
            return try rows.map { try Self.mapSession(from: $0, liveCutoff: liveCutoff) }
        }
    }

    /// Total non-deleted, non-archived session count across all workspaces.
    public func totalSessionCount() async throws -> Int {
        let providerKey = currentProvider.rawValue
        return try await database.read { [providerKey] db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM sessions_index s
                LEFT JOIN user_metadata u ON u.session_id = s.session_id AND u.provider = s.provider
                WHERE s.provider = ?
                  AND COALESCE(u.is_deleted, 0) = 0
                  AND COALESCE(u.is_archived, 0) = 0
                """, arguments: [providerKey]) ?? 0
        }
    }

    /// Number of (non-deleted, non-archived) sessions that were modified
    /// within the last `days` days for the given `provider`. Distinct
    /// from `totalSessionCount` because the menubar tile activity bar
    /// queries this once per detected provider — including providers
    /// other than the active one — to derive each tile's bar fraction.
    /// Hence the explicit provider argument.
    public func sessionCountLast(days: Int, provider: ProviderID) async throws -> Int {
        let cutoff = Date().addingTimeInterval(-Double(max(0, days)) * 24 * 3600)
        let providerKey = provider.rawValue
        return try await database.read { [providerKey] db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM sessions_index s
                LEFT JOIN user_metadata u ON u.session_id = s.session_id AND u.provider = s.provider
                WHERE s.provider = ?
                  AND s.last_modified_at >= ?
                  AND COALESCE(u.is_deleted, 0) = 0
                  AND COALESCE(u.is_archived, 0) = 0
                """, arguments: [providerKey, cutoff]) ?? 0
        }
    }

    /// Returns sessions considered "live", last modified within
    /// `liveWindowSeconds`. `isLive` is set to `true` on each row. Ordered
    /// most-recent first. Excludes deleted + archived rows.
    public func liveSessions() async throws -> [SessionMetadata] {
        let liveCutoff = Date().addingTimeInterval(-Self.liveWindowSeconds)
        let providerKey = currentProvider.rawValue
        return try await database.read { [providerKey] db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.session_id, s.workspace_id,
                       COALESCE(u.custom_title, s.title) AS title,
                       s.created_at, s.last_modified_at,
                       s.message_count, s.token_count,
                       s.total_input_tokens, s.total_output_tokens, s.model,
                       s.provider, s.file_path
                FROM sessions_index s
                LEFT JOIN user_metadata u ON u.session_id = s.session_id AND u.provider = s.provider
                WHERE s.provider = ?
                  AND s.last_modified_at >= ?
                  AND COALESCE(u.is_deleted, 0) = 0
                  AND COALESCE(u.is_archived, 0) = 0
                ORDER BY s.last_modified_at DESC
                """, arguments: [providerKey, liveCutoff])
            return try rows.map { try Self.mapSession(from: $0, liveCutoff: liveCutoff) }
        }
    }

    /// Searches sessions according to a structured `SearchQuery`.
    /// Title-level matches run via LIKE against the existing index; `/full:`
    /// matches use the lazily-populated FTS5 `transcript_fts` table.
    public func search(query: SearchQuery) async throws -> [SessionMetadata] {
        try Task.checkCancellation()

        if query.isEmpty {
            return try await allSessions(limit: query.limit)
        }

        // Tags not implemented until Plan 06; filtering on them now would hide
        // every result, which is a worse UX than ignoring them.
        // TODO(plan-06): wire tag filter once the tags table exists.

        // Resolve workspace filters to concrete workspace_id values via LIKE.
        let resolvedWorkspaceIDs = try await resolveWorkspaceIDs(matching: query.workspaces)
        if !query.workspaces.isEmpty && resolvedWorkspaceIDs.isEmpty {
            // User asked for a workspace that doesn't exist; return empty.
            return []
        }

        // If we need transcript-level search, warm the FTS index first.
        if query.needsFullText, let index = ftsIndex {
            let toIndex = resolvedWorkspaceIDs.isEmpty
                ? (try await allWorkspaces()).map(\.id)
                : resolvedWorkspaceIDs
            try await index.ensureIndexed(workspaceIDs: toIndex)
        }

        try Task.checkCancellation()

        // Build SQL + bindings. Joins user_metadata so we can coalesce the
        // custom title into the result, filter out soft-deleted rows, and
        // filter out archived rows (archived sessions only surface via the
        // dedicated archivedSessions() API).
        var sql = """
            SELECT DISTINCT s.session_id, s.workspace_id,
                   COALESCE(u.custom_title, s.title) AS title,
                   s.created_at, s.last_modified_at,
                   s.message_count, s.token_count,
                   s.total_input_tokens, s.total_output_tokens, s.model,
                   s.provider, s.file_path
            FROM sessions_index s
            LEFT JOIN user_metadata u ON u.session_id = s.session_id AND u.provider = s.provider
            """
        let providerKey = currentProvider.rawValue
        var args: [DatabaseValueConvertible] = [providerKey]
        var clauses: [String] = [
            "s.provider = ?",
            "COALESCE(u.is_deleted, 0) = 0",
            "COALESCE(u.is_archived, 0) = 0",
        ]

        if query.needsFullText {
            sql += """
                 JOIN transcript_fts f ON f.session_id = s.session_id
                """
            clauses.append("transcript_fts MATCH ?")
            args.append(Self.sanitizeFtsMatch(query.fullText))
        }

        if !resolvedWorkspaceIDs.isEmpty {
            let placeholders = Array(repeating: "?", count: resolvedWorkspaceIDs.count).joined(separator: ",")
            clauses.append("s.workspace_id IN (\(placeholders))")
            args.append(contentsOf: resolvedWorkspaceIDs.map { $0 as DatabaseValueConvertible })
        }

        if let cutoff = Self.cutoffDate(for: query.timeWindow) {
            clauses.append("s.last_modified_at >= ?")
            args.append(cutoff)
        }

        if !query.titleText.isEmpty {
            let words = query.titleText
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
                .filter { !$0.isEmpty }
            for word in words {
                // Match against both the custom title and the raw title so a rename
                // still surfaces results for the original message text.
                clauses.append("(LOWER(COALESCE(u.custom_title, s.title)) LIKE ? ESCAPE '\\' OR LOWER(s.title) LIKE ? ESCAPE '\\')")
                let pattern = "%\(Self.escapeLike(word.lowercased()))%"
                args.append(pattern)
                args.append(pattern)
            }
        }

        if !clauses.isEmpty {
            sql += "\nWHERE " + clauses.joined(separator: " AND ")
        }

        sql += "\nORDER BY s.last_modified_at DESC\nLIMIT ?"
        args.append(query.limit)

        try Task.checkCancellation()

        // Diagnostic logging; search has historically been brittle.
        // Stream with `log stream --predicate 'subsystem == "app.chronicle.Chronicle" && category == "search"'`
        // to see exactly which SQL went out and how many rows came back.
        AppLogger.search.info(
            "query title=\"\(query.titleText)\" workspaces=\(query.workspaces) "
            + "needsFullText=\(query.needsFullText) timeWindow=\(String(describing: query.timeWindow)) "
            + "resolvedWorkspaceIDs=\(resolvedWorkspaceIDs.count)"
        )

        do {
            let results: [SessionMetadata] = try await database.read { [sql, args] db in
                let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                return try rows.map { try Self.mapSession(from: $0) }
            }
            AppLogger.search.info("results=\(results.count) sql=\(sql.replacingOccurrences(of: "\n", with: " "))")
            return results
        } catch {
            AppLogger.search.error("search failed: \(error.localizedDescription) sql=\(sql.replacingOccurrences(of: "\n", with: " "))")
            throw error
        }
    }

    // MARK: - Search helpers

    private func resolveWorkspaceIDs(matching needles: [String]) async throws -> [String] {
        guard !needles.isEmpty else { return [] }
        let providerKey = currentProvider.rawValue
        return try await database.read { [providerKey] db in
            var out: [String] = []
            var seen: Set<String> = []
            for needle in needles {
                let like = "%\(Self.escapeLike(needle.lowercased()))%"
                let rows = try String.fetchAll(db, sql: """
                    SELECT id FROM workspaces
                    WHERE provider = ?
                      AND (LOWER(display_name) LIKE ? ESCAPE '\\'
                           OR LOWER(decoded_path) LIKE ? ESCAPE '\\')
                    """, arguments: [providerKey, like, like])
                for id in rows where !seen.contains(id) {
                    seen.insert(id)
                    out.append(id)
                }
            }
            return out
        }
    }

    private static func cutoffDate(for window: SearchQuery.TimeWindow?) -> Date? {
        guard let window else { return nil }
        let cal = Calendar.current
        let now = Date()
        switch window {
        case .today:
            return cal.startOfDay(for: now)
        case .thisWeek:
            return now.addingTimeInterval(-7 * 24 * 3600)
        case .last30Days:
            return now.addingTimeInterval(-30 * 24 * 3600)
        case .relative(let days):
            return now.addingTimeInterval(-Double(max(0, days)) * 24 * 3600)
        }
    }

    /// Escapes `%`, `_`, and `\` so user input inside a LIKE pattern matches literally.
    /// Callers MUST pair this with `ESCAPE '\'` in the SQL.
    internal static func escapeLike(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            if ch == "\\" || ch == "%" || ch == "_" { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// Sanitises user text for an FTS5 MATCH expression. We wrap each bare word
    /// in double quotes so special characters (`-`, `.`, `/`, `:`) don't get
    /// interpreted as FTS operators, which would throw a SQL error.
    internal static func sanitizeFtsMatch(_ s: String) -> String {
        let words = s.split(whereSeparator: \.isWhitespace).map(String.init)
        let quoted = words.map { word -> String in
            // Replace any embedded double-quote by nothing; safest for FTS5.
            let cleaned = word.replacingOccurrences(of: "\"", with: "")
            return "\"\(cleaned)\""
        }
        return quoted.joined(separator: " ")
    }

    private static func mapSession(from row: Row, liveCutoff: Date? = nil) throws -> SessionMetadata {
        let lastModified: Date = row["last_modified_at"]
        let isLive: Bool
        if let liveCutoff {
            isLive = lastModified >= liveCutoff
        } else {
            isLive = false
        }
        // total_input_tokens / total_output_tokens / model are added by v7
        // and may be missing on rows fetched via narrow SELECT lists. Fall
        // back to zero / nil so the protocol shape stays stable.
        let inTokens: Int = (row["total_input_tokens"] as Int?) ?? 0
        let outTokens: Int = (row["total_output_tokens"] as Int?) ?? 0
        let model: String? = row["model"]
        // provider / file_path are v10 columns. Older SELECTs (and tests
        // that build rows with narrower column lists) may not include
        // them; default to `.claude` / nil so behaviour matches pre-v10.
        let providerRaw: String? = row["provider"]
        let provider: ProviderID = providerRaw.flatMap(ProviderID.init(rawValue:)) ?? .claude
        let filePath: String? = row["file_path"]
        return SessionMetadata(
            sessionID: try SessionID(string: row["session_id"]),
            workspaceID: row["workspace_id"],
            title: row["title"],
            createdAt: row["created_at"],
            lastModifiedAt: lastModified,
            messageCount: row["message_count"],
            tokenCount: row["token_count"],
            inputTokens: inTokens,
            outputTokens: outTokens,
            model: model,
            isLive: isLive,
            provider: provider,
            filePath: filePath
        )
    }

    // ========================================================================
    // MARK: - Plan 06 — User metadata + tags
    // ========================================================================

    /// Epoch-second representation used for the integer columns in user_metadata.
    private static func epoch(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970.rounded())
    }

    /// Upsert-or-fetch a user_metadata row as `UserMetadata`. Returns
    /// `UserMetadata.empty(for:)` when no row exists.
    public func userMetadata(for sessionID: SessionID) async throws -> UserMetadata {
        let sid = sessionID.description
        let providerKey = currentProvider.rawValue
        return try await database.read { [providerKey] db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT is_pinned, is_archived, is_deleted, deleted_at,
                       custom_title, note, updated_at
                FROM user_metadata
                WHERE provider = ? AND session_id = ?
                """, arguments: [providerKey, sid])
            else {
                return UserMetadata.empty(for: sessionID)
            }
            let deletedAt: Int64? = row["deleted_at"]
            let updatedAt: Int64 = row["updated_at"]
            return UserMetadata(
                sessionID: sessionID,
                isPinned: (row["is_pinned"] as Int64) != 0,
                isArchived: (row["is_archived"] as Int64) != 0,
                isDeleted: (row["is_deleted"] as Int64) != 0,
                deletedAt: deletedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                customTitle: row["custom_title"],
                note: row["note"],
                updatedAt: Date(timeIntervalSince1970: TimeInterval(updatedAt))
            )
        }
    }

    /// Tags applied to a session, ordered by name ascending.
    public func tags(for sessionID: SessionID) async throws -> [Tag] {
        let sid = sessionID.description
        let providerKey = currentProvider.rawValue
        return try await database.read { [providerKey] db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT t.id, t.name, t.color_hue
                FROM tags t
                INNER JOIN session_tags st ON st.tag_id = t.id
                WHERE st.provider = ?
                  AND st.session_id = ?
                  AND t.provider = st.provider
                ORDER BY t.name COLLATE NOCASE ASC
                """, arguments: [providerKey, sid])
            return rows.map { row in
                Tag(id: row["id"], name: row["name"], colorHue: row["color_hue"])
            }
        }
    }

    public func allTags() async throws -> [Tag] {
        let providerKey = currentProvider.rawValue
        return try await database.read { [providerKey] db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, name, color_hue FROM tags
                WHERE provider = ?
                ORDER BY name COLLATE NOCASE ASC
                """, arguments: [providerKey])
            return rows.map { Tag(id: $0["id"], name: $0["name"], colorHue: $0["color_hue"]) }
        }
    }

    /// Number of (non-deleted, non-archived) sessions per tag id.
    public func tagCounts() async throws -> [Int64: Int] {
        let providerKey = currentProvider.rawValue
        return try await database.read { [providerKey] db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT st.tag_id AS tag_id, COUNT(*) AS n
                FROM session_tags st
                LEFT JOIN user_metadata u ON u.session_id = st.session_id AND u.provider = st.provider
                WHERE st.provider = ?
                  AND COALESCE(u.is_deleted, 0) = 0
                  AND COALESCE(u.is_archived, 0) = 0
                GROUP BY st.tag_id
                """, arguments: [providerKey])
            var out: [Int64: Int] = [:]
            for row in rows {
                out[row["tag_id"]] = row["n"]
            }
            return out
        }
    }

    // MARK: Organised queries

    /// Up to `limit` pinned sessions, newest `updated_at` first. Excludes
    /// deleted + archived rows. Includes applied tags.
    public func pinnedSessions(limit: Int = 50) async throws -> [SessionWithMetadata] {
        let providerKey = currentProvider.rawValue
        return try await loadSessionsWithMetadata(sql: """
            SELECT s.session_id, s.workspace_id,
                   COALESCE(u.custom_title, s.title) AS title,
                   s.created_at, s.last_modified_at,
                   s.message_count, s.token_count,
                   s.total_input_tokens, s.total_output_tokens, s.model,
                   s.provider, s.file_path,
                   u.is_pinned, u.is_archived, u.is_deleted, u.deleted_at,
                   u.custom_title, u.note, u.updated_at
            FROM sessions_index s
            INNER JOIN user_metadata u ON u.session_id = s.session_id AND u.provider = s.provider
            WHERE s.provider = ?
              AND u.is_pinned = 1
              AND u.is_deleted = 0
              AND u.is_archived = 0
            ORDER BY u.updated_at DESC
            LIMIT ?
            """, arguments: [providerKey, limit])
    }

    /// Up to `limit` archived sessions, newest `updated_at` first. Excludes deleted rows.
    public func archivedSessions(limit: Int = 200) async throws -> [SessionWithMetadata] {
        let providerKey = currentProvider.rawValue
        return try await loadSessionsWithMetadata(sql: """
            SELECT s.session_id, s.workspace_id,
                   COALESCE(u.custom_title, s.title) AS title,
                   s.created_at, s.last_modified_at,
                   s.message_count, s.token_count,
                   s.total_input_tokens, s.total_output_tokens, s.model,
                   s.provider, s.file_path,
                   u.is_pinned, u.is_archived, u.is_deleted, u.deleted_at,
                   u.custom_title, u.note, u.updated_at
            FROM sessions_index s
            INNER JOIN user_metadata u ON u.session_id = s.session_id AND u.provider = s.provider
            WHERE s.provider = ?
              AND u.is_archived = 1
              AND u.is_deleted = 0
            ORDER BY u.updated_at DESC
            LIMIT ?
            """, arguments: [providerKey, limit])
    }

    /// Number of archived (non-deleted) sessions; used by the sidebar.
    public func archivedCount() async throws -> Int {
        let providerKey = currentProvider.rawValue
        return try await database.read { [providerKey] db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM user_metadata
                WHERE provider = ? AND is_archived = 1 AND is_deleted = 0
                """, arguments: [providerKey]) ?? 0
        }
    }

    /// Sessions with the given tag applied (excludes deleted + archived).
    public func sessionsForTag(_ tag: Tag, limit: Int = 200) async throws -> [SessionWithMetadata] {
        let providerKey = currentProvider.rawValue
        return try await loadSessionsWithMetadata(sql: """
            SELECT s.session_id, s.workspace_id,
                   COALESCE(u.custom_title, s.title) AS title,
                   s.created_at, s.last_modified_at,
                   s.message_count, s.token_count,
                   s.total_input_tokens, s.total_output_tokens, s.model,
                   s.provider, s.file_path,
                   u.is_pinned, u.is_archived, u.is_deleted, u.deleted_at,
                   u.custom_title, u.note, u.updated_at
            FROM sessions_index s
            INNER JOIN session_tags st ON st.session_id = s.session_id AND st.provider = s.provider
            LEFT JOIN user_metadata u ON u.session_id = s.session_id AND u.provider = s.provider
            WHERE s.provider = ?
              AND st.tag_id = ?
              AND COALESCE(u.is_deleted, 0) = 0
              AND COALESCE(u.is_archived, 0) = 0
            ORDER BY s.last_modified_at DESC
            LIMIT ?
            """, arguments: [providerKey, tag.id, limit])
    }

    /// Shared loader that maps to SessionWithMetadata, hydrating tags in a
    /// single follow-up query to avoid N+1 reads.
    private func loadSessionsWithMetadata(sql: String,
                                          arguments: StatementArguments) async throws -> [SessionWithMetadata] {
        let core = try await database.read { db -> [(SessionMetadata, UserMetadata)] in
            let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
            return try rows.map { row in
                let session = try Self.mapSession(from: row)
                let meta = try Self.mapUserMetadata(from: row, fallback: session.sessionID)
                return (session, meta)
            }
        }
        guard !core.isEmpty else { return [] }

        // Fetch applied tags for the whole batch in one go. Scope to
        // active provider so a Codex session_id colliding with a Claude
        // tag (astronomically unlikely with UUIDs, but the constraint
        // is cheap) doesn't surface the wrong provider's tags.
        let sessionIDs = core.map { $0.0.sessionID.description }
        let providerKey = currentProvider.rawValue
        let tagsBySession: [String: [Tag]] = try await database.read { [providerKey] db in
            let placeholders = Array(repeating: "?", count: sessionIDs.count).joined(separator: ",")
            var args: [DatabaseValueConvertible] = sessionIDs
            args.append(providerKey)
            let rows = try Row.fetchAll(db, sql: """
                SELECT st.session_id AS session_id, t.id AS id, t.name AS name, t.color_hue AS color_hue
                FROM session_tags st
                INNER JOIN tags t ON t.id = st.tag_id AND t.provider = st.provider
                WHERE st.session_id IN (\(placeholders))
                  AND st.provider = ?
                ORDER BY t.name COLLATE NOCASE ASC
                """, arguments: StatementArguments(args))
            var acc: [String: [Tag]] = [:]
            for row in rows {
                let sid: String = row["session_id"]
                let tag = Tag(id: row["id"], name: row["name"], colorHue: row["color_hue"])
                acc[sid, default: []].append(tag)
            }
            return acc
        }

        return core.map { (session, meta) in
            SessionWithMetadata(
                session: session,
                userMetadata: meta,
                tags: tagsBySession[session.sessionID.description] ?? []
            )
        }
    }

    private static func mapUserMetadata(from row: Row, fallback id: SessionID) throws -> UserMetadata {
        // Some call sites may end up here with columns present but null
        // (LEFT JOIN). Fall back to empty metadata in that case.
        guard let updatedAt = row["updated_at"] as Int64? else {
            return UserMetadata.empty(for: id)
        }
        let isPinned = (row["is_pinned"] as Int64?) ?? 0
        let isArchived = (row["is_archived"] as Int64?) ?? 0
        let isDeleted = (row["is_deleted"] as Int64?) ?? 0
        let deletedAt: Int64? = row["deleted_at"]
        return UserMetadata(
            sessionID: id,
            isPinned: isPinned != 0,
            isArchived: isArchived != 0,
            isDeleted: isDeleted != 0,
            deletedAt: deletedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            customTitle: row["custom_title"],
            note: row["note"],
            updatedAt: Date(timeIntervalSince1970: TimeInterval(updatedAt))
        )
    }

    // MARK: Writes — user_metadata

    public func setPinned(_ pinned: Bool, for sessionID: SessionID) async throws {
        try await upsert(sessionID: sessionID) { current in
            var m = current
            m.isPinned = pinned
            return m
        }
    }

    public func setArchived(_ archived: Bool, for sessionID: SessionID) async throws {
        try await upsert(sessionID: sessionID) { current in
            var m = current
            m.isArchived = archived
            return m
        }
    }

    public func setCustomTitle(_ title: String?, for sessionID: SessionID) async throws {
        try await upsert(sessionID: sessionID) { current in
            var m = current
            // Treat empty/whitespace-only as nil so the raw title is used.
            let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            m.customTitle = trimmed.isEmpty ? nil : trimmed
            return m
        }
    }

    public func setNote(_ note: String?, for sessionID: SessionID) async throws {
        try await upsert(sessionID: sessionID) { current in
            var m = current
            let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            m.note = trimmed.isEmpty ? nil : trimmed
            return m
        }
    }

    /// Marks a session as soft-deleted and moves its on-disk `.jsonl` to the
    /// user's macOS Trash. If the file is already missing, the DB flag is
    /// still set. `workspaceID` is an optional hint; if nil the repo looks
    /// it up from `sessions_index`.
    public func softDelete(_ sessionID: SessionID, workspaceID: String? = nil) async throws {
        let providerKey = currentProvider.rawValue
        let resolvedWsID: String? = try await {
            if let workspaceID { return workspaceID }
            return try await database.read { [providerKey] db in
                try String.fetchOne(db,
                    sql: "SELECT workspace_id FROM sessions_index WHERE provider = ? AND session_id = ?",
                    arguments: [providerKey, sessionID.description])
            }
        }()

        // Step 1: move file to Trash (best-effort).
        if let wsID = resolvedWsID, let root = projectsRoot {
            let url = root
                .appendingPathComponent(wsID, isDirectory: true)
                .appendingPathComponent("\(sessionID.description).jsonl", isDirectory: false)
            do {
                var resulting: NSURL?
                try fm.trashItem(at: url, resultingItemURL: &resulting)
            } catch CocoaError.fileNoSuchFile {
                // already gone; fine, carry on
            } catch let err as NSError where err.domain == NSCocoaErrorDomain
                                        && err.code == NSFileNoSuchFileError {
                // same, normalised
            } catch {
                // Any other filesystem error is non-fatal; we still want the
                // DB flag flipped so the session disappears from the UI.
            }
        }

        // Step 2: flip the flag.
        let now = Date()
        try await upsert(sessionID: sessionID) { current in
            var m = current
            m.isDeleted = true
            m.deletedAt = now
            return m
        }
    }

    public func undelete(_ sessionID: SessionID) async throws {
        try await upsert(sessionID: sessionID) { current in
            var m = current
            m.isDeleted = false
            m.deletedAt = nil
            return m
        }
    }

    /// Permanently remove user_metadata rows (and join rows) for sessions
    /// soft-deleted more than `days` days ago. Also drops the underlying
    /// `sessions_index` row so the session disappears from indexes.
    /// The `.jsonl` file itself already lives in ~/.Trash and is outside our
    /// scope; macOS handles the 30-day Trash retention separately.
    public func hardPurgeExpiredDeletes(olderThan days: Int = 30) async throws {
        let cutoff = Self.epoch(Date().addingTimeInterval(-Double(max(0, days)) * 24 * 3600))
        // Hard-purge runs across all providers so a stale Codex
        // soft-delete doesn't outlive its 30-day window just because
        // the user's currently scoped to Claude. The deletes still
        // touch only soft-deleted rows, so any provider's flagged
        // session is fair game; we just don't filter by currentProvider.
        try await database.write { db in
            let expiredRows = try Row.fetchAll(db, sql: """
                SELECT provider, session_id FROM user_metadata
                WHERE is_deleted = 1 AND deleted_at IS NOT NULL AND deleted_at < ?
                """, arguments: [cutoff])
            guard !expiredRows.isEmpty else { return }
            for row in expiredRows {
                let provider: String = row["provider"]
                let sid: String = row["session_id"]
                try db.execute(sql: """
                    DELETE FROM session_tags WHERE provider = ? AND session_id = ?
                    """, arguments: [provider, sid])
                try db.execute(sql: """
                    DELETE FROM user_metadata WHERE provider = ? AND session_id = ?
                    """, arguments: [provider, sid])
                try db.execute(sql: """
                    DELETE FROM sessions_index WHERE provider = ? AND session_id = ?
                    """, arguments: [provider, sid])
            }
        }
    }

    // MARK: Tag CRUD

    public enum TagError: LocalizedError {
        case emptyName
        case alreadyExists(String)

        public var errorDescription: String? {
            switch self {
            case .emptyName: return "Tag name cannot be empty."
            case .alreadyExists(let n): return "A tag called \"\(n)\" already exists."
            }
        }
    }

    public func createTag(name: String, colorHue: Int = 30) async throws -> Tag {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TagError.emptyName }
        let hue = Tag.clampHue(colorHue)
        let providerKey = currentProvider.rawValue
        return try await database.write { [providerKey] db in
            do {
                try db.execute(sql: """
                    INSERT INTO tags (name, color_hue, provider) VALUES (?, ?, ?)
                    """, arguments: [trimmed, hue, providerKey])
            } catch let err as DatabaseError where err.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
                throw TagError.alreadyExists(trimmed)
            }
            let row = try Row.fetchOne(db, sql: """
                SELECT id, name, color_hue FROM tags
                WHERE name = ? COLLATE NOCASE AND provider = ?
                """, arguments: [trimmed, providerKey])!
            return Tag(id: row["id"], name: row["name"], colorHue: row["color_hue"])
        }
    }

    public func renameTag(_ id: Int64, to name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TagError.emptyName }
        let providerKey = currentProvider.rawValue
        try await database.write { [providerKey] db in
            do {
                try db.execute(sql: "UPDATE tags SET name = ? WHERE id = ? AND provider = ?",
                               arguments: [trimmed, id, providerKey])
            } catch let err as DatabaseError where err.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
                throw TagError.alreadyExists(trimmed)
            }
        }
    }

    public func deleteTag(_ id: Int64) async throws {
        let providerKey = currentProvider.rawValue
        try await database.write { [providerKey] db in
            // Foreign-key ON DELETE CASCADE handles session_tags cleanup.
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "DELETE FROM tags WHERE id = ? AND provider = ?",
                           arguments: [id, providerKey])
        }
    }

    /// Replace the set of tags applied to a session.
    public func setTags(_ tagIDs: [Int64], for sessionID: SessionID) async throws {
        let sid = sessionID.description
        let providerKey = currentProvider.rawValue
        try await database.write { [providerKey] db in
            try db.execute(sql: "DELETE FROM session_tags WHERE session_id = ? AND provider = ?",
                           arguments: [sid, providerKey])
            for tagID in tagIDs {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO session_tags (session_id, tag_id, provider) VALUES (?, ?, ?)
                    """, arguments: [sid, tagID, providerKey])
            }
        }
    }

    // MARK: - Internals

    /// Read-modify-write a user_metadata row in a single transaction.
    /// The closure receives the current state (or `.empty` if absent) and
    /// returns the new desired state. `updatedAt` is always rewritten.
    private func upsert(sessionID: SessionID,
                        mutate: @Sendable @escaping (UserMetadata) -> UserMetadata) async throws {
        let sid = sessionID.description
        let providerKey = currentProvider.rawValue
        try await database.write { [providerKey] db in
            let current: UserMetadata
            if let row = try Row.fetchOne(db, sql: """
                SELECT is_pinned, is_archived, is_deleted, deleted_at,
                       custom_title, note, updated_at
                FROM user_metadata
                WHERE provider = ? AND session_id = ?
                """, arguments: [providerKey, sid]) {
                let updatedAt: Int64 = row["updated_at"]
                let deletedAt: Int64? = row["deleted_at"]
                current = UserMetadata(
                    sessionID: sessionID,
                    isPinned: (row["is_pinned"] as Int64) != 0,
                    isArchived: (row["is_archived"] as Int64) != 0,
                    isDeleted: (row["is_deleted"] as Int64) != 0,
                    deletedAt: deletedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                    customTitle: row["custom_title"],
                    note: row["note"],
                    updatedAt: Date(timeIntervalSince1970: TimeInterval(updatedAt))
                )
            } else {
                current = UserMetadata.empty(for: sessionID)
            }

            var next = mutate(current)
            next.updatedAt = Date()
            let deletedAtVal: Int64? = next.deletedAt.map { Self.epoch($0) }

            // Composite (provider, session_id) unique index from v9
            // means ON CONFLICT(session_id) alone could fire on a
            // cross-provider collision. Use the composite target so
            // the upsert is provider-scoped.
            try db.execute(sql: """
                INSERT INTO user_metadata
                    (session_id, is_pinned, is_archived, is_deleted, deleted_at,
                     custom_title, note, updated_at, provider)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(provider, session_id) DO UPDATE SET
                    is_pinned = excluded.is_pinned,
                    is_archived = excluded.is_archived,
                    is_deleted = excluded.is_deleted,
                    deleted_at = excluded.deleted_at,
                    custom_title = excluded.custom_title,
                    note = excluded.note,
                    updated_at = excluded.updated_at
                """, arguments: [
                    sid,
                    next.isPinned ? 1 : 0,
                    next.isArchived ? 1 : 0,
                    next.isDeleted ? 1 : 0,
                    deletedAtVal,
                    next.customTitle,
                    next.note,
                    Self.epoch(next.updatedAt),
                    providerKey,
                ])
        }
    }

    // ========================================================================
    // MARK: - Plan 07 — Smart folders
    // ========================================================================

    public enum SmartFolderError: LocalizedError {
        case emptyName
        case notFound(Int64)

        public var errorDescription: String? {
            switch self {
            case .emptyName:           return "Smart folder name cannot be empty."
            case .notFound(let id):    return "Smart folder #\(id) not found."
            }
        }
    }

    /// All smart folders, ordered by `sort_order` ascending.
    public func smartFolders() async throws -> [SmartFolder] {
        let providerKey = currentProvider.rawValue
        return try await database.read { [providerKey] db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, name, query_json, sort_order, is_builtin
                FROM smart_folders
                WHERE provider = ?
                ORDER BY sort_order ASC, id ASC
                """, arguments: [providerKey])
            return rows.compactMap { Self.mapSmartFolder(from: $0) }
        }
    }

    /// Seeds the four built-in smart folders if they don't already exist
    /// (matched by name) for the active provider. Safe to call on every
    /// bootstrap; idempotent and provider-scoped, so each provider's
    /// first bootstrap gets its own copy of the built-ins.
    internal func ensureBuiltInSmartFolders() async throws {
        let providerKey = currentProvider.rawValue
        try await database.write { [providerKey] db in
            for builtin in SmartFolder.builtIns {
                let existing = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM smart_folders
                    WHERE name = ? COLLATE NOCASE AND provider = ?
                    """, arguments: [builtin.name, providerKey]) ?? 0
                if existing == 0 {
                    let json = try Self.encodeQuery(builtin.query)
                    try db.execute(sql: """
                        INSERT INTO smart_folders (name, query_json, sort_order, is_builtin, provider)
                        VALUES (?, ?, ?, 1, ?)
                        """, arguments: [builtin.name, json, builtin.sortOrder, providerKey])
                }
            }
        }
    }

    public func createSmartFolder(name: String, query: SmartFolderQuery) async throws -> SmartFolder {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SmartFolderError.emptyName }
        let json = try Self.encodeQuery(query)
        let providerKey = currentProvider.rawValue
        return try await database.write { [providerKey] db in
            let maxOrder = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(sort_order), 0) FROM smart_folders WHERE provider = ?",
                arguments: [providerKey]
            ) ?? 0
            try db.execute(sql: """
                INSERT INTO smart_folders (name, query_json, sort_order, is_builtin, provider)
                VALUES (?, ?, ?, 0, ?)
                """, arguments: [trimmed, json, maxOrder + 1, providerKey])
            let newID = db.lastInsertedRowID
            return SmartFolder(id: newID,
                               name: trimmed,
                               query: query,
                               sortOrder: maxOrder + 1,
                               isBuiltIn: false)
        }
    }

    public func deleteSmartFolder(_ id: Int64) async throws {
        let providerKey = currentProvider.rawValue
        try await database.write { [providerKey] db in
            try db.execute(sql: "DELETE FROM smart_folders WHERE id = ? AND provider = ?",
                           arguments: [id, providerKey])
        }
    }

    public func renameSmartFolder(_ id: Int64, to name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SmartFolderError.emptyName }
        let providerKey = currentProvider.rawValue
        try await database.write { [providerKey] db in
            try db.execute(sql: "UPDATE smart_folders SET name = ? WHERE id = ? AND provider = ?",
                           arguments: [trimmed, id, providerKey])
        }
    }

    /// Returns the sessions that match the given smart folder's query.
    /// Excludes deleted + archived rows by default (smart folders are for
    /// "active work"; archived lives in its own sidebar section).
    public func sessionsForSmartFolder(_ folder: SmartFolder,
                                        limit: Int = 500) async throws -> [SessionWithMetadata] {
        switch folder.query {
        case .today:
            let cutoff = Calendar.current.startOfDay(for: Date())
            return try await sessionsByDateRange(since: cutoff, limit: limit)
        case .thisWeek:
            let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
            return try await sessionsByDateRange(since: cutoff, limit: limit)
        case .lastNDays(let n):
            let cutoff = Date().addingTimeInterval(-Double(max(0, n)) * 24 * 3600)
            return try await sessionsByDateRange(since: cutoff, limit: limit)
        case .usedGitPush:
            return try await sessionsWithFlag(JsonlParser.Flag.gitPush, limit: limit)
        case .erroredSessions:
            return try await sessionsWithFlag(JsonlParser.Flag.errored, limit: limit)
        case .search(let sq):
            let bare = try await search(query: sq)
            return try await hydrate(bare)
        case .custom(let raw):
            let parsed = SearchQueryParser.parse(raw)
            let bare = try await search(query: parsed)
            return try await hydrate(bare)
        case .compound(let cq):
            return try await sessionsForCompound(cq, limit: limit)
        }
    }

    /// Compound smart folder: AND together every populated filter on
    /// `SmartFolderCompoundQuery`. Joins are kept lean; tag/flag joins
    /// only attach when those filters are present, FTS only when search
    /// text is present, and the (workspace, tokens, since-days) clauses
    /// hit `sessions_index` directly so the common shape is one indexed
    /// scan plus a couple of cheap subqueries.
    private func sessionsForCompound(_ cq: SmartFolderCompoundQuery,
                                     limit: Int) async throws -> [SessionWithMetadata] {
        let activeProvider = currentProvider
        let (sql, args) = try await Self.buildCompoundSQL(
            cq,
            select: """
                SELECT s.session_id, s.workspace_id,
                       COALESCE(u.custom_title, s.title) AS title,
                       s.created_at, s.last_modified_at,
                       s.message_count, s.token_count,
                       s.total_input_tokens, s.total_output_tokens, s.model,
                       s.provider, s.file_path,
                       u.is_pinned, u.is_archived, u.is_deleted, u.deleted_at,
                       u.custom_title, u.note, u.updated_at
                """,
            order: "ORDER BY s.last_modified_at DESC",
            limit: limit,
            ftsIndexer: ftsIndex,
            allWorkspaceIDs: { try await self.allWorkspaces().map(\.id) },
            provider: activeProvider
        )
        return try await loadSessionsWithMetadata(sql: sql, arguments: StatementArguments(args))
    }

    /// Per-smart-folder matching-session counts. Uses lighter queries than
    /// `sessionsForSmartFolder(...)`, just SELECT COUNT(*) for each.
    public func smartFolderCounts() async throws -> [Int64: Int] {
        let folders = try await smartFolders()
        var out: [Int64: Int] = [:]
        for f in folders {
            out[f.id] = (try? await countSessionsForSmartFolder(f)) ?? 0
        }
        return out
    }

    private func countSessionsForSmartFolder(_ folder: SmartFolder) async throws -> Int {
        switch folder.query {
        case .today:
            let cutoff = Calendar.current.startOfDay(for: Date())
            return try await countSessionsSince(cutoff)
        case .thisWeek:
            return try await countSessionsSince(Date().addingTimeInterval(-7 * 24 * 3600))
        case .lastNDays(let n):
            return try await countSessionsSince(Date().addingTimeInterval(-Double(max(0, n)) * 24 * 3600))
        case .usedGitPush:
            return try await countSessionsWithFlag(JsonlParser.Flag.gitPush)
        case .erroredSessions:
            return try await countSessionsWithFlag(JsonlParser.Flag.errored)
        case .search, .custom:
            // Slow path; do the full query but cap at 500 so we don't pay
            // unbounded cost on the sidebar count.
            let rows = try await sessionsForSmartFolder(folder, limit: 500)
            return rows.count
        case .compound(let cq):
            return try await countSessionsForCompound(cq)
        }
    }

    /// Count-only path for compound smart folders. Mirrors
    /// `sessionsForCompound` but issues a `SELECT COUNT(DISTINCT s.session_id)`
    /// so sidebar counts don't materialize full rows. Capped via the
    /// shared SQL builder's `limit:` argument set to a sentinel.
    private func countSessionsForCompound(_ cq: SmartFolderCompoundQuery) async throws -> Int {
        let activeProvider = currentProvider
        let (sql, args) = try await Self.buildCompoundSQL(
            cq,
            select: "SELECT COUNT(DISTINCT s.session_id) AS n",
            order: nil,
            limit: nil,
            ftsIndexer: ftsIndex,
            allWorkspaceIDs: { try await self.allWorkspaces().map(\.id) },
            provider: activeProvider
        )
        return try await database.read { db in
            try Int.fetchOne(db, sql: sql, arguments: StatementArguments(args)) ?? 0
        }
    }

    private func countSessionsSince(_ cutoff: Date) async throws -> Int {
        let providerKey = currentProvider.rawValue
        return try await database.read { [providerKey] db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM sessions_index s
                LEFT JOIN user_metadata u ON u.session_id = s.session_id AND u.provider = s.provider
                WHERE s.provider = ?
                  AND s.last_modified_at >= ?
                  AND COALESCE(u.is_deleted, 0) = 0
                  AND COALESCE(u.is_archived, 0) = 0
                """, arguments: [providerKey, cutoff]) ?? 0
        }
    }

    private func countSessionsWithFlag(_ flag: String) async throws -> Int {
        let providerKey = currentProvider.rawValue
        return try await database.read { [providerKey] db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*)
                FROM session_flags f
                INNER JOIN sessions_index s ON s.session_id = f.session_id AND s.provider = f.provider
                LEFT JOIN user_metadata u ON u.session_id = s.session_id AND u.provider = s.provider
                WHERE f.provider = ?
                  AND f.flag_name = ?
                  AND COALESCE(u.is_deleted, 0) = 0
                  AND COALESCE(u.is_archived, 0) = 0
                """, arguments: [providerKey, flag]) ?? 0
        }
    }

    private func sessionsByDateRange(since cutoff: Date,
                                     limit: Int) async throws -> [SessionWithMetadata] {
        let providerKey = currentProvider.rawValue
        return try await loadSessionsWithMetadata(sql: """
            SELECT s.session_id, s.workspace_id,
                   COALESCE(u.custom_title, s.title) AS title,
                   s.created_at, s.last_modified_at,
                   s.message_count, s.token_count,
                   s.total_input_tokens, s.total_output_tokens, s.model,
                   s.provider, s.file_path,
                   u.is_pinned, u.is_archived, u.is_deleted, u.deleted_at,
                   u.custom_title, u.note, u.updated_at
            FROM sessions_index s
            LEFT JOIN user_metadata u ON u.session_id = s.session_id AND u.provider = s.provider
            WHERE s.provider = ?
              AND s.last_modified_at >= ?
              AND COALESCE(u.is_deleted, 0) = 0
              AND COALESCE(u.is_archived, 0) = 0
            ORDER BY s.last_modified_at DESC
            LIMIT ?
            """, arguments: [providerKey, cutoff, limit])
    }

    private func sessionsWithFlag(_ flag: String,
                                  limit: Int) async throws -> [SessionWithMetadata] {
        let providerKey = currentProvider.rawValue
        return try await loadSessionsWithMetadata(sql: """
            SELECT s.session_id, s.workspace_id,
                   COALESCE(u.custom_title, s.title) AS title,
                   s.created_at, s.last_modified_at,
                   s.message_count, s.token_count,
                   s.total_input_tokens, s.total_output_tokens, s.model,
                   s.provider, s.file_path,
                   u.is_pinned, u.is_archived, u.is_deleted, u.deleted_at,
                   u.custom_title, u.note, u.updated_at
            FROM sessions_index s
            INNER JOIN session_flags f ON f.session_id = s.session_id AND f.provider = s.provider
            LEFT JOIN user_metadata u ON u.session_id = s.session_id AND u.provider = s.provider
            WHERE s.provider = ?
              AND f.flag_name = ?
              AND COALESCE(u.is_deleted, 0) = 0
              AND COALESCE(u.is_archived, 0) = 0
            ORDER BY s.last_modified_at DESC
            LIMIT ?
            """, arguments: [providerKey, flag, limit])
    }

    /// Hydrate bare [SessionMetadata] into [SessionWithMetadata] by looking up
    /// each row's user_metadata + tags in batch. Used for .search/.custom
    /// smart folders where the underlying repo.search(query:) returns bare
    /// SessionMetadata.
    private func hydrate(_ bare: [SessionMetadata]) async throws -> [SessionWithMetadata] {
        guard !bare.isEmpty else { return [] }
        let ids = bare.map { $0.sessionID.description }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let providerKey = currentProvider.rawValue

        let (metaByID, tagsByID): ([String: UserMetadata], [String: [Tag]]) = try await database.read { [providerKey] db in
            var metaMap: [String: UserMetadata] = [:]
            var metaArgs: [DatabaseValueConvertible] = ids
            metaArgs.append(providerKey)
            let metaRows = try Row.fetchAll(db, sql: """
                SELECT session_id, is_pinned, is_archived, is_deleted, deleted_at,
                       custom_title, note, updated_at
                FROM user_metadata
                WHERE session_id IN (\(placeholders))
                  AND provider = ?
                """, arguments: StatementArguments(metaArgs))
            for row in metaRows {
                let sid: String = row["session_id"]
                guard let parsed = try? SessionID(string: sid) else { continue }
                metaMap[sid] = UserMetadata(
                    sessionID: parsed,
                    isPinned: (row["is_pinned"] as Int64) != 0,
                    isArchived: (row["is_archived"] as Int64) != 0,
                    isDeleted: (row["is_deleted"] as Int64) != 0,
                    deletedAt: (row["deleted_at"] as Int64?).map {
                        Date(timeIntervalSince1970: TimeInterval($0))
                    },
                    customTitle: row["custom_title"],
                    note: row["note"],
                    updatedAt: Date(timeIntervalSince1970: TimeInterval(row["updated_at"] as Int64))
                )
            }

            var tagsMap: [String: [Tag]] = [:]
            var tagArgs: [DatabaseValueConvertible] = ids
            tagArgs.append(providerKey)
            let tagRows = try Row.fetchAll(db, sql: """
                SELECT st.session_id AS session_id, t.id AS id, t.name AS name, t.color_hue AS color_hue
                FROM session_tags st
                INNER JOIN tags t ON t.id = st.tag_id AND t.provider = st.provider
                WHERE st.session_id IN (\(placeholders))
                  AND st.provider = ?
                ORDER BY t.name COLLATE NOCASE ASC
                """, arguments: StatementArguments(tagArgs))
            for row in tagRows {
                let sid: String = row["session_id"]
                tagsMap[sid, default: []].append(Tag(id: row["id"], name: row["name"], colorHue: row["color_hue"]))
            }
            return (metaMap, tagsMap)
        }

        return bare.map { s in
            let key = s.sessionID.description
            let meta = metaByID[key] ?? UserMetadata.empty(for: s.sessionID)
            return SessionWithMetadata(session: s, userMetadata: meta, tags: tagsByID[key] ?? [])
        }
    }

    // MARK: Compound smart folder SQL builder

    /// Builds the SQL + bindings for a `SmartFolderCompoundQuery`.
    ///
    /// Shared between the row-fetch (`sessionsForCompound`) and count-only
    /// (`countSessionsForCompound`) call sites; they only differ in
    /// `select`, `order`, and whether they append a `LIMIT ?`. Always
    /// excludes deleted + archived rows to match the rest of the smart
    /// folder pipeline.
    ///
    /// - parameters:
    ///   - cq: the compound query to translate.
    ///   - select: the leading SELECT clause (caller chooses the column
    ///     list; full row vs `COUNT(DISTINCT s.session_id)`).
    ///   - order: optional `ORDER BY ...` suffix; pass nil for COUNT(*).
    ///   - limit: optional row cap appended as `LIMIT ?` and bound.
    ///   - ftsIndexer: when non-nil and `cq.searchText` has tokens, the
    ///     FTS index for the involved workspaces is warmed before the
    ///     query so the FTS join returns rows.
    ///   - allWorkspaceIDs: lazy resolver for "every workspace ID" used
    ///     when an FTS warm-up needs to span every workspace (no
    ///     `workspaceID` filter).
    private static func buildCompoundSQL(
        _ cq: SmartFolderCompoundQuery,
        select: String,
        order: String?,
        limit: Int?,
        ftsIndexer: FtsIndex?,
        allWorkspaceIDs: () async throws -> [String],
        provider: ProviderID
    ) async throws -> (String, [DatabaseValueConvertible]) {
        var joins: [String] = [
            "LEFT JOIN user_metadata u ON u.session_id = s.session_id AND u.provider = s.provider"
        ]
        var clauses: [String] = [
            "s.provider = ?",
            "COALESCE(u.is_deleted, 0) = 0",
            "COALESCE(u.is_archived, 0) = 0",
        ]
        var args: [DatabaseValueConvertible] = [provider.rawValue]

        // Workspace filter; direct equality on the indexed column.
        if let ws = cq.workspaceID, !ws.isEmpty {
            clauses.append("s.workspace_id = ?")
            args.append(ws)
        }

        // Token range ,  `sessions_index.token_count` is the aggregate the
        // sidebar already shows. Inclusive bounds on both sides.
        if let lo = cq.minTokens {
            clauses.append("s.token_count >= ?")
            args.append(lo)
        }
        if let hi = cq.maxTokens {
            clauses.append("s.token_count <= ?")
            args.append(hi)
        }

        // "Modified within the last N days" → cutoff Date.
        if let n = cq.sinceDays, n > 0 {
            let cutoff = Date().addingTimeInterval(-Double(n) * 24 * 3600)
            clauses.append("s.last_modified_at >= ?")
            args.append(cutoff)
        }

        // Tag filter; sessions must carry EVERY tag in the list. Use a
        // GROUP-BY-COUNT subquery so the row matches only when all
        // requested tag IDs are present (intersection, not union).
        let trimmedTagIDs = Self.dedup(cq.tagIDs)
        if !trimmedTagIDs.isEmpty {
            let placeholders = Array(repeating: "?", count: trimmedTagIDs.count).joined(separator: ",")
            clauses.append("""
                s.session_id IN (
                    SELECT session_id FROM session_tags
                    WHERE provider = ?
                      AND tag_id IN (\(placeholders))
                    GROUP BY session_id
                    HAVING COUNT(DISTINCT tag_id) = ?
                )
                """)
            args.append(provider.rawValue)
            for tid in trimmedTagIDs { args.append(tid) }
            args.append(trimmedTagIDs.count)
        }

        // Flag filter; same intersection pattern as tags so the user
        // can require BOTH `git_push` AND `errored`.
        let trimmedFlags = Self.dedup(cq.flags)
        if !trimmedFlags.isEmpty {
            let placeholders = Array(repeating: "?", count: trimmedFlags.count).joined(separator: ",")
            clauses.append("""
                s.session_id IN (
                    SELECT session_id FROM session_flags
                    WHERE provider = ?
                      AND flag_name IN (\(placeholders))
                    GROUP BY session_id
                    HAVING COUNT(DISTINCT flag_name) = ?
                )
                """)
            args.append(provider.rawValue)
            for f in trimmedFlags { args.append(f) }
            args.append(trimmedFlags.count)
        }

        // Free-text search; when present, JOIN against FTS5 and warm
        // the index for the relevant workspaces first. We re-use the
        // same sanitizer as the main search bar so dashes/dots in
        // queries don't blow up MATCH.
        let trimmedSearch = (cq.searchText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSearch.isEmpty {
            if let indexer = ftsIndexer {
                let toIndex: [String]
                if let ws = cq.workspaceID, !ws.isEmpty {
                    toIndex = [ws]
                } else {
                    toIndex = (try? await allWorkspaceIDs()) ?? []
                }
                try? await indexer.ensureIndexed(workspaceIDs: toIndex)
            }
            joins.append("JOIN transcript_fts f ON f.session_id = s.session_id")
            clauses.append("transcript_fts MATCH ?")
            args.append(Self.sanitizeFtsMatch(trimmedSearch))
        }

        var sql = "\(select)\n            FROM sessions_index s\n            \(joins.joined(separator: "\n            "))"
        if !clauses.isEmpty {
            sql += "\n            WHERE " + clauses.joined(separator: "\n              AND ")
        }
        if let order { sql += "\n            \(order)" }
        if let limit {
            sql += "\n            LIMIT ?"
            args.append(limit)
        }
        return (sql, args)
    }

    /// Order-preserving deduplicate. Used by the compound SQL builder to
    /// drop accidental duplicates from `tagIDs` / `flags` before building
    /// the GROUP BY count subquery (a duplicate would inflate the
    /// HAVING-COUNT match threshold and silently drop valid rows).
    private static func dedup<T: Hashable>(_ items: [T]) -> [T] {
        var seen: Set<T> = []
        var out: [T] = []
        for item in items where !seen.contains(item) {
            seen.insert(item)
            out.append(item)
        }
        return out
    }

    // MARK: Smart folder row mapping / encoding

    private static func mapSmartFolder(from row: Row) -> SmartFolder? {
        let jsonText: String = row["query_json"]
        guard let q = decodeQuery(jsonText) else { return nil }
        return SmartFolder(
            id: row["id"],
            name: row["name"],
            query: q,
            sortOrder: Int(row["sort_order"] as Int64),
            isBuiltIn: (row["is_builtin"] as Int64) != 0
        )
    }

    private static func decodeQuery(_ json: String) -> SmartFolderQuery? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SmartFolderQuery.self, from: data)
    }

    private static func encodeQuery(_ q: SmartFolderQuery) throws -> String {
        let data = try JSONEncoder().encode(q)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // ========================================================================
    // MARK: - Plan 07 — Session flags + incremental reindex
    // ========================================================================

    /// Replace the set of flags for a single session. Drops any existing
    /// flag rows first then re-inserts; idempotent for the same input.
    internal func replaceFlags(_ flags: Set<String>, for sessionID: SessionID) async throws {
        let sid = sessionID.description
        let providerKey = currentProvider.rawValue
        try await database.write { [providerKey] db in
            try db.execute(sql: "DELETE FROM session_flags WHERE session_id = ? AND provider = ?",
                           arguments: [sid, providerKey])
            for flag in flags {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO session_flags (session_id, flag_name, provider) VALUES (?, ?, ?)
                    """, arguments: [sid, flag, providerKey])
            }
        }
    }

    /// Legacy 3-arg overload kept for source compatibility. Forwards to
    /// the provider-scoped variant tagged as `.claude` because the only
    /// live caller — `WatcherCoordinator` — historically watched the
    /// `~/.claude/projects/` tree exclusively. New callers should pick
    /// the provider explicitly via the 4-arg form below.
    public func incrementalReindex(paths: Set<URL>,
                                   workspaces: Set<String>,
                                   removedPaths: Set<URL>) async throws {
        try await incrementalReindex(
            paths: paths,
            workspaces: workspaces,
            removedPaths: removedPaths,
            provider: .claude
        )
    }

    /// Re-parses the given jsonl paths and updates sessions_index + session_flags.
    /// Removes rows for files that disappeared. Safe to call on overlapping
    /// inputs (each session is replaced atomically).
    ///
    /// `provider` scopes every INSERT, UPDATE, and DELETE in this pass so
    /// the watcher coordinator's writes carry the provider tag of the
    /// tree it is watching, NOT whatever the user has selected in the
    /// segmented control at flush time. Bug 1: the previous implementation
    /// read `self.currentProvider`, which let Claude FSEvents fire after
    /// the user toggled to Codex / Gemini and tag the resulting Claude rows
    /// with the wrong provider — visible in production as `provider='codex'`
    /// rows whose `workspace_id` was Claude's `-Users-…` folder-encoded form.
    public func incrementalReindex(paths: Set<URL>,
                                   workspaces: Set<String>,
                                   removedPaths: Set<URL>,
                                   provider: ProviderID) async throws {
        // Step A: Parse OUTSIDE the write lock.
        struct Pending {
            let sessionID: SessionID
            let workspaceID: String
            let metadata: SessionMetadata
            let flags: Set<String>
            let fileSize: Int
            let fileMTime: Date
        }

        var pending: [Pending] = []
        for url in paths {
            do {
                switch provider {
                case .claude:
                    let wsID = workspaceIDForPath(url)
                    guard !wsID.isEmpty else { continue }
                    let stem = url.deletingPathExtension().lastPathComponent
                    guard UUID(uuidString: stem) != nil else { continue }
                    let attrs = (try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]))
                    let size = attrs?.fileSize ?? 0
                    let mtime = attrs?.contentModificationDate ?? Date()
                    let (metadata, flags) = try parser.parseWithFlags(url: url, workspaceID: wsID)
                    pending.append(Pending(
                        sessionID: metadata.sessionID,
                        workspaceID: wsID,
                        metadata: metadata,
                        flags: flags,
                        fileSize: size,
                        fileMTime: mtime
                    ))

                case .codex:
                    let codexParser = CodexParser()
                    guard let meta = codexParser.extractMetadata(url: url) else { continue }
                    let wsID = "codex:\(meta.cwd ?? "(unknown)")"
                    let attrs = (try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]))
                    let size = attrs?.fileSize ?? 0
                    let mtime = attrs?.contentModificationDate ?? Date()
                    let (sessionMeta, flags) = try codexParser.parse(url: url, workspaceID: wsID)
                    pending.append(Pending(
                        sessionID: sessionMeta.sessionID,
                        workspaceID: wsID,
                        metadata: sessionMeta,
                        flags: flags,
                        fileSize: size,
                        fileMTime: mtime
                    ))

                case .gemini:
                    let geminiParser = GeminiParser()
                    // Match the bootstrap path's wsID convention: gemini:<project_dir_lastPathComponent>.
                    // The project dir is the file's grandparent directory
                    // (~/.gemini/tmp/<project_dir>/chats/<session>.json). Bootstrap also
                    // uses lastPathComponent of the project dir. Keeping the conventions
                    // identical is required so that live updates land on the same
                    // `workspaces.id` row that bootstrap created. Resolved-cwd form
                    // (which would join cleaner to the metadata pane) is a Phase 4
                    // concern; for now correctness via consistency wins.
                    let projectDirName = url.deletingLastPathComponent()
                        .deletingLastPathComponent()
                        .lastPathComponent
                    let wsID = "gemini:\(projectDirName)"
                    let attrs = (try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]))
                    let size = attrs?.fileSize ?? 0
                    let mtime = attrs?.contentModificationDate ?? Date()
                    do {
                        let (sessionMeta, flags) = try geminiParser.parse(url: url, workspaceID: wsID)
                        pending.append(Pending(
                            sessionID: sessionMeta.sessionID,
                            workspaceID: wsID,
                            metadata: sessionMeta,
                            flags: flags,
                            fileSize: size,
                            fileMTime: mtime
                        ))
                    } catch GeminiParser.ParseError.filtered(_) {
                        // Subagent / system-only sessions are intentionally skipped.
                        continue
                    }
                }
            } catch {
                _bootstrapErrors.append(
                    "incrementalReindex parse error for \(url.lastPathComponent): \(error.localizedDescription)"
                )
            }
        }

        // Step A.5: Resolve session IDs for removed paths (from filename stems).
        let removedIDs: [String] = removedPaths.compactMap { url in
            let stem = url.deletingPathExtension().lastPathComponent
            return (try? SessionID(string: stem))?.description
        }

        // Step B: Ensure the workspaces row exists for any new workspace
        // we've discovered. Using INSERT OR IGNORE so we never clobber an
        // existing human-curated display name. Sniff workspace metadata from
        // the largest jsonl currently on disk so a brand-new workspace gets
        // its real cwd populated even on the incremental path.
        //
        // Provider tag comes from the explicit argument so the FSEvents
        // watcher's writes can never get cross-tagged when the user
        // toggles providers mid-flush.
        //
        // We process the UNION of the caller-supplied `workspaces` set and
        // every workspace_id derived during the parse loop, so per-provider
        // watchers don't have to pre-compute (and double-parse) cwd just to
        // satisfy the sessions_index FK.
        let providerKey = provider.rawValue
        let workspaceIDsToUpsert = workspaces.union(Set(pending.map(\.workspaceID))).filter { !$0.isEmpty }
        for wsID in workspaceIDsToUpsert {
            let decoded = decoder.decode(wsID)
            // Best-effort metadata sniff. Looks at any pending file in this
            // workspace; falls back to nil when no candidate exists.
            let candidate: URL? = paths.first { $0.deletingLastPathComponent().lastPathComponent == wsID }
            let meta = candidate.flatMap { parser.extractWorkspaceMetadata(url: $0) }
            try await database.write { [providerKey] db in
                try db.execute(sql: """
                    INSERT INTO workspaces
                        (id, decoded_path, "group", display_name, indexed_at,
                         cwd, git_branch, claude_version, provider)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        indexed_at = excluded.indexed_at,
                        cwd = COALESCE(excluded.cwd, workspaces.cwd),
                        git_branch = COALESCE(excluded.git_branch, workspaces.git_branch),
                        claude_version = COALESCE(excluded.claude_version, workspaces.claude_version),
                        provider = excluded.provider
                    """, arguments: [
                        wsID, decoded.decodedPath, decoded.group, decoded.displayName, Date(),
                        meta?.cwd, meta?.gitBranch, meta?.version,
                        providerKey,
                    ])
            }
        }

        // Step C: Upsert pending rows (sessions_index + session_flags).
        for p in pending {
            try await database.write { [p, providerKey] db in
                try db.execute(sql: """
                    INSERT INTO sessions_index
                        (session_id, workspace_id, title, created_at, last_modified_at,
                         message_count, token_count, file_size_bytes, file_mtime,
                         total_input_tokens, total_output_tokens, model, provider, file_path)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(session_id) DO UPDATE SET
                        title = excluded.title,
                        last_modified_at = excluded.last_modified_at,
                        message_count = excluded.message_count,
                        token_count = excluded.token_count,
                        file_size_bytes = excluded.file_size_bytes,
                        file_mtime = excluded.file_mtime,
                        total_input_tokens = excluded.total_input_tokens,
                        total_output_tokens = excluded.total_output_tokens,
                        model = COALESCE(excluded.model, sessions_index.model),
                        provider = excluded.provider,
                        file_path = COALESCE(excluded.file_path, sessions_index.file_path)
                    """, arguments: [
                        p.sessionID.description,
                        p.workspaceID,
                        p.metadata.title,
                        p.metadata.createdAt,
                        p.metadata.lastModifiedAt,
                        p.metadata.messageCount,
                        p.metadata.tokenCount,
                        p.fileSize,
                        // file_mtime is REAL (epoch seconds) since v8; bind
                        // as Double so APFS sub-second precision survives.
                        p.fileMTime.timeIntervalSince1970,
                        p.metadata.inputTokens,
                        p.metadata.outputTokens,
                        p.metadata.model,
                        providerKey,
                        // FSEvents-driven incremental reindex only fires on
                        // Claude's `~/.claude/projects` tree today; Claude
                        // sessions resolve via the canonical projectsRoot
                        // path so we leave file_path NULL here. The COALESCE
                        // in the UPSERT preserves any value set by an earlier
                        // bootstrap pass.
                        nil as String?,
                    ])

                // Replace flags for this session. DELETE+INSERT keeps us
                // idempotent when the set shrinks or expands.
                let sid = p.sessionID.description
                try db.execute(sql: """
                    DELETE FROM session_flags WHERE session_id = ? AND provider = ?
                    """, arguments: [sid, providerKey])
                for flag in p.flags {
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO session_flags (session_id, flag_name, provider) VALUES (?, ?, ?)
                        """, arguments: [sid, flag, providerKey])
                }
            }
        }

        // Step D: Drop rows for removed files. Provider-scoped so a
        // file vanishing under one provider can't nuke another's row.
        if !removedIDs.isEmpty {
            try await database.write { [providerKey] db in
                let placeholders = Array(repeating: "?", count: removedIDs.count).joined(separator: ",")
                var args: [DatabaseValueConvertible] = removedIDs
                args.append(providerKey)
                try db.execute(sql: """
                    DELETE FROM session_flags WHERE session_id IN (\(placeholders)) AND provider = ?
                    """, arguments: StatementArguments(args))
                try db.execute(sql: """
                    DELETE FROM sessions_index WHERE session_id IN (\(placeholders)) AND provider = ?
                    """, arguments: StatementArguments(args))
            }
        }
    }

    /// Infers the workspace ID for a jsonl path. Assumes the path shape
    /// `…/projects/<workspace>/<sessionid>.jsonl`. When we have an explicit
    /// `projectsRoot` we use that; otherwise fall back to the parent folder name.
    private func workspaceIDForPath(_ url: URL) -> String {
        if let root = projectsRoot {
            let relative = url.path.hasPrefix(root.path)
                ? String(url.path.dropFirst(root.path.count))
                : url.path
            let trimmed = relative.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let comps = trimmed.split(separator: "/").map(String.init)
            if let first = comps.first { return first }
        }
        return url.deletingLastPathComponent().lastPathComponent
    }
}
