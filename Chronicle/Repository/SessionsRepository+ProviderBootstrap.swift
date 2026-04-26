import Foundation
import GRDB

// MARK: - Codex / Gemini bootstrap
//
// The Claude path's bootstrap walks `~/.claude/projects/<workspace>/<sid>.jsonl`
// — workspace-bucketed on disk. Codex stores everything date-bucketed
// (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`), Gemini stores per
// project_dir (`~/.gemini/tmp/<dir>/chats/session-*.json`). So neither
// fits the existing `bootstrap(rootURL:)` contract — they need their
// own walkers that produce the canonical `WorkspaceData` shape and feed
// it to the same `writeWorkspace` helper.
//
// These bootstraps run when the user switches to a provider whose
// rows aren't in the DB yet. Sequential, not parallel — the file
// counts are typically small enough that the simplicity wins, and
// the call sites already show a progress splash so a few seconds of
// indexing lands in the UI naturally.

public extension SessionsRepository {

    // MARK: - Codex

    /// Walks `~/.codex/sessions/`, parses every rollout file, groups
    /// sessions by their `cwd`, and upserts into the DB scoped as
    /// `provider = 'codex'`. Sets `currentProvider` to `.codex`
    /// before writing so existing repository invariants hold.
    func bootstrapCodex(
        sessionsRoot: URL = CodexProvider.sessionsRoot(),
        progress: (@Sendable (_ fraction: Double, _ message: String) -> Void)? = nil
    ) async throws {
        await setActiveProvider(.codex)
        progress?(0.0, "Scanning \(sessionsRoot.path)")

        let fm = FileManager.default
        let parser = CodexParser()

        // Date tree walk: year → month → day → rollout-*.jsonl.
        // Bounded depth so a corrupted Codex install can't run away.
        //
        // Bug 2: live data showed 9 rollout files on disk but only 1–3
        // landing in `sessions_index`. Tally visited / kept / skipped
        // counts as we walk so any future drift in Codex's filename
        // convention is visible in the unified log without re-instrumenting.
        var rolloutFiles: [URL] = []
        var visitedCount = 0
        var skippedFilenameCount = 0
        if let years = try? fm.contentsOfDirectory(
            at: sessionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for year in years where Self.isDirectory(year) {
                guard let months = try? fm.contentsOfDirectory(
                    at: year, includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for month in months where Self.isDirectory(month) {
                    guard let days = try? fm.contentsOfDirectory(
                        at: month, includingPropertiesForKeys: [.isDirectoryKey],
                        options: [.skipsHiddenFiles]
                    ) else { continue }
                    for day in days where Self.isDirectory(day) {
                        guard let entries = try? fm.contentsOfDirectory(
                            at: day, includingPropertiesForKeys: nil,
                            options: [.skipsHiddenFiles]
                        ) else { continue }
                        for entry in entries {
                            visitedCount += 1
                            if entry.pathExtension == "jsonl"
                                && entry.lastPathComponent.hasPrefix("rollout-") {
                                rolloutFiles.append(entry)
                            } else {
                                skippedFilenameCount += 1
                            }
                        }
                    }
                }
            }
        }

        AppLogger.parser.info(
            "Codex walk: visited=\(visitedCount), kept=\(rolloutFiles.count), filteredByName=\(skippedFilenameCount)"
        )
        progress?(0.1, "Parsing \(rolloutFiles.count) Codex sessions")

        // Group sessions by cwd-derived workspace_id. Sessions whose
        // session_meta lacks a cwd land in a single "(unknown)"
        // workspace so they're still surfaced.
        struct Bucket {
            let workspaceID: String
            let cwd: String?
            var entries: [ParsedSession] = []
        }
        var buckets: [String: Bucket] = [:]

        var parsedCount = 0
        var erroredCount = 0
        for (idx, file) in rolloutFiles.enumerated() {
            let meta = parser.extractMetadata(url: file)
            let cwd = meta?.cwd
            let workspaceID = Self.codexWorkspaceID(forCwd: cwd)

            if buckets[workspaceID] == nil {
                buckets[workspaceID] = Bucket(workspaceID: workspaceID, cwd: cwd)
            }

            let attrs = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = attrs?.fileSize ?? 0
            let mtime = attrs?.contentModificationDate ?? Date()

            do {
                let (sessionMeta, flags) = try parser.parse(url: file, workspaceID: workspaceID)
                buckets[workspaceID]?.entries.append(
                    ParsedSession(
                        metadata: sessionMeta,
                        size: size,
                        mtime: mtime,
                        flags: flags,
                        // Codex rollouts live under a date tree
                        // (`YYYY/MM/DD/rollout-...jsonl`) so the
                        // path isn't recoverable from `(workspace_id,
                        // sessionID)`. Record the absolute path now
                        // so TranscriptRepository can re-open the
                        // file later for the preview pane.
                        filePath: file.path
                    )
                )
                parsedCount += 1
            } catch {
                erroredCount += 1
                AppLogger.parser.error(
                    "Codex parse error for \(file.lastPathComponent): \(error.localizedDescription)"
                )
            }

            if rolloutFiles.count > 0 {
                let frac = 0.1 + (Double(idx + 1) / Double(rolloutFiles.count)) * 0.7
                if (idx + 1) % 10 == 0 || idx + 1 == rolloutFiles.count {
                    progress?(frac, "Parsed \(idx + 1) of \(rolloutFiles.count)")
                }
            }
        }

        AppLogger.parser.info(
            "Codex parse pass: parsed=\(parsedCount), errored=\(erroredCount), total=\(rolloutFiles.count)"
        )

        // Materialise into WorkspaceData and feed the existing writer.
        let now = Date()
        let workspaceData: [WorkspaceData] = buckets.values.map { bucket in
            let displayName = bucket.cwd.flatMap { (URL(fileURLWithPath: $0).lastPathComponent.isEmpty ? nil : URL(fileURLWithPath: $0).lastPathComponent) } ?? bucket.workspaceID
            return WorkspaceData(
                id: bucket.workspaceID,
                decoded: WorkspacePathDecoder.Result(
                    decodedPath: bucket.cwd ?? bucket.workspaceID,
                    group: Self.groupForCwd(bucket.cwd),
                    displayName: displayName
                ),
                indexedAt: now,
                sessions: bucket.entries,
                metadata: JsonlParser.WorkspaceMetadata(
                    cwd: bucket.cwd,
                    gitBranch: nil,
                    version: nil
                )
            )
        }

        progress?(0.85, "Writing \(workspaceData.count) workspaces")
        try await databaseForTests.write { db in
            for wd in workspaceData {
                try Self.writeWorkspace(wd, provider: .codex, into: db)
            }
        }

        // Smart-folder built-ins are per-provider since v9; ensure
        // they exist for Codex too.
        try await ensureBuiltInSmartFolders()
        progress?(1.0, "Indexed \(workspaceData.count) Codex workspaces")
    }

    /// Catch-up reindex for Codex. Walks `~/.codex/sessions/` like the
    /// full bootstrap but skips files already in `sessions_index.file_path`.
    /// Invoked on provider-switch into a Codex provider that was already
    /// bootstrapped earlier in the session — ensures sessions created
    /// while Codex was inactive (i.e. its watcher wasn't running) land
    /// in the DB without requiring an app restart. Idempotent.
    func catchupCodex(
        sessionsRoot: URL = CodexProvider.sessionsRoot()
    ) async throws {
        let known = await knownFilePaths(provider: .codex)
        let fm = FileManager.default
        let parser = CodexParser()

        var rolloutFiles: [URL] = []
        if let years = try? fm.contentsOfDirectory(
            at: sessionsRoot, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for year in years where Self.isDirectory(year) {
                guard let months = try? fm.contentsOfDirectory(
                    at: year, includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for month in months where Self.isDirectory(month) {
                    guard let days = try? fm.contentsOfDirectory(
                        at: month, includingPropertiesForKeys: [.isDirectoryKey],
                        options: [.skipsHiddenFiles]
                    ) else { continue }
                    for day in days where Self.isDirectory(day) {
                        guard let entries = try? fm.contentsOfDirectory(
                            at: day, includingPropertiesForKeys: nil,
                            options: [.skipsHiddenFiles]
                        ) else { continue }
                        for entry in entries
                        where entry.pathExtension == "jsonl"
                            && entry.lastPathComponent.hasPrefix("rollout-") {
                            guard !known.contains(entry.path) else { continue }
                            rolloutFiles.append(entry)
                        }
                    }
                }
            }
        }
        guard !rolloutFiles.isEmpty else {
            AppLogger.parser.info("Codex catch-up: no new sessions")
            return
        }
        AppLogger.parser.info("Codex catch-up: \(rolloutFiles.count) new sessions to index")

        struct Bucket {
            let workspaceID: String
            let cwd: String?
            var entries: [ParsedSession] = []
        }
        var buckets: [String: Bucket] = [:]
        for file in rolloutFiles {
            let meta = parser.extractMetadata(url: file)
            let cwd = meta?.cwd
            let workspaceID = Self.codexWorkspaceID(forCwd: cwd)
            if buckets[workspaceID] == nil {
                buckets[workspaceID] = Bucket(workspaceID: workspaceID, cwd: cwd)
            }
            let attrs = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = attrs?.fileSize ?? 0
            let mtime = attrs?.contentModificationDate ?? Date()
            do {
                let (sessionMeta, flags) = try parser.parse(url: file, workspaceID: workspaceID)
                buckets[workspaceID]?.entries.append(
                    ParsedSession(
                        metadata: sessionMeta,
                        size: size,
                        mtime: mtime,
                        flags: flags,
                        filePath: file.path
                    )
                )
            } catch {
                AppLogger.parser.error("Codex catch-up parse error for \(file.lastPathComponent): \(error.localizedDescription)")
            }
        }

        let now = Date()
        let workspaceData: [WorkspaceData] = buckets.values.map { bucket in
            let displayName = bucket.cwd.flatMap {
                URL(fileURLWithPath: $0).lastPathComponent.isEmpty
                    ? nil : URL(fileURLWithPath: $0).lastPathComponent
            } ?? bucket.workspaceID
            return WorkspaceData(
                id: bucket.workspaceID,
                decoded: WorkspacePathDecoder.Result(
                    decodedPath: bucket.cwd ?? bucket.workspaceID,
                    group: Self.groupForCwd(bucket.cwd),
                    displayName: displayName
                ),
                indexedAt: now,
                sessions: bucket.entries,
                metadata: JsonlParser.WorkspaceMetadata(
                    cwd: bucket.cwd, gitBranch: nil, version: nil
                )
            )
        }

        try await databaseForTests.write { db in
            for wd in workspaceData {
                try Self.writeWorkspace(wd, provider: .codex, into: db)
            }
        }
    }

    /// Stable workspace_id for a Codex session keyed off cwd. Using
    /// the cwd directly keeps the join-friendly invariant intact —
    /// re-runs with the same cwd land in the same workspace row.
    private static func codexWorkspaceID(forCwd cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "codex:(unknown)" }
        return "codex:\(cwd)"
    }

    // MARK: - Gemini

    /// Walks `~/.gemini/tmp/<project_dir>/chats/`, parses each session
    /// JSON, groups by project_dir, and upserts into the DB scoped as
    /// `provider = 'gemini'`. cwd is recovered via reverse lookup in
    /// `~/.gemini/projects.json` for friendly-named project dirs;
    /// hash-named dirs (newer Gemini builds) get a nil cwd and the
    /// metadata pane shows "—" for those.
    func bootstrapGemini(
        tmpRoot: URL = GeminiProvider.tmpRoot(),
        progress: (@Sendable (_ fraction: Double, _ message: String) -> Void)? = nil
    ) async throws {
        await setActiveProvider(.gemini)
        progress?(0.0, "Scanning \(tmpRoot.path)")

        let parser = GeminiParser()
        // Discover project subdirs under the supplied tmpRoot. When the
        // caller passes the default `GeminiProvider.tmpRoot()` this is
        // equivalent to `GeminiProvider.discoverProjectDirs()`; when a
        // test passes a synthetic root, we walk THAT root's children
        // directly so the catch-up tests can use a sandbox tmp dir.
        let projectDirs: [URL] = (try? FileManager.default.contentsOfDirectory(
            at: tmpRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ))?.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        } ?? []
        progress?(0.1, "Found \(projectDirs.count) Gemini projects")

        struct Bucket {
            let workspaceID: String
            let cwd: String?
            var entries: [ParsedSession] = []
        }
        var buckets: [String: Bucket] = [:]
        var totalFiles = 0

        // First pass: count files for progress reporting.
        for dir in projectDirs {
            let chats = dir.appendingPathComponent("chats", isDirectory: true)
            if let files = try? FileManager.default.contentsOfDirectory(
                at: chats, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) {
                totalFiles += files.filter { $0.lastPathComponent.hasPrefix("session-") }.count
            }
        }

        var processed = 0

        for dir in projectDirs {
            let chats = dir.appendingPathComponent("chats", isDirectory: true)
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: chats, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }

            let workspaceID = "gemini:\(dir.lastPathComponent)"
            let cwd = GeminiProvider.cwd(forProjectDirName: dir.lastPathComponent)
            if buckets[workspaceID] == nil {
                buckets[workspaceID] = Bucket(workspaceID: workspaceID, cwd: cwd)
            }

            for file in files where file.lastPathComponent.hasPrefix("session-") && file.pathExtension == "json" {
                let attrs = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let size = attrs?.fileSize ?? 0
                let mtime = attrs?.contentModificationDate ?? Date()

                do {
                    let (sessionMeta, flags) = try parser.parse(url: file, workspaceID: workspaceID)
                    buckets[workspaceID]?.entries.append(
                        ParsedSession(
                            metadata: sessionMeta,
                            size: size,
                            mtime: mtime,
                            flags: flags,
                            // Gemini stores chats under
                            // `~/.gemini/tmp/<project_dir>/chats/...`
                            // — record the absolute path so
                            // TranscriptRepository can re-open it
                            // for the preview pane.
                            filePath: file.path
                        )
                    )
                } catch GeminiParser.ParseError.filtered {
                    // subagent / system-only — silently skipped.
                } catch {
                    AppLogger.parser.error(
                        "Gemini parse error for \(file.lastPathComponent): \(error.localizedDescription)"
                    )
                }

                processed += 1
                if totalFiles > 0 && (processed % 10 == 0 || processed == totalFiles) {
                    let frac = 0.1 + (Double(processed) / Double(totalFiles)) * 0.7
                    progress?(frac, "Parsed \(processed) of \(totalFiles)")
                }
            }
        }

        let now = Date()
        let workspaceData: [WorkspaceData] = buckets.values.compactMap { bucket -> WorkspaceData? in
            // Drop empty workspaces (subagent-only project dirs).
            guard !bucket.entries.isEmpty else { return nil }
            let displayName = bucket.cwd
                .map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? bucket.workspaceID.replacingOccurrences(of: "gemini:", with: "")
            return WorkspaceData(
                id: bucket.workspaceID,
                decoded: WorkspacePathDecoder.Result(
                    decodedPath: bucket.cwd ?? bucket.workspaceID,
                    group: Self.groupForCwd(bucket.cwd),
                    displayName: displayName
                ),
                indexedAt: now,
                sessions: bucket.entries,
                metadata: JsonlParser.WorkspaceMetadata(
                    cwd: bucket.cwd,
                    gitBranch: nil,
                    version: nil
                )
            )
        }

        progress?(0.85, "Writing \(workspaceData.count) workspaces")
        try await databaseForTests.write { db in
            for wd in workspaceData {
                try Self.writeWorkspace(wd, provider: .gemini, into: db)
            }
        }
        try await ensureBuiltInSmartFolders()
        progress?(1.0, "Indexed \(workspaceData.count) Gemini workspaces")
    }

    /// Catch-up reindex for Gemini. Walks `~/.gemini/tmp/<project_dir>/chats/`
    /// like the full bootstrap but skips files already in
    /// `sessions_index.file_path`. Invoked on provider-switch into a
    /// Gemini provider that was already bootstrapped earlier in the
    /// session — sessions created while Gemini was inactive land in
    /// the DB without requiring an app restart. Idempotent.
    func catchupGemini(
        tmpRoot: URL = GeminiProvider.tmpRoot()
    ) async throws {
        let known = await knownFilePaths(provider: .gemini)
        let parser = GeminiParser()
        let projectDirs = (try? FileManager.default.contentsOfDirectory(
            at: tmpRoot, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        struct Bucket {
            let workspaceID: String
            let cwd: String?
            var entries: [ParsedSession] = []
        }
        var buckets: [String: Bucket] = [:]
        var newCount = 0
        for dir in projectDirs where Self.isDirectory(dir) {
            let chats = dir.appendingPathComponent("chats", isDirectory: true)
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: chats, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }

            let workspaceID = "gemini:\(dir.lastPathComponent)"
            let cwd = GeminiProvider.cwd(forProjectDirName: dir.lastPathComponent)
            for file in files
            where file.lastPathComponent.hasPrefix("session-") && file.pathExtension == "json" {
                guard !known.contains(file.path) else { continue }
                newCount += 1
                if buckets[workspaceID] == nil {
                    buckets[workspaceID] = Bucket(workspaceID: workspaceID, cwd: cwd)
                }
                let attrs = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let size = attrs?.fileSize ?? 0
                let mtime = attrs?.contentModificationDate ?? Date()
                do {
                    let (sessionMeta, flags) = try parser.parse(url: file, workspaceID: workspaceID)
                    buckets[workspaceID]?.entries.append(
                        ParsedSession(
                            metadata: sessionMeta,
                            size: size,
                            mtime: mtime,
                            flags: flags,
                            filePath: file.path
                        )
                    )
                } catch GeminiParser.ParseError.filtered(_) {
                    continue
                } catch {
                    AppLogger.parser.error("Gemini catch-up parse error for \(file.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
        guard newCount > 0 else {
            AppLogger.parser.info("Gemini catch-up: no new sessions")
            return
        }
        AppLogger.parser.info("Gemini catch-up: \(newCount) new sessions to index")

        let now = Date()
        let workspaceData: [WorkspaceData] = buckets.values.map { bucket in
            let displayName = bucket.cwd.flatMap {
                URL(fileURLWithPath: $0).lastPathComponent.isEmpty
                    ? nil : URL(fileURLWithPath: $0).lastPathComponent
            } ?? bucket.workspaceID
            return WorkspaceData(
                id: bucket.workspaceID,
                decoded: WorkspacePathDecoder.Result(
                    decodedPath: bucket.cwd ?? bucket.workspaceID,
                    group: Self.groupForCwd(bucket.cwd),
                    displayName: displayName
                ),
                indexedAt: now,
                sessions: bucket.entries,
                metadata: JsonlParser.WorkspaceMetadata(
                    cwd: bucket.cwd, gitBranch: nil, version: nil
                )
            )
        }

        try await databaseForTests.write { db in
            for wd in workspaceData {
                try Self.writeWorkspace(wd, provider: .gemini, into: db)
            }
        }
    }

    // MARK: - Corrupt-row cleanup (Bug 1 / Bug 3)

    /// Drops Codex / Gemini rows whose `id` doesn't carry the canonical
    /// `<provider>:<...>` prefix. These rows can only have been written
    /// by the pre-fix `incrementalReindex` path, which tagged the active
    /// provider rather than the watcher's bound provider — leaving
    /// Claude folder-encoded workspace IDs (e.g. `-Users-…`) under
    /// `provider='codex'`. Cascades to dependent `sessions_index` and
    /// `session_flags` rows via the FK relationship.
    ///
    /// Idempotent: safe to call repeatedly. Gated behind the
    /// `Chronicle.bootstrapDataVersion` bump at call sites so it runs
    /// at most once per upgrade.
    func cleanupCorruptProviderRows() async throws {
        try await databaseForTests.write { db in
            // workspaces FK has ON DELETE CASCADE for sessions_index, but
            // session_flags is keyed only by session_id (no FK), so we
            // delete its rows explicitly first using the same WHERE
            // predicate to avoid orphan flag rows surviving the cleanup.
            for provider in [ProviderID.codex, ProviderID.gemini] {
                let prefix = "\(provider.rawValue):"
                let providerKey = provider.rawValue

                // Drop session_flags whose owning workspace is corrupt.
                try db.execute(
                    sql: """
                    DELETE FROM session_flags
                    WHERE provider = ?
                      AND session_id IN (
                          SELECT session_id FROM sessions_index
                          WHERE provider = ?
                            AND workspace_id NOT LIKE ?
                      )
                    """,
                    arguments: [providerKey, providerKey, "\(prefix)%"]
                )

                // Drop sessions_index rows whose workspace_id isn't
                // namespaced with the provider prefix.
                try db.execute(
                    sql: """
                    DELETE FROM sessions_index
                    WHERE provider = ? AND workspace_id NOT LIKE ?
                    """,
                    arguments: [providerKey, "\(prefix)%"]
                )

                // Drop workspaces rows whose id isn't namespaced.
                try db.execute(
                    sql: """
                    DELETE FROM workspaces
                    WHERE provider = ? AND id NOT LIKE ?
                    """,
                    arguments: [providerKey, "\(prefix)%"]
                )
            }
        }
    }

    // MARK: - Helpers

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    /// Neutral, provider-agnostic sidebar grouping for a cwd. The
    /// previous version pattern-matched substrings like "claude" and
    /// "/ai/" which polluted the Codex / Gemini sidebars whenever the
    /// user's project name happened to contain those tokens (e.g. a
    /// repo called `claude-history-manager`). The Claude provider has
    /// its own decoder-driven grouping path; this method only runs
    /// for the Codex / Gemini bootstraps.
    ///
    /// Rules:
    ///   1. Strip a leading `~/Code/`, `~/Desktop/`, `~/Documents/`
    ///      prefix (absolute or tilde form) so the group key isn't
    ///      "users" for everyone.
    ///   2. After stripping, take the second-to-last directory of the
    ///      remaining path (the "parent project group") if one
    ///      exists, else the last component.
    ///   3. Capitalize the first letter for display so the sidebar
    ///      reads "Apps" / "Security" / "StealthZero" rather than
    ///      shouty all-caps.
    ///
    /// Examples:
    ///   - `/Users/foo/Code/swift/apps/chronicle`     → "Apps"
    ///   - `/Users/foo/Code/security/pentest`         → "Security"
    ///   - `/Users/foo/Desktop/StealthZero/turnitin`  → "StealthZero"
    ///   - `/Users/foo/Documents/notes/diary`         → "Notes"
    ///   - `/Users/foo`                               → "home"
    ///   - `/`                                        → "Other"
    static func groupForCwd(_ cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "Other" }

        // Normalize: trim trailing slashes (but preserve a single "/").
        var path = cwd
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }

        // Resolve "~" so the home check below works regardless of form.
        let home = NSHomeDirectory()
        let expanded: String = {
            if path == "~" || path == "~/" { return home }
            if path.hasPrefix("~/") {
                return home + String(path.dropFirst(1))
            }
            return path
        }()

        // The user's home directory itself groups as "home" — both
        // shells and macOS treat it as a special root, and there's
        // no parent directory to derive a name from.
        if expanded == home { return "home" }

        // Strip the well-known top-level prefixes so the group name
        // is the FIRST meaningful subdirectory under them (or the
        // project itself if there's nothing deeper).
        let prefixes = [
            home + "/Code/",
            home + "/Desktop/",
            home + "/Documents/",
        ]
        var remainder = expanded
        for prefix in prefixes {
            if remainder.hasPrefix(prefix) {
                remainder = String(remainder.dropFirst(prefix.count))
                break
            }
        }

        let components = remainder.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return "Other" }

        // Second-to-last component if it exists (the parent project
        // group), else the last component.
        let chosen: String
        if components.count >= 2 {
            chosen = components[components.count - 2]
        } else {
            chosen = components[0]
        }

        return Self.capitalizeFirstLetter(chosen)
    }

    /// Uppercase the first character only, leaving the rest of the
    /// string untouched. Preserves CamelCase repo names like
    /// "StealthZero" while still tidying lowercase tokens like "apps"
    /// → "Apps". Falls back to "Other" for empty strings.
    private static func capitalizeFirstLetter(_ s: String) -> String {
        guard let first = s.first else { return "Other" }
        return first.uppercased() + s.dropFirst()
    }
}
