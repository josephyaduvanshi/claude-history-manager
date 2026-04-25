import SwiftUI

/// Stats dashboard: totals row · per-project table · hour/weekday heatmap ·
/// 90-day calendar heatmap. Reachable via the titlebar tab switch (⌘2) or
/// the menubar. Keeps the editorial look of the Plan 01.5 shell; no
/// gradients, no fake glow, quiet rules, coral only as an accent.
struct StatsView: View {
    @Environment(AppState.self) private var state
    /// Action fired when the user clicks a calendar cell. Takes the date
    /// start (local) so the caller can filter the session list to that day.
    var onOpenDay: ((Date) -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                TotalsRow(totals: state.totals, loading: state.statsLoading)
                if !state.modelBreakdown.isEmpty {
                    ModelBreakdownRow(breakdown: state.modelBreakdown)
                }
                WorkspaceTable(rows: state.workspaceStats)
                HourWeekdayHeatmapSection(cells: state.hourWeekdayHeatmap)
                CalendarHeatmapSection(cells: state.calendarHeatmap, onOpenDay: onOpenDay)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.Color.bg)
    }
}

// MARK: - Per-model breakdown row

private struct ModelBreakdownRow: View {
    let breakdown: [AppState.ModelBreakdown]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cost by model")
                .font(Theme.Font.display(size: 16, wdth: 100, wght: 600, opsz: 24))
                .foregroundStyle(Theme.Color.text)
                .kerning(-0.25)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(breakdown, id: \.model) { row in
                    HStack(spacing: 12) {
                        Circle()
                            .fill(Theme.Color.accent.opacity(0.6))
                            .frame(width: 6, height: 6)
                        Text(prettyModel(row.model))
                            .font(Theme.Font.mono(size: 11.5, wght: 500))
                            .foregroundStyle(Theme.Color.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 280, alignment: .leading)
                        Text(NumFmt.compactInt(row.tokens))
                            .font(Theme.Font.mono(size: 11.5, wght: 500))
                            .foregroundStyle(Theme.Color.textMuted)
                            .frame(width: 100, alignment: .trailing)
                        Text("tokens")
                            .font(Theme.Font.mono(size: 10, wght: 400))
                            .foregroundStyle(Theme.Color.textFaint)
                        Spacer()
                        Text(NumFmt.dollar(row.cost))
                            .font(Theme.Font.mono(size: 11.5, wght: 600))
                            .foregroundStyle(Theme.Color.text)
                            .frame(width: 100, alignment: .trailing)
                    }
                    .padding(.vertical, 4)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Theme.Color.rule).frame(height: 1)
                    }
                }
            }
        }
    }

    /// Trim known-noisy suffixes off model strings; eg
    /// `claude-opus-4-7-20251201` → `claude-opus-4-7`. Pure-cosmetic.
    private func prettyModel(_ raw: String) -> String {
        var s = raw
        // Strip trailing `-YYYYMMDD` if present.
        if let r = s.range(of: #"-\d{8}$"#, options: .regularExpression) {
            s.removeSubrange(r)
        }
        return s
    }
}

// MARK: - Totals row

private struct TotalsRow: View {
    let totals: (sessions: Int, tokens: Int, estimatedCostUSD: Double)
    let loading: Bool

    var body: some View {
        HStack(spacing: 0) {
            TotalsCard(
                title: "Sessions",
                value: NumFmt.int(totals.sessions),
                subtitle: "indexed"
            )
            divider
            TotalsCard(
                title: "Tokens",
                value: NumFmt.compactInt(totals.tokens),
                subtitle: NumFmt.int(totals.tokens)
            )
            divider
            TotalsCard(
                title: "Estimated Cost",
                value: NumFmt.dollar(totals.estimatedCostUSD),
                subtitle: "USD · sonnet-blend"
            )
        }
        .padding(.vertical, 18)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.Color.rule).frame(height: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Color.rule).frame(height: 1)
        }
        .opacity(loading ? 0.4 : 1)
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.Color.rule)
            .frame(width: 1)
            .padding(.vertical, 6)
    }
}

private struct TotalsCard: View {
    let title: String
    let value: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(Theme.Font.sbLabel)
                .foregroundStyle(Theme.Color.textFaint)
                .kerning(1.6)
            Text(value)
                .font(Theme.Font.display(size: 32, wdth: 100, wght: 600, opsz: 36))
                .foregroundStyle(Theme.Color.text)
                .kerning(-0.8)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(subtitle)
                .font(Theme.Font.mono(size: 10.5, wght: 400))
                .foregroundStyle(Theme.Color.textDim)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Per-workspace usage table

private struct WorkspaceTable: View {
    let rows: [WorkspaceStats]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Per-project usage")
            if rows.isEmpty {
                emptyState
            } else {
                tableHeader
                ForEach(rows, id: \.workspaceID) { row in
                    WorkspaceRow(row: row, maxTokens: maxTokens)
                    Rectangle().fill(Theme.Color.rule).frame(height: 1)
                }
            }
        }
    }

    private var maxTokens: Int {
        rows.map(\.totalTokens).max() ?? 0
    }

    private var tableHeader: some View {
        HStack(spacing: 0) {
            col("Project",  width: nil, align: .leading)
            col("Sessions", width: 90,  align: .trailing)
            col("Tokens",   width: 120, align: .trailing)
            col("Split",    width: 160, align: .leading)
            col("Cost USD", width: 100, align: .trailing)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Color.ruleStrong).frame(height: 1)
        }
    }

    private func col(_ label: String, width: CGFloat?, align: Alignment) -> some View {
        let hAlign: HorizontalAlignment = {
            switch align {
            case .leading: return .leading
            case .trailing: return .trailing
            default: return .leading
            }
        }()
        return HStack {
            if align == .trailing { Spacer(minLength: 0) }
            Text(label.uppercased())
                .font(Theme.Font.sbLabel)
                .foregroundStyle(Theme.Color.textFaint)
                .kerning(1.4)
            if align == .leading { Spacer(minLength: 0) }
        }
        .frame(width: width, alignment: align)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: align)
        .multilineTextAlignment(hAlign == .leading ? .leading : .trailing)
    }

    private var emptyState: some View {
        Text("No workspace activity indexed yet.")
            .font(Theme.Font.bodyBase)
            .foregroundStyle(Theme.Color.textMuted)
            .padding(.vertical, 10)
    }

    private func sectionHeader(_ label: String) -> some View {
        Text(label)
            .font(Theme.Font.display(size: 16, wdth: 100, wght: 600, opsz: 24))
            .foregroundStyle(Theme.Color.text)
            .kerning(-0.25)
    }
}

private struct WorkspaceRow: View {
    let row: WorkspaceStats
    let maxTokens: Int

    var body: some View {
        HStack(spacing: 0) {
            // Project
            VStack(alignment: .leading, spacing: 2) {
                Text(row.workspaceName)
                    .font(Theme.Font.sessionTitle)
                    .foregroundStyle(Theme.Color.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let last = row.latestActivity {
                    Text("last active " + RelativeTime.shortAgo(from: last))
                        .font(Theme.Font.mono(size: 10, wght: 400))
                        .foregroundStyle(Theme.Color.textDim)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Sessions
            Text(NumFmt.int(row.sessionCount))
                .font(Theme.Font.mono(size: 12, wght: 500))
                .foregroundStyle(Theme.Color.text)
                .frame(width: 90, alignment: .trailing)

            // Tokens
            Text(NumFmt.compactInt(row.totalTokens))
                .font(Theme.Font.mono(size: 12, wght: 500))
                .foregroundStyle(Theme.Color.text)
                .frame(width: 120, alignment: .trailing)

            // Split (percentage bar of this row's tokens vs the largest row)
            SplitBar(tokens: row.totalTokens, maxTokens: maxTokens)
                .frame(width: 160, alignment: .leading)

            // Cost
            Text(NumFmt.dollar(row.estimatedCostUSD))
                .font(Theme.Font.mono(size: 12, wght: 500))
                .foregroundStyle(Theme.Color.text)
                .frame(width: 100, alignment: .trailing)
        }
        .padding(.vertical, 10)
    }
}

private struct SplitBar: View {
    let tokens: Int
    let maxTokens: Int

    var body: some View {
        GeometryReader { geo in
            let pct = maxTokens > 0 ? Double(tokens) / Double(maxTokens) : 0
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Theme.Color.rule)
                    .frame(height: 4)
                Rectangle()
                    .fill(Theme.Color.accent)
                    .frame(width: max(1, geo.size.width * pct), height: 4)
            }
            .clipShape(RoundedRectangle(cornerRadius: 1))
        }
        .frame(height: 4)
        .padding(.trailing, 12)
    }
}

// MARK: - Hour/Weekday heatmap

private struct HourWeekdayHeatmapSection: View {
    let cells: [HeatmapCell]
    /// Per-section hover tracker; single `@State` instead of one bool per
    /// tile (24 × 7 = 168 cells). The string key is `"weekday-hour"`.
    @State private var hoveredCellID: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionHeader("Most-active hours")
                Spacer()
                Text("last 90 days · local timezone")
                    .font(Theme.Font.mono(size: 10.5, wght: 400))
                    .foregroundStyle(Theme.Color.textDim)
            }
            heatmapGrid
        }
    }

    private var heatmapGrid: some View {
        let maxCount = max(1, cells.map(\.count).max() ?? 1)
        // Lookup keyed for O(1) per-tile reads; avoids the linear `first(where:)`
        // call that otherwise runs 168 times on every redraw.
        let lookup: [String: HeatmapCell] = Dictionary(
            uniqueKeysWithValues: cells.map { ("\($0.weekday)-\($0.hour)", $0) }
        )
        return VStack(alignment: .leading, spacing: 3) {
            // Hour column ruler (every 3 hours)
            HStack(spacing: 3) {
                // Leading gutter matching weekday label width.
                Text("")
                    .frame(width: 32)
                ForEach(0..<24, id: \.self) { h in
                    Text(h % 3 == 0 ? "\(h)" : "")
                        .font(Theme.Font.mono(size: 9, wght: 400))
                        .foregroundStyle(Theme.Color.textFaint)
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(1...7, id: \.self) { weekday in
                HStack(spacing: 3) {
                    Text(Self.weekdayLabel(weekday))
                        .font(Theme.Font.mono(size: 10, wght: 500))
                        .foregroundStyle(Theme.Color.textDim)
                        .frame(width: 32, alignment: .leading)
                    ForEach(0..<24, id: \.self) { hour in
                        let key = "\(weekday)-\(hour)"
                        let cell = lookup[key]
                            ?? HeatmapCell(weekday: weekday, hour: hour, count: 0)
                        HeatCell(
                            cell: cell,
                            maxCount: maxCount,
                            weekdayLabel: Self.weekdayLabel(weekday),
                            isHovered: hoveredCellID == key,
                            onHoverChanged: { hovering in
                                hoveredCellID = hovering ? key : (hoveredCellID == key ? nil : hoveredCellID)
                            }
                        )
                    }
                }
            }
        }
    }

    static func weekdayLabel(_ w: Int) -> String {
        // 1=Sun (matches Calendar.component(.weekday))
        switch w {
        case 1: return "Sun"
        case 2: return "Mon"
        case 3: return "Tue"
        case 4: return "Wed"
        case 5: return "Thu"
        case 6: return "Fri"
        default: return "Sat"
        }
    }

    private func sectionHeader(_ label: String) -> some View {
        Text(label)
            .font(Theme.Font.display(size: 16, wdth: 100, wght: 600, opsz: 24))
            .foregroundStyle(Theme.Color.text)
            .kerning(-0.25)
    }
}

private struct HeatCell: View {
    let cell: HeatmapCell
    let maxCount: Int
    let weekdayLabel: String
    let isHovered: Bool
    let onHoverChanged: (Bool) -> Void

    var body: some View {
        let intensity = maxCount > 0 ? Double(cell.count) / Double(maxCount) : 0
        let alpha = cell.count == 0 ? 0.0 : (0.12 + 0.88 * intensity)
        return RoundedRectangle(cornerRadius: 2)
            .fill(Theme.Color.accent.opacity(alpha))
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(borderColor, lineWidth: cell.count == 0 ? 1 : (isHovered ? 1 : 0))
            )
            .frame(maxWidth: .infinity)
            .frame(height: 16)
            .contentShape(Rectangle())
            .onHover(perform: onHoverChanged)
            .help(helpText)
            .popover(isPresented: .constant(isHovered && cell.count > 0), arrowEdge: .top) {
                HourBucketPopover(cell: cell, weekdayLabel: weekdayLabel)
            }
    }

    private var borderColor: Color {
        if cell.count == 0 { return Theme.Color.rule }
        return isHovered ? Theme.Color.accentEdge : .clear
    }

    private var helpText: String {
        let hourStr = String(format: "%02d:00", cell.hour)
        let next = String(format: "%02d:00", (cell.hour + 1) % 24)
        return "\(weekdayLabel) \(hourStr)–\(next) — \(cell.count) session\(cell.count == 1 ? "" : "s")"
    }
}

/// Compact hover popover for an hour×weekday bucket. Shows hour range,
/// session count, total tokens and (when available) the most-active
/// workspaces that touched the bucket.
private struct HourBucketPopover: View {
    let cell: HeatmapCell
    let weekdayLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(headline.uppercased())
                .font(Theme.Font.sbLabel)
                .foregroundStyle(Theme.Color.textFaint)
                .kerning(1.4)
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                statColumn(
                    label: "Sessions",
                    value: NumFmt.int(cell.count)
                )
                statColumn(
                    label: "Tokens",
                    value: NumFmt.compactInt(cell.tokens)
                )
            }
            if !cell.topWorkspaces.isEmpty {
                Rectangle().fill(Theme.Color.rule).frame(height: 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text("TOP PROJECTS")
                        .font(Theme.Font.sbLabel)
                        .foregroundStyle(Theme.Color.textFaint)
                        .kerning(1.4)
                    ForEach(cell.topWorkspaces, id: \.self) { name in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Theme.Color.accent.opacity(0.6))
                                .frame(width: 4, height: 4)
                            Text(name)
                                .font(Theme.Font.mono(size: 11, wght: 500))
                                .foregroundStyle(Theme.Color.text)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: 240, alignment: .leading)
        .background(Theme.Color.bgElev2)
    }

    private var headline: String {
        let hourStr = String(format: "%02d:00", cell.hour)
        let next = String(format: "%02d:00", (cell.hour + 1) % 24)
        return "\(hourStr)–\(next)  ·  \(weekdayLabel)"
    }

    @ViewBuilder
    private func statColumn(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(Theme.Font.sbLabel)
                .foregroundStyle(Theme.Color.textFaint)
                .kerning(1.4)
            Text(value)
                .font(Theme.Font.mono(size: 13, wght: 600))
                .foregroundStyle(Theme.Color.text)
        }
    }
}

// MARK: - Calendar heatmap (GitHub-style columns of 7)

private struct CalendarHeatmapSection: View {
    let cells: [CalendarHeatmapCell]
    var onOpenDay: ((Date) -> Void)? = nil
    /// Per-section hover tracker; single state, key = ISO date string.
    @State private var hoveredCellID: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionHeader("Activity calendar")
                Spacer()
                Text("\(cells.count) days")
                    .font(Theme.Font.mono(size: 10.5, wght: 400))
                    .foregroundStyle(Theme.Color.textDim)
            }
            calendarGrid
        }
    }

    private var calendarGrid: some View {
        let maxCount = max(1, cells.map(\.sessionCount).max() ?? 1)
        // Pad the first column so the grid aligns to the starting weekday.
        let firstWeekday: Int = {
            guard let first = cells.first?.date else { return 1 }
            return Calendar.current.component(.weekday, from: first)
        }()
        let padding = firstWeekday - 1
        let totalSlots = padding + cells.count
        let columnCount = Int(ceil(Double(totalSlots) / 7.0))

        return HStack(alignment: .top, spacing: 3) {
            VStack(alignment: .trailing, spacing: 3) {
                ForEach(0..<7, id: \.self) { w in
                    Text(dayHint(w))
                        .font(Theme.Font.mono(size: 9, wght: 400))
                        .foregroundStyle(Theme.Color.textFaint)
                        .frame(height: 12)
                }
            }
            .padding(.trailing, 4)

            ForEach(0..<columnCount, id: \.self) { col in
                VStack(spacing: 3) {
                    ForEach(0..<7, id: \.self) { row in
                        let slot = col * 7 + row
                        let idx = slot - padding
                        if idx >= 0 && idx < cells.count {
                            let cell = cells[idx]
                            let key = Self.idKey(for: cell.date)
                            CalendarHeatCell(
                                cell: cell,
                                maxCount: maxCount,
                                isHovered: hoveredCellID == key,
                                onHoverChanged: { hovering in
                                    hoveredCellID = hovering
                                        ? key
                                        : (hoveredCellID == key ? nil : hoveredCellID)
                                },
                                onTap: { onOpenDay?(cell.date) }
                            )
                        } else {
                            Rectangle().fill(Color.clear).frame(width: 12, height: 12)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private static func idKey(for date: Date) -> String {
        // Cheap stable key; the popover and hover tracker only need the
        // start-of-day timestamp as a string.
        String(Int(date.timeIntervalSince1970))
    }

    private func dayHint(_ row: Int) -> String {
        // Mon / Wed / Fri labels (GitHub-style).
        switch row {
        case 1: return "Mon"
        case 3: return "Wed"
        case 5: return "Fri"
        default: return ""
        }
    }

    private func sectionHeader(_ label: String) -> some View {
        Text(label)
            .font(Theme.Font.display(size: 16, wdth: 100, wght: 600, opsz: 24))
            .foregroundStyle(Theme.Color.text)
            .kerning(-0.25)
    }
}

private struct CalendarHeatCell: View {
    let cell: CalendarHeatmapCell
    let maxCount: Int
    let isHovered: Bool
    let onHoverChanged: (Bool) -> Void
    let onTap: () -> Void

    var body: some View {
        let intensity = maxCount > 0 ? Double(cell.sessionCount) / Double(maxCount) : 0
        let alpha = cell.sessionCount == 0 ? 0.0 : (0.15 + 0.85 * intensity)
        return Button(action: onTap) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.Color.accent.opacity(alpha))
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(borderColor, lineWidth: cell.sessionCount == 0 ? 1 : (isHovered ? 1 : 0))
                )
                .frame(width: 12, height: 12)
        }
        .buttonStyle(.plain)
        .onHover(perform: onHoverChanged)
        .help("\(Self.dateString(cell.date)) — \(cell.sessionCount) session\(cell.sessionCount == 1 ? "" : "s") · \(NumFmt.compactInt(cell.tokenCount)) tok")
        .popover(isPresented: .constant(isHovered && cell.sessionCount > 0), arrowEdge: .top) {
            CalendarDayPopover(cell: cell)
        }
    }

    private var borderColor: Color {
        if cell.sessionCount == 0 { return Theme.Color.rule }
        return isHovered ? Theme.Color.accentEdge : .clear
    }

    private static func dateString(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "MMM d"
        return df.string(from: date)
    }
}

/// Compact hover popover for a calendar-day cell. Shows the full date,
/// session count, total tokens and (when available) the day's three most
/// active workspaces.
private struct CalendarDayPopover: View {
    let cell: CalendarHeatmapCell

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.fullDateString(cell.date).uppercased())
                .font(Theme.Font.sbLabel)
                .foregroundStyle(Theme.Color.textFaint)
                .kerning(1.4)
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                statColumn(
                    label: "Sessions",
                    value: NumFmt.int(cell.sessionCount)
                )
                statColumn(
                    label: "Tokens",
                    value: NumFmt.compactInt(cell.tokenCount)
                )
            }
            if !cell.topWorkspaces.isEmpty {
                Rectangle().fill(Theme.Color.rule).frame(height: 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text("TOP PROJECTS")
                        .font(Theme.Font.sbLabel)
                        .foregroundStyle(Theme.Color.textFaint)
                        .kerning(1.4)
                    ForEach(cell.topWorkspaces, id: \.self) { name in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Theme.Color.accent.opacity(0.6))
                                .frame(width: 4, height: 4)
                            Text(name)
                                .font(Theme.Font.mono(size: 11, wght: 500))
                                .foregroundStyle(Theme.Color.text)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
            Text("Click to filter sessions to this day")
                .font(Theme.Font.mono(size: 9.5, wght: 400))
                .foregroundStyle(Theme.Color.textDim)
                .padding(.top, 2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: 240, alignment: .leading)
        .background(Theme.Color.bgElev2)
    }

    @ViewBuilder
    private func statColumn(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(Theme.Font.sbLabel)
                .foregroundStyle(Theme.Color.textFaint)
                .kerning(1.4)
            Text(value)
                .font(Theme.Font.mono(size: 13, wght: 600))
                .foregroundStyle(Theme.Color.text)
        }
    }

    private static func fullDateString(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "EEE, MMM d"
        return df.string(from: date)
    }
}

// MARK: - Number formatting

private enum NumFmt {
    static func int(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// "3.2k", "1.8m", "0", suitable for big mono stat values.
    static func compactInt(_ n: Int) -> String {
        let abs = Double(Swift.abs(n))
        if abs >= 1_000_000 {
            return String(format: "%.1fm", Double(n) / 1_000_000)
        }
        if abs >= 1_000 {
            return String(format: "%.1fk", Double(n) / 1_000)
        }
        return "\(n)"
    }

    static func dollar(_ d: Double) -> String {
        if d >= 100_000 {
            return String(format: "$%.0f", d)
        }
        if d >= 1_000 {
            return String(format: "$%.1fk", d / 1_000)
        }
        if d >= 10 {
            return String(format: "$%.2f", d)
        }
        return String(format: "$%.3f", d)
    }
}
