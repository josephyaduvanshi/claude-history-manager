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
    /// Which CLI produced this session. v10 column. Defaults to `.claude`
    /// for older callers / persisted blobs that pre-date the multi-provider
    /// migration.
    public let provider: ProviderID
    /// Absolute on-disk path to the session's `.jsonl` (or rollout file).
    /// v10 column. Always populated for Codex/Gemini rows because their
    /// on-disk layout isn't reconstructible from `(workspace_id, sessionID)`.
    /// `nil` for Claude rows or rows pre-dating v10 — Claude resolves via
    /// the canonical `projectsRoot/<workspaceID>/<sessionID>.jsonl` path.
    public let filePath: String?

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
        isLive: Bool,
        provider: ProviderID = .claude,
        filePath: String? = nil
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
        self.provider = provider
        self.filePath = filePath
    }

    // Custom Codable so persisted blobs that pre-date v10 still decode
    // (older payloads won't carry `provider` / `filePath`).
    private enum CodingKeys: String, CodingKey {
        case sessionID, workspaceID, title, createdAt, lastModifiedAt
        case messageCount, tokenCount, inputTokens, outputTokens, model, isLive
        case provider, filePath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionID = try c.decode(SessionID.self, forKey: .sessionID)
        self.workspaceID = try c.decode(String.self, forKey: .workspaceID)
        self.title = try c.decode(String.self, forKey: .title)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.lastModifiedAt = try c.decode(Date.self, forKey: .lastModifiedAt)
        self.messageCount = try c.decode(Int.self, forKey: .messageCount)
        self.tokenCount = try c.decode(Int.self, forKey: .tokenCount)
        self.inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        self.outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        self.model = try c.decodeIfPresent(String.self, forKey: .model)
        self.isLive = try c.decode(Bool.self, forKey: .isLive)
        self.provider = try c.decodeIfPresent(ProviderID.self, forKey: .provider) ?? .claude
        self.filePath = try c.decodeIfPresent(String.self, forKey: .filePath)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sessionID, forKey: .sessionID)
        try c.encode(workspaceID, forKey: .workspaceID)
        try c.encode(title, forKey: .title)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(lastModifiedAt, forKey: .lastModifiedAt)
        try c.encode(messageCount, forKey: .messageCount)
        try c.encode(tokenCount, forKey: .tokenCount)
        try c.encode(inputTokens, forKey: .inputTokens)
        try c.encode(outputTokens, forKey: .outputTokens)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encode(isLive, forKey: .isLive)
        try c.encode(provider, forKey: .provider)
        try c.encodeIfPresent(filePath, forKey: .filePath)
    }
}
