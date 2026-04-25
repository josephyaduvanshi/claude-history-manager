import Foundation

/// Compact human-readable relative time strings like "just now", "5m ago",
/// "yesterday", "3w ago". Matches the visual style in `main-window-v2.html`
/// better than `RelativeDateTimeFormatter`, which mis-rounds short intervals
/// ("0w ago") when `unitsStyle = .named`.
enum RelativeTime {

    /// Short form: "just now" / "5m ago" / "2h ago" / "yesterday" / "3d ago" /
    /// "2w ago" / "1mo ago" / "1y ago".
    static func shortAgo(from date: Date, reference: Date = Date()) -> String {
        let delta = reference.timeIntervalSince(date)
        // Future dates (clock skew); clamp.
        let clamped = max(0, delta)

        if clamped < 60 { return "just now" }

        let minutes = Int(clamped / 60)
        if minutes < 60 { return "\(minutes)m ago" }

        let hours = Int(clamped / 3600)
        if hours < 24 { return "\(hours)h ago" }

        // Day-aware checks: "yesterday" specifically means the previous calendar day.
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: reference) {
            // Same day but more than 24h ago (rare, only via timezone weirdness).
            return "\(hours)h ago"
        }
        if let yesterday = cal.date(byAdding: .day, value: -1, to: reference),
           cal.isDate(date, inSameDayAs: yesterday) {
            return "yesterday"
        }

        let days = Int(clamped / 86400)
        if days < 7 { return "\(days)d ago" }

        let weeks = Int(clamped / (7 * 86400))
        if weeks < 4 { return "\(weeks)w ago" }

        if clamped < 365 * 86400 {
            // Approximate months as 30-day buckets; matches the mockup ("3mo ago").
            let months = Int(clamped / (30 * 86400))
            return "\(max(1, months))mo ago"
        }

        let years = Int(clamped / (365 * 86400))
        return "\(max(1, years))y ago"
    }
}
