import Foundation

/// Reads full session transcripts from disk. Lazy; only invoked
/// when the user opens the transcript view (or the preview pane wants
/// Files Touched / Tools Used). Lives as a separate actor from
/// `SessionsRepository` so a long transcript parse can't block
/// menubar / sidebar queries against the SQLite index.
///
/// Provider-aware as of v0.2: Claude sessions resolve via the canonical
/// `projectsRoot/<workspaceID>/<sessionID>.jsonl` path, while Codex and
/// Gemini sessions read the absolute path recorded in
/// `sessions_index.file_path` at index time (their on-disk layout
/// isn't reconstructible from `(workspace_id, sessionID)` alone).
public actor TranscriptRepository {
    private let projectsRoot: URL
    private let parser: TranscriptParser
    private let codexParser: CodexTranscriptParser
    private let geminiParser: GeminiTranscriptParser

    public init(
        projectsRoot: URL,
        parser: TranscriptParser = TranscriptParser(),
        codexParser: CodexTranscriptParser = CodexTranscriptParser(),
        geminiParser: GeminiTranscriptParser = GeminiTranscriptParser()
    ) {
        self.projectsRoot = projectsRoot
        self.parser = parser
        self.codexParser = codexParser
        self.geminiParser = geminiParser
    }

    /// Backwards-compatible Claude entry point. The original Plan 05
    /// signature, kept so older callers + tests don't regress. Resolves
    /// to `projectsRoot/<workspaceID>/<sessionID>.jsonl` exactly as
    /// before.
    public func transcript(
        forSessionID sessionID: SessionID,
        workspaceID: String
    ) async throws -> Transcript {
        try await transcript(
            forSessionID: sessionID,
            workspaceID: workspaceID,
            provider: .claude,
            filePath: nil
        )
    }

    /// Provider-aware overload. Routes to the correct parser given the
    /// session's `provider`:
    ///
    ///   - `.claude` (or `filePath == nil`): the Claude jsonl walker,
    ///     resolving the file at `projectsRoot/<workspaceID>/<sessionID>.jsonl`
    ///   - `.codex`: `CodexTranscriptParser` against `filePath`
    ///   - `.gemini`: `GeminiTranscriptParser` against `filePath`
    ///
    /// `filePath` is the absolute on-disk path recorded in
    /// `sessions_index.file_path` at index time. Pass `nil` for Claude
    /// sessions or when the column is unset (which is also valid
    /// because the canonical path always works for Claude).
    ///
    /// Returns an empty transcript (not an error) when the file is
    /// missing on disk, so the preview pane can still render a frame
    /// instead of bubbling a TCC / "file gone" error to the toast row.
    public func transcript(
        forSessionID sessionID: SessionID,
        workspaceID: String,
        provider: ProviderID,
        filePath: String?
    ) async throws -> Transcript {
        try Task.checkCancellation()
        switch provider {
        case .claude:
            // Claude's on-disk layout is recoverable from
            // `(workspace_id, sessionID)`. Ignore `filePath` even when
            // populated — the canonical path is authoritative for
            // Claude.
            let url = projectsRoot
                .appendingPathComponent(workspaceID, isDirectory: true)
                .appendingPathComponent("\(sessionID.description).jsonl", isDirectory: false)
            return try parser.parse(url: url, workspaceID: workspaceID)

        case .codex:
            guard let filePath, !filePath.isEmpty else {
                // Pre-v10 row, or somehow the column is blank — return an
                // empty stats block rather than throwing so the preview
                // pane just shows zeroes.
                return Transcript.empty(sessionID: sessionID, workspaceID: workspaceID)
            }
            let url = URL(fileURLWithPath: filePath)
            return try codexParser.parse(
                url: url,
                sessionID: sessionID,
                workspaceID: workspaceID
            )

        case .gemini:
            guard let filePath, !filePath.isEmpty else {
                return Transcript.empty(sessionID: sessionID, workspaceID: workspaceID)
            }
            let url = URL(fileURLWithPath: filePath)
            return try geminiParser.parse(
                url: url,
                sessionID: sessionID,
                workspaceID: workspaceID
            )
        }
    }
}
