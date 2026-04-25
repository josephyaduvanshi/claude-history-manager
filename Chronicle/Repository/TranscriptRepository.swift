import Foundation

/// Reads full session transcripts from jsonl on disk. Lazy; only invoked
/// when the user opens the transcript view. Lives as a separate actor
/// from `SessionsRepository` so a long transcript parse can't block
/// menubar / sidebar queries against the SQLite index.
public actor TranscriptRepository {
    private let projectsRoot: URL
    private let parser: TranscriptParser

    public init(
        projectsRoot: URL,
        parser: TranscriptParser = TranscriptParser()
    ) {
        self.projectsRoot = projectsRoot
        self.parser = parser
    }

    /// Load the transcript for a specific session. The jsonl file is at
    /// `projectsRoot/<workspaceID>/<sessionID>.jsonl`. Throws on IO errors
    /// + cancellation; returns an empty transcript for empty files.
    public func transcript(
        forSessionID sessionID: SessionID,
        workspaceID: String
    ) async throws -> Transcript {
        try Task.checkCancellation()
        let url = projectsRoot
            .appendingPathComponent(workspaceID, isDirectory: true)
            .appendingPathComponent("\(sessionID.description).jsonl", isDirectory: false)
        return try parser.parse(url: url, workspaceID: workspaceID)
    }
}
