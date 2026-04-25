import Foundation
import GRDB

// MARK: - Plan 08 — Stats queries

extension SessionsRepository {

    /// Per-workspace summary used by the Stats screen's "Per-project usage"
    /// table. Excludes soft-deleted rows; archived rows are included because
    /// the user cares about lifetime usage, not what's currently visible in
    /// the workspace pane. Ordered by `totalTokens` descending.
    public func statsByWorkspace() async throws -> [WorkspaceStats] {
        let providerKey = activeProvider().rawValue
        return try await databaseForTests.read { [providerKey] db in
            // Pull per-session rows so we can: (1) bucket by workspace, (2)
            // attribute cost using the correct model pricing for each row.
            // Per-session is the correct granularity; averaging an entire
            // workspace under "blended sonnet" hides Opus turn cost.
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.workspace_id AS workspace_id,
                       s.token_count AS token_count,
                       s.total_input_tokens AS input_tokens,
                       s.total_output_tokens AS output_tokens,
                       s.model AS model,
                       s.last_modified_at AS last_modified_at
                FROM sessions_index s
                LEFT JOIN user_metadata u ON u.session_id = s.session_id AND u.provider = s.provider
                WHERE s.provider = ?
                  AND COALESCE(u.is_deleted, 0) = 0
                """, arguments: [providerKey])

            // Workspace name lookup, scoped to active provider so a
            // hash-named Codex workspace doesn't spuriously show up in
            // the Claude stats table.
            let nameRows = try Row.fetchAll(db, sql: """
                SELECT id, COALESCE(display_name, id) AS name FROM workspaces
                WHERE provider = ?
                """, arguments: [providerKey])
            var nameByID: [String: String] = [:]
            for r in nameRows { nameByID[r["id"]] = r["name"] }

            struct Acc {
                var sessionCount: Int = 0
                var totalTokens: Int = 0
                var input: Int = 0
                var output: Int = 0
                var cost: Double = 0
                var latest: Date? = nil
            }
            var acc: [String: Acc] = [:]
            for row in rows {
                let wsID: String = row["workspace_id"]
                let token: Int = (row["token_count"] as Int?) ?? 0
                let i: Int = (row["input_tokens"] as Int?) ?? 0
                let o: Int = (row["output_tokens"] as Int?) ?? 0
                let model: String? = row["model"]
                let last: Date? = row["last_modified_at"]
                let resolvedI = i > 0 ? i : token / 2
                let resolvedO = o > 0 ? o : (token - token / 2)
                let cost = ModelPricing.cost(
                    inputTokens: resolvedI, outputTokens: resolvedO, model: model
                )
                acc[wsID, default: Acc()].sessionCount += 1
                acc[wsID]!.totalTokens += token
                acc[wsID]!.input += resolvedI
                acc[wsID]!.output += resolvedO
                acc[wsID]!.cost += cost
                if let last {
                    if let prev = acc[wsID]!.latest {
                        if last > prev { acc[wsID]!.latest = last }
                    } else {
                        acc[wsID]!.latest = last
                    }
                }
            }

            // Include workspaces with zero sessions so the table doesn't
            // silently drop empty projects (still alphabetised at the bottom).
            for (wsID, _) in nameByID where acc[wsID] == nil {
                acc[wsID] = Acc()
            }

            return acc.map { (wsID, a) -> WorkspaceStats in
                WorkspaceStats(
                    workspaceID: wsID,
                    workspaceName: nameByID[wsID] ?? wsID,
                    sessionCount: a.sessionCount,
                    totalTokens: a.totalTokens,
                    totalInputTokens: a.input,
                    totalOutputTokens: a.output,
                    estimatedCostUSD: a.cost,
                    latestActivity: a.latest
                )
            }
            .sorted { lhs, rhs in
                if lhs.totalTokens != rhs.totalTokens {
                    return lhs.totalTokens > rhs.totalTokens
                }
                return lhs.workspaceName < rhs.workspaceName
            }
        }
    }

    /// Aggregate token + cost totals broken down per model (e.g.
    /// `[("claude-opus-4-7-...", tokens, cost), ...]`). Used in the Stats
    /// header beside the global blended cost. Sessions with no model column
    /// (legacy rows) are bucketed under "(unspecified)".
    public func statsByModel() async throws -> [(model: String, tokens: Int, cost: Double)] {
        let providerKey = activeProvider().rawValue
        return try await databaseForTests.read { [providerKey] db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT COALESCE(s.model, '(unspecified)') AS model,
                       COALESCE(SUM(s.token_count), 0) AS tokens,
                       COALESCE(SUM(s.total_input_tokens), 0) AS input_tokens,
                       COALESCE(SUM(s.total_output_tokens), 0) AS output_tokens
                FROM sessions_index s
                LEFT JOIN user_metadata u ON u.session_id = s.session_id AND u.provider = s.provider
                WHERE s.provider = ?
                  AND COALESCE(u.is_deleted, 0) = 0
                GROUP BY COALESCE(s.model, '(unspecified)')
                ORDER BY tokens DESC
                """, arguments: [providerKey])
            return rows.map { row in
                let token: Int = (row["tokens"] as Int?) ?? 0
                let i: Int = (row["input_tokens"] as Int?) ?? 0
                let o: Int = (row["output_tokens"] as Int?) ?? 0
                let resolvedI = i > 0 ? i : token / 2
                let resolvedO = o > 0 ? o : (token - token / 2)
                let modelRaw: String = row["model"]
                let modelKey: String? = (modelRaw == "(unspecified)") ? nil : modelRaw
                let cost = ModelPricing.cost(
                    inputTokens: resolvedI, outputTokens: resolvedO, model: modelKey
                )
                return (model: modelRaw, tokens: token, cost: cost)
            }
        }
    }

    /// Totals across every (non-deleted) session. Used by the Stats header
    /// trio (Sessions · Tokens · Estimated Cost). Cost is computed
    /// per-session using the recorded model, then summed; so a workspace
    /// with one Opus session no longer gets averaged out into Sonnet pricing.
    public func totalStats() async throws -> (sessions: Int, tokens: Int, estimatedCostUSD: Double) {
        let providerKey = activeProvider().rawValue
        return try await databaseForTests.read { [providerKey] db in
            // Count + token total in one query.
            let aggRow = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS n,
                       COALESCE(SUM(s.token_count), 0) AS total
                FROM sessions_index s
                LEFT JOIN user_metadata u ON u.session_id = s.session_id AND u.provider = s.provider
                WHERE s.provider = ?
                  AND COALESCE(u.is_deleted, 0) = 0
                """, arguments: [providerKey])
            let n = (aggRow?["n"] as Int?) ?? 0
            let total = (aggRow?["total"] as Int?) ?? 0

            // Per-row cost calc; accurate when model is known.
            let costRows = try Row.fetchAll(db, sql: """
                SELECT s.token_count AS token_count,
                       s.total_input_tokens AS input_tokens,
                       s.total_output_tokens AS output_tokens,
                       s.model AS model
                FROM sessions_index s
                LEFT JOIN user_metadata u ON u.session_id = s.session_id AND u.provider = s.provider
                WHERE s.provider = ?
                  AND COALESCE(u.is_deleted, 0) = 0
                """, arguments: [providerKey])
            var cost: Double = 0
            for row in costRows {
                let token: Int = (row["token_count"] as Int?) ?? 0
                let i: Int = (row["input_tokens"] as Int?) ?? 0
                let o: Int = (row["output_tokens"] as Int?) ?? 0
                let model: String? = row["model"]
                let resolvedI = i > 0 ? i : token / 2
                let resolvedO = o > 0 ? o : (token - token / 2)
                cost += ModelPricing.cost(
                    inputTokens: resolvedI, outputTokens: resolvedO, model: model
                )
            }
            return (sessions: n, tokens: total, estimatedCostUSD: cost)
        }
    }

    /// 24×7 buckets of "sessions touched" by (weekday, hour) in the user's
    /// local timezone. Restricted to the last `days` days; defaults to 90.
    /// Excludes deleted sessions. Each cell is enriched with the bucket's
    /// total token count and (up to) the three most-active workspace names
    /// so the Stats view can show a rich hover popover.
    public func hourWeekdayHeatmap(days: Int = 90) async throws -> [HeatmapCell] {
        let cutoff = Date().addingTimeInterval(-Double(max(1, days)) * 24 * 3600)
        // Pull (date, tokens, workspace) per session; the view needs all
        // three per bucket. Workspace names are joined here so the bucketer
        // can rank by per-bucket token contribution.
        struct Raw { let date: Date; let tokens: Int; let workspace: String }
        let providerKey = activeProvider().rawValue
        let raw: [Raw] = try await databaseForTests.read { [providerKey] db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.last_modified_at AS d,
                       COALESCE(s.token_count, 0) AS t,
                       COALESCE(w.display_name, w.id, s.workspace_id, '(unknown)') AS ws
                FROM sessions_index s
                LEFT JOIN user_metadata u ON u.session_id = s.session_id AND u.provider = s.provider
                LEFT JOIN workspaces w ON w.id = s.workspace_id AND w.provider = s.provider
                WHERE s.provider = ?
                  AND s.last_modified_at >= ?
                  AND COALESCE(u.is_deleted, 0) = 0
                """, arguments: [providerKey, cutoff])
            return rows.map { Raw(date: $0["d"],
                                  tokens: ($0["t"] as Int?) ?? 0,
                                  workspace: $0["ws"] ?? "(unknown)") }
        }

        let cal = Calendar.current
        // Bucket key = weekday * 100 + hour. Track count, tokens and a
        // workspace -> tokens map so we can pick top 3 per bucket below.
        struct Bucket {
            var count: Int = 0
            var tokens: Int = 0
            var perWorkspace: [String: Int] = [:]
        }
        var buckets: [Int: Bucket] = [:]
        for r in raw {
            let comps = cal.dateComponents([.weekday, .hour], from: r.date)
            let w = comps.weekday ?? 1
            let h = comps.hour ?? 0
            let key = w * 100 + h
            var b = buckets[key] ?? Bucket()
            b.count += 1
            b.tokens += r.tokens
            // Rank by tokens primarily; sessions with zero tokens still count
            // as 1 so silent-but-active workspaces don't disappear entirely.
            b.perWorkspace[r.workspace, default: 0] += max(r.tokens, 1)
            buckets[key] = b
        }

        // Emit every (weekday, hour) pair so the view doesn't have to fill
        // gaps itself. Ordered (weekday ASC, hour ASC).
        var cells: [HeatmapCell] = []
        cells.reserveCapacity(24 * 7)
        for w in 1...7 {
            for h in 0...23 {
                let key = w * 100 + h
                if let b = buckets[key] {
                    let top = b.perWorkspace
                        .sorted { lhs, rhs in
                            if lhs.value != rhs.value { return lhs.value > rhs.value }
                            return lhs.key < rhs.key
                        }
                        .prefix(3)
                        .map(\.key)
                    cells.append(HeatmapCell(
                        weekday: w, hour: h,
                        count: b.count, tokens: b.tokens, topWorkspaces: Array(top)
                    ))
                } else {
                    cells.append(HeatmapCell(weekday: w, hour: h, count: 0))
                }
            }
        }
        return cells
    }

    /// One cell per day for the last `days` days (default 90). Days with no
    /// activity appear with zero counts so the caller can render a full grid.
    /// Each non-empty cell carries up to three top-workspace names ranked by
    /// per-day token contribution so the view can render a hover popover.
    public func calendarHeatmap(days: Int = 90) async throws -> [CalendarHeatmapCell] {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let cutoff = cal.date(byAdding: .day, value: -(max(1, days) - 1), to: todayStart) ?? todayStart

        // Pull every (last_modified_at, token_count, workspace) row in the
        // window. Workspace name comes through the workspaces join so we
        // don't need a second lookup pass in Swift.
        struct Raw { let date: Date; let tokens: Int; let workspace: String }
        let providerKey = activeProvider().rawValue
        let raw: [Raw] = try await databaseForTests.read { [providerKey] db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.last_modified_at AS d,
                       COALESCE(s.token_count, 0) AS t,
                       COALESCE(w.display_name, w.id, s.workspace_id, '(unknown)') AS ws
                FROM sessions_index s
                LEFT JOIN user_metadata u ON u.session_id = s.session_id AND u.provider = s.provider
                LEFT JOIN workspaces w ON w.id = s.workspace_id AND w.provider = s.provider
                WHERE s.provider = ?
                  AND s.last_modified_at >= ?
                  AND COALESCE(u.is_deleted, 0) = 0
                """, arguments: [providerKey, cutoff])
            return rows.map { Raw(date: $0["d"],
                                  tokens: ($0["t"] as Int?) ?? 0,
                                  workspace: $0["ws"] ?? "(unknown)") }
        }

        var counts: [Date: Int] = [:]
        var tokens: [Date: Int] = [:]
        var perWorkspace: [Date: [String: Int]] = [:]
        for r in raw {
            let start = cal.startOfDay(for: r.date)
            counts[start, default: 0] += 1
            tokens[start, default: 0] += r.tokens
            // Same ranking trick as the hour grid: sessions with no token
            // info still count as a single-unit contribution.
            perWorkspace[start, default: [:]][r.workspace, default: 0] += max(r.tokens, 1)
        }

        var out: [CalendarHeatmapCell] = []
        out.reserveCapacity(days)
        for offset in 0..<max(1, days) {
            guard let day = cal.date(byAdding: .day, value: -offset, to: todayStart) else { continue }
            let start = cal.startOfDay(for: day)
            let topWS: [String]
            if let ws = perWorkspace[start] {
                topWS = ws.sorted { lhs, rhs in
                    if lhs.value != rhs.value { return lhs.value > rhs.value }
                    return lhs.key < rhs.key
                }
                .prefix(3)
                .map(\.key)
            } else {
                topWS = []
            }
            out.append(CalendarHeatmapCell(
                date: start,
                sessionCount: counts[start] ?? 0,
                tokenCount: tokens[start] ?? 0,
                topWorkspaces: topWS
            ))
        }
        // Return oldest -> newest so the UI can render columns left-to-right.
        return out.reversed()
    }
}
