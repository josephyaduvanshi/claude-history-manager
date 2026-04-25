import Foundation
import GRDB

/// Lazily populates the `transcript_fts` FTS5 virtual table from on-disk `.jsonl`
/// session files. Designed to be called ONLY when a `/full:` query needs
/// transcript-level search; populating transcripts for all ~3k sessions on
/// startup would take ~60–90s, so we defer that cost.
///
/// Usage:
/// ```swift
/// let index = FtsIndex(database: dbq, projectsRoot: ~/.claude/projects)
/// try await index.ensureIndexed(workspaceIDs: ["-my-workspace"]) { progress in
///     // 0.0 ... 1.0
/// }
/// ```
public actor FtsIndex {
    public enum IndexError: Error {
        case workspaceDirectoryUnreadable(String)
    }

    private let database: any DatabaseWriter
    private let projectsRoot: URL
    private let parser: JsonlParser
    private let fm = FileManager.default

    public init(database: any DatabaseWriter,
                projectsRoot: URL,
                parser: JsonlParser = JsonlParser()) {
        self.database = database
        self.projectsRoot = projectsRoot
        self.parser = parser
    }

    // MARK: - Public API

    /// Populates `transcript_fts` for every given workspace that isn't already in
    /// `fts_state`. Reports fraction complete (0.0 ... 1.0) via `progress`.
    ///
    /// - Parameters:
    ///   - workspaceIDs: the workspaces to ensure are indexed. Empty = no-op.
    ///   - forceRebuild: if true, re-index even if `fts_state` already has a row.
    ///   - progress: called (on the actor's task) after each workspace finishes.
    public func ensureIndexed(workspaceIDs: [String],
                              forceRebuild: Bool = false,
                              progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard !workspaceIDs.isEmpty else {
            progress?(1.0)
            return
        }

        // Filter down to workspaces that still need indexing (unless forcing).
        let needsIndex: [String]
        if forceRebuild {
            needsIndex = workspaceIDs
        } else {
            let already = try await database.read { db in
                try Set(String.fetchAll(db,
                    sql: "SELECT workspace_id FROM fts_state WHERE workspace_id IN (\(Self.placeholders(workspaceIDs.count)))",
                    arguments: StatementArguments(workspaceIDs)))
            }
            needsIndex = workspaceIDs.filter { !already.contains($0) }
        }

        if needsIndex.isEmpty {
            progress?(1.0)
            return
        }

        let total = Double(needsIndex.count)
        for (i, wsID) in needsIndex.enumerated() {
            try Task.checkCancellation()
            try await indexWorkspace(id: wsID, forceRebuild: forceRebuild)
            progress?(Double(i + 1) / total)
        }
    }

    /// True when `fts_state` has a row for the given workspace.
    public func isIndexed(workspaceID: String) async -> Bool {
        (try? await database.read { db in
            try Bool.fetchOne(db,
                              sql: "SELECT 1 FROM fts_state WHERE workspace_id = ?",
                              arguments: [workspaceID]) ?? false
        }) ?? false
    }

    // MARK: - Internal

    private func indexWorkspace(id wsID: String, forceRebuild: Bool) async throws {
        let folder = projectsRoot.appendingPathComponent(wsID, isDirectory: true)
        let files: [URL]
        do {
            files = try fm.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "jsonl" }
        } catch {
            throw IndexError.workspaceDirectoryUnreadable(wsID)
        }

        // Parse OUTSIDE the write lock so we don't block other readers. We
        // collect (sessionID, title, body) triples and flush them in one
        // transaction at the end.
        struct Row {
            let sessionID: String
            let title: String
            let body: String
        }

        var rows: [Row] = []
        rows.reserveCapacity(files.count)

        for file in files {
            try Task.checkCancellation()
            let stem = file.deletingPathExtension().lastPathComponent
            // Title best-effort; we re-use the full parse so we get the same
            // title the UI shows. A parse error skips this file entirely.
            let title: String
            if let m = try? parser.parse(url: file, workspaceID: wsID) {
                title = m.title
            } else {
                title = ""
            }
            let body: String
            do {
                body = try parser.extractPlaintext(url: file)
            } catch {
                // Unreadable file; skip rather than abort the whole workspace.
                continue
            }
            rows.append(Row(sessionID: stem, title: title, body: body))
        }

        try Task.checkCancellation()

        let now = Int(Date().timeIntervalSince1970)
        let toWrite = rows
        try await database.write { db in
            if forceRebuild {
                try db.execute(
                    sql: "DELETE FROM transcript_fts WHERE workspace_id = ?",
                    arguments: [wsID]
                )
            }

            for row in toWrite {
                try db.execute(sql: """
                    INSERT INTO transcript_fts(session_id, workspace_id, title, body)
                    VALUES (?, ?, ?, ?)
                    """,
                    arguments: [row.sessionID, wsID, row.title, row.body])
            }

            try db.execute(sql: """
                INSERT INTO fts_state(workspace_id, last_indexed_at)
                VALUES (?, ?)
                ON CONFLICT(workspace_id) DO UPDATE SET last_indexed_at = excluded.last_indexed_at
                """,
                arguments: [wsID, now])
        }
    }

    private static func placeholders(_ n: Int) -> String {
        Array(repeating: "?", count: n).joined(separator: ",")
    }
}
