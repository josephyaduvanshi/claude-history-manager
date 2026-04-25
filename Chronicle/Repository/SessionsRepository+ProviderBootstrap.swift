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
        var rolloutFiles: [URL] = []
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
                        for entry in entries
                        where entry.pathExtension == "jsonl"
                            && entry.lastPathComponent.hasPrefix("rollout-") {
                            rolloutFiles.append(entry)
                        }
                    }
                }
            }
        }

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
                    ParsedSession(metadata: sessionMeta, size: size, mtime: mtime, flags: flags)
                )
            } catch {
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
        progress: (@Sendable (_ fraction: Double, _ message: String) -> Void)? = nil
    ) async throws {
        await setActiveProvider(.gemini)
        progress?(0.0, "Scanning ~/.gemini/tmp")

        let parser = GeminiParser()
        let projectDirs = GeminiProvider.discoverProjectDirs()
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
                        ParsedSession(metadata: sessionMeta, size: size, mtime: mtime, flags: flags)
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

    // MARK: - Helpers

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    /// Best-effort sidebar grouping for a cwd. Reuses the existing
    /// path-prefix-based heuristics so Codex / Gemini workspaces
    /// land in the same sidebar buckets a Claude workspace at the
    /// same path would.
    private static func groupForCwd(_ cwd: String?) -> String {
        guard let cwd else { return "OTHER" }
        let lower = cwd.lowercased()
        if lower.contains("/flutter") || lower.contains("flutter projects") { return "FLUTTER" }
        if lower.contains("stealthzero") || lower.contains("stealth-zero") { return "SECURITY" }
        if lower.contains("/rust/") || lower.hasSuffix("/rust") { return "RUST" }
        if lower.contains("/go/") || lower.hasSuffix("/go") { return "GO" }
        if lower.contains("/python/") { return "PYTHON" }
        if lower.contains("/web/") || lower.contains("frontend") { return "WEB" }
        if lower.contains("/work/") { return "WORK" }
        if lower.contains("/ai/") || lower.contains("claude") { return "AI/CLAUDE" }
        return "OTHER"
    }
}
