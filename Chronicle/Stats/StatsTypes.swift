import Foundation

/// Per-workspace summary for the Stats screen's "Per-project usage" table.
///
/// Input/output token splits are best-effort: our index stores a combined
/// `token_count` only. When we can't separate them (every current session) we
/// set both halves to `0` and let the UI render a single aggregate bar.
public struct WorkspaceStats: Sendable, Equatable {
    public let workspaceID: String
    public let workspaceName: String
    public let sessionCount: Int
    public let totalTokens: Int
    public let totalInputTokens: Int
    public let totalOutputTokens: Int
    public let estimatedCostUSD: Double
    public let latestActivity: Date?

    public init(
        workspaceID: String,
        workspaceName: String,
        sessionCount: Int,
        totalTokens: Int,
        totalInputTokens: Int,
        totalOutputTokens: Int,
        estimatedCostUSD: Double,
        latestActivity: Date?
    ) {
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.sessionCount = sessionCount
        self.totalTokens = totalTokens
        self.totalInputTokens = totalInputTokens
        self.totalOutputTokens = totalOutputTokens
        self.estimatedCostUSD = estimatedCostUSD
        self.latestActivity = latestActivity
    }
}

/// One bucket in the hour/weekday heatmap (rows = weekday, cols = hour).
public struct HeatmapCell: Sendable, Equatable, Hashable {
    /// 1 = Sunday, 7 = Saturday (matches `Calendar.component(.weekday, ...)`).
    public let weekday: Int
    /// 0..23, in the user's local timezone.
    public let hour: Int
    /// Sessions whose last_modified_at falls in this bucket.
    public let count: Int
    /// Total tokens summed across every session in this bucket. Zero when
    /// no sessions or when the bucket has no token info recorded.
    public let tokens: Int
    /// Up to three workspace names (most-active first) that contributed to
    /// this bucket. Empty when the bucket has no sessions.
    public let topWorkspaces: [String]

    public init(weekday: Int, hour: Int, count: Int, tokens: Int = 0, topWorkspaces: [String] = []) {
        self.weekday = weekday
        self.hour = hour
        self.count = count
        self.tokens = tokens
        self.topWorkspaces = topWorkspaces
    }
}

/// One day in the GitHub-style calendar heatmap.
public struct CalendarHeatmapCell: Sendable, Equatable, Hashable {
    /// Start-of-day (local) for the bucket.
    public let date: Date
    public let sessionCount: Int
    public let tokenCount: Int
    /// Up to three workspace names (most-active first) that touched this day.
    /// Empty when the day has no sessions.
    public let topWorkspaces: [String]

    public init(date: Date, sessionCount: Int, tokenCount: Int, topWorkspaces: [String] = []) {
        self.date = date
        self.sessionCount = sessionCount
        self.tokenCount = tokenCount
        self.topWorkspaces = topWorkspaces
    }
}
