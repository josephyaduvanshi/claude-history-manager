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
    func incrementalReindex(paths: Set<URL>,
                            workspaces: Set<String>,
                            removedPaths: Set<URL>) async throws

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
    static func writeWorkspace(_ wd: WorkspaceData, into db: GRDB.Database) throws {
        try db.execute(
            sql: """
            INSERT INTO workspaces
                (id, decoded_path, "group", display_name, indexed_at,
                 cwd, git_branch, claude_version)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                decoded_path = excluded.decoded_path,
                "group" = excluded."group",
                display_name = excluded.display_name,
                indexed_at = excluded.indexed_at,
                cwd = COALESCE(excluded.cwd, workspaces.cwd),
                git_branch = COALESCE(excluded.git_branch, workspaces.git_branch),
                claude_version = COALESCE(excluded.claude_version, workspaces.claude_version)
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
            ]
        )

        for entry in wd.sessions {
            let m = entry.metadata
            try db.execute(sql: """
                INSERT INTO sessions_index
                    (session_id, workspace_id, title, created_at, last_modified_at,
                     message_count, token_count, file_size_bytes, file_mtime,
                     total_input_tokens, total_output_tokens, model)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(session_id) DO UPDATE SET
                    title = excluded.title,
                    last_modified_at = excluded.last_modified_at,
                    message_count = excluded.message_count,
                    token_count = excluded.token_count,
                    file_size_bytes = excluded.file_size_bytes,
                    file_mtime = excluded.file_mtime,
                    total_input_tokens = excluded.total_input_tokens,
                    total_output_tokens = excluded.total_output_tokens,
                    model = COALESCE(excluded.model, sessions_index.model)
                """,
                arguments: [m.sessionID.description, wd.id, m.title,
                            m.createdAt, m.lastModifiedAt,
                            m.messageCount, m.tokenCount, entry.size,
                            // file_mtime is REAL (epoch seconds) since v8; bind as
                            // Double so APFS sub-second precision survives the round
                            // trip. (GRDB's default Date binding is ISO-8601 TEXT,
                            // which truncates to 1ms granularity.)
                            entry.mtime.timeIntervalSince1970,
                            m.inputTokens, m.outputTokens, m.model])

            let sid = m.sessionID.description
            try db.execute(sql: "DELETE FROM session_flags WHERE session_id = ?",
                           arguments: [sid])
            for flag in entry.flags {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO session_flags (session_id, flag_name) VALUES (?, ?)
                    """, arguments: [sid, flag])
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
        let cachedAttrs: [String: CachedFileAttrs]
        do {
            cachedAttrs = try await database.read { db in
                var map: [String: CachedFileAttrs] = [:]
                let cursor = try Row.fetchCursor(
                    db,
                    sql: "SELECT session_id, file_size_bytes, file_mtime FROM sessions_index"
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
            cachedWorkspaceMeta = try await database.read { db in
                var map: [String: JsonlParser.WorkspaceMetadata] = [:]
                let cursor = try Row.fetchCursor(
                    db,
                    sql: """
                        SELECT id, cwd, git_branch, claude_version
                        FROM workspaces
                        WHERE cwd IS NOT NULL
                           OR git_branch IS NOT NULL
                           OR claude_version IS NOT NULL
                        """
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

        do {
            try await database.write { db in
                for (idx, wd) in workspaceDataList.enumerated() {
                    // Per-workspace SAVEPOINT so a single bad workspace can
                    // roll back without aborting the whole bulk transaction.
                    do {
                        try db.inSavepoint {
                            try Self.writeWorkspace(wd, into: db)
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
                try await database.write { db in
                    try Self.writeWorkspace(wd, into: db)
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
                    try await database.write { db in
                        // Chunk to keep the SQL placeholder count well under
                        // SQLite's default 999 limit even on extreme
                        // databases. Hard-delete from sessions_index +
                        // session_flags only; leave user_metadata intact so
                        // notes/tags survive accidental file removals.
                        let chunkSize = 500
                        var i = 0
                        while i < orphanList.count {
                            let end = min(i + chunkSize, orphanList.count)
                            let chunk = Array(orphanList[i..<end])
                            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                            try db.execute(
                                sql: "DELETE FROM session_flags WHERE session_id IN (\(placeholders))",
                                arguments: StatementArguments(chunk)
                            )
                            try db.execute(
                                sql: "DELETE FROM sessions_index WHERE session_id IN (\(placeholders))",
                                arguments: StatementArguments(chunk)
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
        try await database.read { db in
            let rows = try Row.fetchAll(db,
                sql: #"""
                    SELECT id, decoded_path, "group", display_name,
                           cwd, git_branch, claude_version
                    FROM workspaces
                    ORDER BY "group", display_name
                    """#)
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
        try await database.read { db in
            var sql = """
                SELECT s.session_id, s.workspace_id,
                       COALESCE(u.custom_title, s.title) AS title,
                       s.created_at, s.last_modified_at,
                       s.message_count, s.token_count,
                       s.total_input_tokens, s.total_output_tokens, s.model
                FROM sessions_index s
                LEFT JOIN user_metadata u ON u.session_id = s.session_id
                WHERE s.workspace_id = ?
                """
            if !includeDeleted {
                sql += "\n  AND COALESCE(u.is_deleted, 0) = 0"
            }
            if !includeArchived {
                sql += "\n  AND COALESCE(u.is_archived, 0) = 0"
            }
            sql += "\nORDER BY s.last_modified_at DESC"
            let rows = try Row.fetchAll(db, sql: sql, arguments: [id])
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
        try await database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.session_id, s.workspace_id,
                       COALESCE(u.custom_title, s.title) AS title,
                       s.created_at, s.last_modified_at,
                       s.message_count, s.token_count,
                       s.total_input_tokens, s.total_output_tokens, s.model
                FROM sessions_index s
                LEFT JOIN user_metadata u ON u.session_id = s.session_id
                WHERE COALESCE(u.is_deleted, 0) = 0
                  AND COALESCE(u.is_archived, 0) = 0
                ORDER BY s.last_modified_at DESC
                LIMIT ?
                """, arguments: [limit])
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
        return try await database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.session_id, s.workspace_id,
                       COALESCE(u.custom_title, s.title) AS title,
                       s.created_at, s.last_modified_at,
                       s.message_count, s.token_count,
                       s.total_input_tokens, s.total_output_tokens, s.model
                FROM sessions_index s
                LEFT JOIN user_metadata u ON u.session_id = s.session_id
                WHERE s.last_modified_at >= ?
                  AND COALESCE(u.is_deleted, 0) = 0
                  AND COALESCE(u.is_archived, 0) = 0
                ORDER BY s.last_modified_at DESC
                LIMIT ?
                """, arguments: [cutoff, limit])
            return try rows.map { try Self.mapSession(from: $0, liveCutoff: liveCutoff) }
        }
    }

    /// Total non-deleted, non-archived session count across all workspaces.
    public func totalSessionCount() async throws -> Int {
        try await database.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM sessions_index s
                LEFT JOIN user_metadata u ON u.session_id = s.session_id
                WHERE COALESCE(u.is_deleted, 0) = 0
                  AND COALESCE(u.is_archived, 0) = 0
                """) ?? 0
        }
    }

    /// Returns sessions considered "live", last modified within
    /// `liveWindowSeconds`. `isLive` is set to `true` on each row. Ordered
    /// most-recent first. Excludes deleted + archived rows.
    public func liveSessions() async throws -> [SessionMetadata] {
        let liveCutoff = Date().addingTimeInterval(-Self.liveWindowSeconds)
        return try await database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.session_id, s.workspace_id,
                       COALESCE(u.custom_title, s.title) AS title,
                       s.created_at, s.last_modified_at,
                       s.message_count, s.token_count,
                       s.total_input_tokens, s.total_output_tokens, s.model
                FROM sessions_index s
                LEFT JOIN user_metadata u ON u.session_id = s.session_id
                WHERE s.last_modified_at >= ?
                  AND COALESCE(u.is_deleted, 0) = 0
                  AND COALESCE(u.is_archived, 0) = 0
                ORDER BY s.last_modified_at DESC
                """, arguments: [liveCutoff])
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
                   s.message_count, s.token_count
            FROM sessions_index s
            LEFT JOIN user_metadata u ON u.session_id = s.session_id
            """
        var args: [DatabaseValueConvertible] = []
        var clauses: [String] = [
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
        return try await database.read { db in
            var out: [String] = []
            var seen: Set<String> = []
            for needle in needles {
                let like = "%\(Self.escapeLike(needle.lowercased()))%"
                let rows = try String.fetchAll(db, sql: """
                    SELECT id FROM workspaces
                    WHERE LOWER(display_name) LIKE ? ESCAPE '\\' OR LOWER(decoded_path) LIKE ? ESCAPE '\\'
                    """, arguments: [like, like])
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
            isLive: isLive
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
        return try await database.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT is_pinned, is_archived, is_deleted, deleted_at,
                       custom_title, note, updated_at
                FROM user_metadata
                WHERE session_id = ?
                """, arguments: [sid])
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
        return try await database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT t.id, t.name, t.color_hue
                FROM tags t
                INNER JOIN session_tags st ON st.tag_id = t.id
                WHERE st.session_id = ?
                ORDER BY t.name COLLATE NOCASE ASC
                """, arguments: [sid])
            return rows.map { row in
                Tag(id: row["id"], name: row["name"], colorHue: row["color_hue"])
            }
        }
    }

    public func allTags() async throws -> [Tag] {
        try await database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, name, color_hue FROM tags ORDER BY name COLLATE NOCASE ASC
                """)
            return rows.map { Tag(id: $0["id"], name: $0["name"], colorHue: $0["color_hue"]) }
        }
    }

    /// Number of (non-deleted, non-archived) sessions per tag id.
    public func tagCounts() async throws -> [Int64: Int] {
        try await database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT st.tag_id AS tag_id, COUNT(*) AS n
                FROM session_tags st
                LEFT JOIN user_metadata u ON u.session_id = st.session_id
                WHERE COALESCE(u.is_deleted, 0) = 0
                  AND COALESCE(u.is_archived, 0) = 0
                GROUP BY st.tag_id
                """)
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
        try await loadSessionsWithMetadata(sql: """
            SELECT s.session_id, s.workspace_id,
                   COALESCE(u.custom_title, s.title) AS title,
                   s.created_at, s.last_modified_at,
                   s.message_count, s.token_count,
                   s.total_input_tokens, s.total_output_tokens, s.model,
                   u.is_pinned, u.is_archived, u.is_deleted, u.deleted_at,
                   u.custom_title, u.note, u.updated_at
            FROM sessions_index s
            INNER JOIN user_metadata u ON u.session_id = s.session_id
            WHERE u.is_pinned = 1
              AND u.is_deleted = 0
              AND u.is_archived = 0
            ORDER BY u.updated_at DESC
            LIMIT ?
            """, arguments: [limit])
    }

    /// Up to `limit` archived sessions, newest `updated_at` first. Excludes deleted rows.
    public func archivedSessions(limit: Int = 200) async throws -> [SessionWithMetadata] {
        try await loadSessionsWithMetadata(sql: """
            SELECT s.session_id, s.workspace_id,
                   COALESCE(u.custom_title, s.title) AS title,
                   s.created_at, s.last_modified_at,
                   s.message_count, s.token_count,
                   s.total_input_tokens, s.total_output_tokens, s.model,
                   u.is_pinned, u.is_archived, u.is_deleted, u.deleted_at,
                   u.custom_title, u.note, u.updated_at
            FROM sessions_index s
            INNER JOIN user_metadata u ON u.session_id = s.session_id
            WHERE u.is_archived = 1
              AND u.is_deleted = 0
            ORDER BY u.updated_at DESC
            LIMIT ?
            """, arguments: [limit])
    }

    /// Number of archived (non-deleted) sessions; used by the sidebar.
    public func archivedCount() async throws -> Int {
        try await database.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM user_metadata
                WHERE is_archived = 1 AND is_deleted = 0
                """) ?? 0
        }
    }

    /// Sessions with the given tag applied (excludes deleted + archived).
    public func sessionsForTag(_ tag: Tag, limit: Int = 200) async throws -> [SessionWithMetadata] {
        try await loadSessionsWithMetadata(sql: """
            SELECT s.session_id, s.workspace_id,
                   COALESCE(u.custom_title, s.title) AS title,
                   s.created_at, s.last_modified_at,
                   s.message_count, s.token_count,
                   s.total_input_tokens, s.total_output_tokens, s.model,
                   u.is_pinned, u.is_archived, u.is_deleted, u.deleted_at,
                   u.custom_title, u.note, u.updated_at
            FROM sessions_index s
            INNER JOIN session_tags st ON st.session_id = s.session_id
            LEFT JOIN user_metadata u ON u.session_id = s.session_id
            WHERE st.tag_id = ?
              AND COALESCE(u.is_deleted, 0) = 0
              AND COALESCE(u.is_archived, 0) = 0
            ORDER BY s.last_modified_at DESC
            LIMIT ?
            """, arguments: [tag.id, limit])
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

        // Fetch applied tags for the whole batch in one go.
        let sessionIDs = core.map { $0.0.sessionID.description }
        let tagsBySession: [String: [Tag]] = try await database.read { db in
            let placeholders = Array(repeating: "?", count: sessionIDs.count).joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: """
                SELECT st.session_id AS session_id, t.id AS id, t.name AS name, t.color_hue AS color_hue
                FROM session_tags st
                INNER JOIN tags t ON t.id = st.tag_id
                WHERE st.session_id IN (\(placeholders))
                ORDER BY t.name COLLATE NOCASE ASC
                """, arguments: StatementArguments(sessionIDs))
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
        let resolvedWsID: String? = try await {
            if let workspaceID { return workspaceID }
            return try await database.read { db in
                try String.fetchOne(db,
                    sql: "SELECT workspace_id FROM sessions_index WHERE session_id = ?",
                    arguments: [sessionID.description])
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
        try await database.write { db in
            let expired = try String.fetchAll(db, sql: """
                SELECT session_id FROM user_metadata
                WHERE is_deleted = 1 AND deleted_at IS NOT NULL AND deleted_at < ?
                """, arguments: [cutoff])
            guard !expired.isEmpty else { return }
            let placeholders = Array(repeating: "?", count: expired.count).joined(separator: ",")
            try db.execute(sql: "DELETE FROM session_tags WHERE session_id IN (\(placeholders))",
                           arguments: StatementArguments(expired))
            try db.execute(sql: "DELETE FROM user_metadata WHERE session_id IN (\(placeholders))",
                           arguments: StatementArguments(expired))
            try db.execute(sql: "DELETE FROM sessions_index WHERE session_id IN (\(placeholders))",
                           arguments: StatementArguments(expired))
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
        return try await database.write { db in
            do {
                try db.execute(sql: """
                    INSERT INTO tags (name, color_hue) VALUES (?, ?)
                    """, arguments: [trimmed, hue])
            } catch let err as DatabaseError where err.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
                throw TagError.alreadyExists(trimmed)
            }
            let row = try Row.fetchOne(db, sql: """
                SELECT id, name, color_hue FROM tags WHERE name = ? COLLATE NOCASE
                """, arguments: [trimmed])!
            return Tag(id: row["id"], name: row["name"], colorHue: row["color_hue"])
        }
    }

    public func renameTag(_ id: Int64, to name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TagError.emptyName }
        try await database.write { db in
            do {
                try db.execute(sql: "UPDATE tags SET name = ? WHERE id = ?",
                               arguments: [trimmed, id])
            } catch let err as DatabaseError where err.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
                throw TagError.alreadyExists(trimmed)
            }
        }
    }

    public func deleteTag(_ id: Int64) async throws {
        try await database.write { db in
            // Foreign-key ON DELETE CASCADE handles session_tags cleanup.
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "DELETE FROM tags WHERE id = ?", arguments: [id])
        }
    }

    /// Replace the set of tags applied to a session.
    public func setTags(_ tagIDs: [Int64], for sessionID: SessionID) async throws {
        let sid = sessionID.description
        try await database.write { db in
            try db.execute(sql: "DELETE FROM session_tags WHERE session_id = ?",
                           arguments: [sid])
            for tagID in tagIDs {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO session_tags (session_id, tag_id) VALUES (?, ?)
                    """, arguments: [sid, tagID])
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
        try await database.write { db in
            let current: UserMetadata
            if let row = try Row.fetchOne(db, sql: """
                SELECT is_pinned, is_archived, is_deleted, deleted_at,
                       custom_title, note, updated_at
                FROM user_metadata
                WHERE session_id = ?
                """, arguments: [sid]) {
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

            try db.execute(sql: """
                INSERT INTO user_metadata
                    (session_id, is_pinned, is_archived, is_deleted, deleted_at,
                     custom_title, note, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(session_id) DO UPDATE SET
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
        try await database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, name, query_json, sort_order, is_builtin
                FROM smart_folders
                ORDER BY sort_order ASC, id ASC
                """)
            return rows.compactMap { Self.mapSmartFolder(from: $0) }
        }
    }

    /// Seeds the four built-in smart folders if they don't already exist
    /// (matched by name). Safe to call on every bootstrap; idempotent.
    ///
    /// Intentionally `internal`: only called from `bootstrap(rootURL:progress:)`
    /// inside this actor and from `@testable`-importing tests. Not part of any
    /// sub-protocol; promoting to `public` would expose an internal seeding
    /// helper to the wider app surface for no caller benefit.
    internal func ensureBuiltInSmartFolders() async throws {
        try await database.write { db in
            for builtin in SmartFolder.builtIns {
                let existing = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM smart_folders
                    WHERE name = ? COLLATE NOCASE
                    """, arguments: [builtin.name]) ?? 0
                if existing == 0 {
                    let json = try Self.encodeQuery(builtin.query)
                    try db.execute(sql: """
                        INSERT INTO smart_folders (name, query_json, sort_order, is_builtin)
                        VALUES (?, ?, ?, 1)
                        """, arguments: [builtin.name, json, builtin.sortOrder])
                }
            }
        }
    }

    public func createSmartFolder(name: String, query: SmartFolderQuery) async throws -> SmartFolder {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SmartFolderError.emptyName }
        let json = try Self.encodeQuery(query)
        return try await database.write { db in
            let maxOrder = try Int.fetchOne(db, sql:
                "SELECT COALESCE(MAX(sort_order), 0) FROM smart_folders") ?? 0
            try db.execute(sql: """
                INSERT INTO smart_folders (name, query_json, sort_order, is_builtin)
                VALUES (?, ?, ?, 0)
                """, arguments: [trimmed, json, maxOrder + 1])
            let newID = db.lastInsertedRowID
            return SmartFolder(id: newID,
                               name: trimmed,
                               query: query,
                               sortOrder: maxOrder + 1,
                               isBuiltIn: false)
        }
    }

    public func deleteSmartFolder(_ id: Int64) async throws {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM smart_folders WHERE id = ?", arguments: [id])
        }
    }

    public func renameSmartFolder(_ id: Int64, to name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SmartFolderError.emptyName }
        try await database.write { db in
            try db.execute(sql: "UPDATE smart_folders SET name = ? WHERE id = ?",
                           arguments: [trimmed, id])
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
        let (sql, args) = try await Self.buildCompoundSQL(
            cq,
            select: """
                SELECT s.session_id, s.workspace_id,
                       COALESCE(u.custom_title, s.title) AS title,
                       s.created_at, s.last_modified_at,
                       s.message_count, s.token_count,
                       s.total_input_tokens, s.total_output_tokens, s.model,
                       u.is_pinned, u.is_archived, u.is_deleted, u.deleted_at,
                       u.custom_title, u.note, u.updated_at
                """,
            order: "ORDER BY s.last_modified_at DESC",
            limit: limit,
            ftsIndexer: ftsIndex,
            allWorkspaceIDs: { try await self.allWorkspaces().map(\.id) }
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
        let (sql, args) = try await Self.buildCompoundSQL(
            cq,
            select: "SELECT COUNT(DISTINCT s.session_id) AS n",
            order: nil,
            limit: nil,
            ftsIndexer: ftsIndex,
            allWorkspaceIDs: { try await self.allWorkspaces().map(\.id) }
        )
        return try await database.read { db in
            try Int.fetchOne(db, sql: sql, arguments: StatementArguments(args)) ?? 0
        }
    }

    private func countSessionsSince(_ cutoff: Date) async throws -> Int {
        try await database.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM sessions_index s
                LEFT JOIN user_metadata u ON u.session_id = s.session_id
                WHERE s.last_modified_at >= ?
                  AND COALESCE(u.is_deleted, 0) = 0
                  AND COALESCE(u.is_archived, 0) = 0
                """, arguments: [cutoff]) ?? 0
        }
    }

    private func countSessionsWithFlag(_ flag: String) async throws -> Int {
        try await database.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*)
                FROM session_flags f
                INNER JOIN sessions_index s ON s.session_id = f.session_id
                LEFT JOIN user_metadata u ON u.session_id = s.session_id
                WHERE f.flag_name = ?
                  AND COALESCE(u.is_deleted, 0) = 0
                  AND COALESCE(u.is_archived, 0) = 0
                """, arguments: [flag]) ?? 0
        }
    }

    private func sessionsByDateRange(since cutoff: Date,
                                     limit: Int) async throws -> [SessionWithMetadata] {
        try await loadSessionsWithMetadata(sql: """
            SELECT s.session_id, s.workspace_id,
                   COALESCE(u.custom_title, s.title) AS title,
                   s.created_at, s.last_modified_at,
                   s.message_count, s.token_count,
                   s.total_input_tokens, s.total_output_tokens, s.model,
                   u.is_pinned, u.is_archived, u.is_deleted, u.deleted_at,
                   u.custom_title, u.note, u.updated_at
            FROM sessions_index s
            LEFT JOIN user_metadata u ON u.session_id = s.session_id
            WHERE s.last_modified_at >= ?
              AND COALESCE(u.is_deleted, 0) = 0
              AND COALESCE(u.is_archived, 0) = 0
            ORDER BY s.last_modified_at DESC
            LIMIT ?
            """, arguments: [cutoff, limit])
    }

    private func sessionsWithFlag(_ flag: String,
                                  limit: Int) async throws -> [SessionWithMetadata] {
        try await loadSessionsWithMetadata(sql: """
            SELECT s.session_id, s.workspace_id,
                   COALESCE(u.custom_title, s.title) AS title,
                   s.created_at, s.last_modified_at,
                   s.message_count, s.token_count,
                   s.total_input_tokens, s.total_output_tokens, s.model,
                   u.is_pinned, u.is_archived, u.is_deleted, u.deleted_at,
                   u.custom_title, u.note, u.updated_at
            FROM sessions_index s
            INNER JOIN session_flags f ON f.session_id = s.session_id
            LEFT JOIN user_metadata u ON u.session_id = s.session_id
            WHERE f.flag_name = ?
              AND COALESCE(u.is_deleted, 0) = 0
              AND COALESCE(u.is_archived, 0) = 0
            ORDER BY s.last_modified_at DESC
            LIMIT ?
            """, arguments: [flag, limit])
    }

    /// Hydrate bare [SessionMetadata] into [SessionWithMetadata] by looking up
    /// each row's user_metadata + tags in batch. Used for .search/.custom
    /// smart folders where the underlying repo.search(query:) returns bare
    /// SessionMetadata.
    private func hydrate(_ bare: [SessionMetadata]) async throws -> [SessionWithMetadata] {
        guard !bare.isEmpty else { return [] }
        let ids = bare.map { $0.sessionID.description }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")

        let (metaByID, tagsByID): ([String: UserMetadata], [String: [Tag]]) = try await database.read { db in
            var metaMap: [String: UserMetadata] = [:]
            let metaRows = try Row.fetchAll(db, sql: """
                SELECT session_id, is_pinned, is_archived, is_deleted, deleted_at,
                       custom_title, note, updated_at
                FROM user_metadata
                WHERE session_id IN (\(placeholders))
                """, arguments: StatementArguments(ids))
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
            let tagRows = try Row.fetchAll(db, sql: """
                SELECT st.session_id AS session_id, t.id AS id, t.name AS name, t.color_hue AS color_hue
                FROM session_tags st
                INNER JOIN tags t ON t.id = st.tag_id
                WHERE st.session_id IN (\(placeholders))
                ORDER BY t.name COLLATE NOCASE ASC
                """, arguments: StatementArguments(ids))
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
        allWorkspaceIDs: () async throws -> [String]
    ) async throws -> (String, [DatabaseValueConvertible]) {
        var joins: [String] = ["LEFT JOIN user_metadata u ON u.session_id = s.session_id"]
        var clauses: [String] = [
            "COALESCE(u.is_deleted, 0) = 0",
            "COALESCE(u.is_archived, 0) = 0",
        ]
        var args: [DatabaseValueConvertible] = []

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
                    WHERE tag_id IN (\(placeholders))
                    GROUP BY session_id
                    HAVING COUNT(DISTINCT tag_id) = ?
                )
                """)
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
                    WHERE flag_name IN (\(placeholders))
                    GROUP BY session_id
                    HAVING COUNT(DISTINCT flag_name) = ?
                )
                """)
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
        try await database.write { db in
            try db.execute(sql: "DELETE FROM session_flags WHERE session_id = ?",
                           arguments: [sid])
            for flag in flags {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO session_flags (session_id, flag_name) VALUES (?, ?)
                    """, arguments: [sid, flag])
            }
        }
    }

    /// Re-parses the given jsonl paths and updates sessions_index + session_flags.
    /// Removes rows for files that disappeared. Safe to call on overlapping
    /// inputs (each session is replaced atomically).
    public func incrementalReindex(paths: Set<URL>,
                                   workspaces: Set<String>,
                                   removedPaths: Set<URL>) async throws {
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
            let wsID = workspaceIDForPath(url)
            guard !wsID.isEmpty else { continue }
            // Skip non-UUID jsonl files (e.g. `agent-<id>.jsonl` subagent
            // transcripts); silently, no error spam.
            let stem = url.deletingPathExtension().lastPathComponent
            guard UUID(uuidString: stem) != nil else { continue }
            let attrs = (try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]))
            let size = attrs?.fileSize ?? 0
            let mtime = attrs?.contentModificationDate ?? Date()
            do {
                let (metadata, flags) = try parser.parseWithFlags(url: url, workspaceID: wsID)
                pending.append(Pending(
                    sessionID: metadata.sessionID,
                    workspaceID: wsID,
                    metadata: metadata,
                    flags: flags,
                    fileSize: size,
                    fileMTime: mtime
                ))
            } catch {
                _bootstrapErrors.append("incrementalReindex parse error for \(url.lastPathComponent): \(error.localizedDescription)")
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
        for wsID in workspaces where !wsID.isEmpty {
            let decoded = decoder.decode(wsID)
            // Best-effort metadata sniff. Looks at any pending file in this
            // workspace; falls back to nil when no candidate exists.
            let candidate: URL? = paths.first { $0.deletingLastPathComponent().lastPathComponent == wsID }
            let meta = candidate.flatMap { parser.extractWorkspaceMetadata(url: $0) }
            try await database.write { db in
                try db.execute(sql: """
                    INSERT INTO workspaces
                        (id, decoded_path, "group", display_name, indexed_at,
                         cwd, git_branch, claude_version)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        indexed_at = excluded.indexed_at,
                        cwd = COALESCE(excluded.cwd, workspaces.cwd),
                        git_branch = COALESCE(excluded.git_branch, workspaces.git_branch),
                        claude_version = COALESCE(excluded.claude_version, workspaces.claude_version)
                    """, arguments: [
                        wsID, decoded.decodedPath, decoded.group, decoded.displayName, Date(),
                        meta?.cwd, meta?.gitBranch, meta?.version,
                    ])
            }
        }

        // Step C: Upsert pending rows (sessions_index + session_flags).
        for p in pending {
            try await database.write { [p] db in
                try db.execute(sql: """
                    INSERT INTO sessions_index
                        (session_id, workspace_id, title, created_at, last_modified_at,
                         message_count, token_count, file_size_bytes, file_mtime,
                         total_input_tokens, total_output_tokens, model)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(session_id) DO UPDATE SET
                        title = excluded.title,
                        last_modified_at = excluded.last_modified_at,
                        message_count = excluded.message_count,
                        token_count = excluded.token_count,
                        file_size_bytes = excluded.file_size_bytes,
                        file_mtime = excluded.file_mtime,
                        total_input_tokens = excluded.total_input_tokens,
                        total_output_tokens = excluded.total_output_tokens,
                        model = COALESCE(excluded.model, sessions_index.model)
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
                    ])

                // Replace flags for this session. DELETE+INSERT keeps us
                // idempotent when the set shrinks or expands.
                let sid = p.sessionID.description
                try db.execute(sql: "DELETE FROM session_flags WHERE session_id = ?",
                               arguments: [sid])
                for flag in p.flags {
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO session_flags (session_id, flag_name) VALUES (?, ?)
                        """, arguments: [sid, flag])
                }
            }
        }

        // Step D: Drop rows for removed files.
        if !removedIDs.isEmpty {
            try await database.write { db in
                let placeholders = Array(repeating: "?", count: removedIDs.count).joined(separator: ",")
                try db.execute(sql: "DELETE FROM session_flags WHERE session_id IN (\(placeholders))",
                               arguments: StatementArguments(removedIDs))
                try db.execute(sql: "DELETE FROM sessions_index WHERE session_id IN (\(placeholders))",
                               arguments: StatementArguments(removedIDs))
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
