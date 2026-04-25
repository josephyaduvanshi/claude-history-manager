import Foundation

/// Metadata extracted from a session's `.jsonl` file. Stored in the SQLite index.
public struct SessionMetadata: Hashable, Equatable, Codable, Sendable, Identifiable {
    public let sessionID: SessionID
    public let workspaceID: String          // FK to Workspace.id
    public let title: String                // first user message, truncated
    public let createdAt: Date
    public let lastModifiedAt: Date
    public let messageCount: Int
    public let tokenCount: Int
    /// Sum of `input_tokens` across assistant turns. v7 column.
    public let inputTokens: Int
    /// Sum of `output_tokens` across assistant turns. v7 column.
    public let outputTokens: Int
    /// Most-recent model string (e.g. `"claude-opus-4-7-20250101"`). v7 column.
    public let model: String?
    public let isLive: Bool                 // computed at runtime; persisted as snapshot

    public var id: SessionID { sessionID }

    public init(
        sessionID: SessionID,
        workspaceID: String,
        title: String,
        createdAt: Date,
        lastModifiedAt: Date,
        messageCount: Int,
        tokenCount: Int,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        model: String? = nil,
        isLive: Bool
    ) {
        self.sessionID = sessionID
        self.workspaceID = workspaceID
        self.title = title
        self.createdAt = createdAt
        self.lastModifiedAt = lastModifiedAt
        self.messageCount = messageCount
        self.tokenCount = tokenCount
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.model = model
        self.isLive = isLive
    }
}
