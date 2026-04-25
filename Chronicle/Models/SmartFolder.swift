import Foundation

/// A saved query surfaced in the sidebar's Smart Folders section.
/// Both built-in (Today / This week / Used `git push` / Errored sessions)
/// and user-authored folders live in the same table; the `isBuiltIn` flag
/// is purely cosmetic (prevents a Delete/Rename context menu for now).
public struct SmartFolder: Equatable, Sendable, Identifiable, Codable {
    public let id: Int64
    public var name: String
    public var query: SmartFolderQuery
    public var sortOrder: Int
    public var isBuiltIn: Bool

    public init(id: Int64,
                name: String,
                query: SmartFolderQuery,
                sortOrder: Int = 0,
                isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.query = query
        self.sortOrder = sortOrder
        self.isBuiltIn = isBuiltIn
    }
}

/// Persisted as JSON in `smart_folders.query_json`. Designed so that new
/// cases can be added without a migration; unknown cases decode to
/// `.custom(raw:)` and are rendered as regular saved searches.
///
/// `compound` is the rich, user-authored shape introduced in Plan 09. It
/// holds zero-or-more filters of each kind ANDed together. Older simple
/// cases (today / thisWeek / usedGitPush / erroredSessions / lastNDays /
/// search / custom) still decode and run as before; this preserves
/// every already-saved DB row in users' SQLite stores AND keeps the four
/// built-in folders on their original lightweight code paths.
public enum SmartFolderQuery: Equatable, Sendable, Codable {
    case today
    case thisWeek
    case lastNDays(Int)
    case usedGitPush
    case erroredSessions
    case search(SearchQuery)
    case custom(raw: String)
    case compound(SmartFolderCompoundQuery)

    // MARK: - Codable (manual; preserves forward-compat with unknown tags)

    private enum CodingKeys: String, CodingKey {
        case kind
        case days
        case search
        case raw
        case compound
    }

    private enum Kind: String, Codable {
        case today
        case thisWeek
        case lastNDays
        case usedGitPush
        case erroredSessions
        case search
        case custom
        case compound
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .today:
            try c.encode(Kind.today, forKey: .kind)
        case .thisWeek:
            try c.encode(Kind.thisWeek, forKey: .kind)
        case .lastNDays(let n):
            try c.encode(Kind.lastNDays, forKey: .kind)
            try c.encode(n, forKey: .days)
        case .usedGitPush:
            try c.encode(Kind.usedGitPush, forKey: .kind)
        case .erroredSessions:
            try c.encode(Kind.erroredSessions, forKey: .kind)
        case .search(let q):
            try c.encode(Kind.search, forKey: .kind)
            try c.encode(SmartFolderSearchEnvelope(from: q), forKey: .search)
        case .custom(let raw):
            try c.encode(Kind.custom, forKey: .kind)
            try c.encode(raw, forKey: .raw)
        case .compound(let cq):
            try c.encode(Kind.compound, forKey: .kind)
            try c.encode(cq, forKey: .compound)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind: Kind
        do {
            kind = try c.decode(Kind.self, forKey: .kind)
        } catch {
            // Unknown kind → treat as a raw custom query so we don't crash
            // the sidebar on a forward-version DB row.
            self = .custom(raw: "")
            return
        }
        switch kind {
        case .today:             self = .today
        case .thisWeek:          self = .thisWeek
        case .lastNDays:         self = .lastNDays((try? c.decode(Int.self, forKey: .days)) ?? 7)
        case .usedGitPush:       self = .usedGitPush
        case .erroredSessions:   self = .erroredSessions
        case .search:
            if let env = try? c.decode(SmartFolderSearchEnvelope.self, forKey: .search) {
                self = .search(env.toSearchQuery())
            } else {
                self = .custom(raw: "")
            }
        case .custom:
            self = .custom(raw: (try? c.decode(String.self, forKey: .raw)) ?? "")
        case .compound:
            if let cq = try? c.decode(SmartFolderCompoundQuery.self, forKey: .compound) {
                self = .compound(cq)
            } else {
                self = .compound(SmartFolderCompoundQuery())
            }
        }
    }
}

/// Rich user-authored smart-folder query. Every field is optional and an
/// empty array means "no constraint", the SQL builder ANDs together only
/// the constraints that are actually populated. A blank
/// `SmartFolderCompoundQuery()` matches every non-deleted, non-archived
/// session (i.e. it acts like "All sessions"); the UI prevents that case
/// from being saved by requiring at least one filter to be active.
///
/// All fields are stored verbatim; no normalization at decode time so
/// that old DB rows decode losslessly when re-saved.
public struct SmartFolderCompoundQuery: Equatable, Sendable, Codable {
    /// Restricts results to a single workspace by `Workspace.id` (the
    /// dash-encoded folder name under `~/.claude/projects/`). `nil` means
    /// "any workspace".
    public var workspaceID: String?

    /// Sessions must carry EVERY tag in this list. Empty = no constraint.
    /// IDs come from the `tags.id` table (Plan 06 user tags).
    public var tagIDs: [Int64]

    /// Inclusive lower bound on `sessions_index.token_count`.
    public var minTokens: Int?

    /// Inclusive upper bound on `sessions_index.token_count`.
    public var maxTokens: Int?

    /// "Modified within the last N days", translates to a
    /// `last_modified_at >= now - N*86400` clause. `nil` = no constraint.
    public var sinceDays: Int?

    /// Sessions must carry EVERY flag listed (e.g. `"git_push"`,
    /// `"errored"`). Empty = no constraint.
    public var flags: [String]

    /// Optional FTS-or-LIKE text. When non-blank we run the same
    /// title-LIKE OR transcript-FTS search the main search bar uses.
    public var searchText: String?

    public init(workspaceID: String? = nil,
                tagIDs: [Int64] = [],
                minTokens: Int? = nil,
                maxTokens: Int? = nil,
                sinceDays: Int? = nil,
                flags: [String] = [],
                searchText: String? = nil) {
        self.workspaceID = workspaceID
        self.tagIDs = tagIDs
        self.minTokens = minTokens
        self.maxTokens = maxTokens
        self.sinceDays = sinceDays
        self.flags = flags
        self.searchText = searchText
    }

    /// True when every field is empty/nil. The "Save" button uses this to
    /// gate creation; saving a blank compound query would silently match
    /// every session, which the user almost never wants.
    public var isEmpty: Bool {
        workspaceID == nil
            && tagIDs.isEmpty
            && minTokens == nil
            && maxTokens == nil
            && sinceDays == nil
            && flags.isEmpty
            && (searchText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}

/// Codable envelope for embedding a `SearchQuery` inside a smart folder. The
/// production `SearchQuery` isn't Codable (`TimeWindow` cases include
/// associated values), so we mirror its shape here.
private struct SmartFolderSearchEnvelope: Codable {
    var fullText: String
    var titleText: String
    var tags: [String]
    var workspaces: [String]
    var timeWindow: TimeWindowEnvelope?
    var limit: Int

    struct TimeWindowEnvelope: Codable {
        var kind: String
        var days: Int?

        init(from window: SearchQuery.TimeWindow) {
            switch window {
            case .today:                self = .init(kind: "today", days: nil)
            case .thisWeek:             self = .init(kind: "thisWeek", days: nil)
            case .last30Days:           self = .init(kind: "last30Days", days: nil)
            case .relative(let d):      self = .init(kind: "relative", days: d)
            }
        }

        init(kind: String, days: Int?) {
            self.kind = kind
            self.days = days
        }

        func toTimeWindow() -> SearchQuery.TimeWindow? {
            switch kind {
            case "today":         return .today
            case "thisWeek":      return .thisWeek
            case "last30Days":    return .last30Days
            case "relative":      return .relative(days: days ?? 7)
            default:              return nil
            }
        }
    }

    init(from q: SearchQuery) {
        self.fullText   = q.fullText
        self.titleText  = q.titleText
        self.tags       = q.tags
        self.workspaces = q.workspaces
        self.timeWindow = q.timeWindow.map(TimeWindowEnvelope.init(from:))
        self.limit      = q.limit
    }

    func toSearchQuery() -> SearchQuery {
        var q = SearchQuery()
        q.fullText   = fullText
        q.titleText  = titleText
        q.tags       = tags
        q.workspaces = workspaces
        q.timeWindow = timeWindow?.toTimeWindow()
        q.limit      = limit
        return q
    }
}

// MARK: - Built-ins

public extension SmartFolder {
    /// Descriptor for one of the four always-present smart folders. `id` is
    /// assigned at INSERT time so built-ins can share the same table as
    /// user-authored folders.
    struct BuiltIn: Sendable, Equatable {
        public let name: String
        public let query: SmartFolderQuery
        public let sortOrder: Int

        public init(name: String, query: SmartFolderQuery, sortOrder: Int) {
            self.name = name
            self.query = query
            self.sortOrder = sortOrder
        }
    }

    /// The four smart folders seeded on first launch. Order matters; the
    /// sidebar renders them in `sortOrder` ascending.
    static let builtIns: [BuiltIn] = [
        BuiltIn(name: "Today",             query: .today,            sortOrder: 0),
        BuiltIn(name: "This week",         query: .thisWeek,         sortOrder: 1),
        BuiltIn(name: "Used `git push`",   query: .usedGitPush,      sortOrder: 2),
        BuiltIn(name: "Errored sessions",  query: .erroredSessions,  sortOrder: 3),
    ]
}
