import SwiftUI

/// Provider tile grid that lives at the top of the menubar dropdown.
/// Renders one tile per detected provider; clicking a tile switches
/// every list / count / stat in Chronicle to that provider's data.
///
/// Layout (CodexBar-inspired, per spec decision #9):
///
///   - Vertical, equal-width tiles
///   - Large centered icon (22 pt, weight `.semibold`)
///   - Provider name below the icon, smaller font, one line
///   - Thin (2 pt) activity bar absolutely at the bottom edge of the
///     tile, full tile width — rule-fill background, accent-fill
///     foreground proportional to last-7-days count / busiest
///     provider's count
///   - Tile height ~68 pt, padding ~12 pt
///   - Active tile: accent fill, icon + name in `Theme.Color.bg`,
///     no activity bar (the accent fill IS the activity signal)
///   - Inactive tile: `Theme.Color.bgElev` background, icon + name
///     in `Theme.Color.text`, activity bar visible at bottom
///
/// The menubar runs in its own scene scope, so it doesn't share the
/// main window's `AppState` instance. Switching is wired through
/// `UserDefaults` + a notification (`Notification.Name.chronicleActiveProviderChanged`)
/// that AppView listens for. This keeps the two scenes loosely
/// coupled — no need to lift state up to the app level.
///
/// Hidden when only one provider is detected — there's nothing to
/// switch to and the tiles would just be visual noise above the
/// session list.
struct MenubarProviderTiles: View {
    @Environment(\.sessionsRepository) private var repository
    @State private var available: [ProviderID]
    @State private var active: ProviderID
    /// Per-provider session count over the last 7 days. Cached for 60 s
    /// per `cacheStamp` so opening / closing the menubar in rapid
    /// succession doesn't hammer the DB.
    @State private var counts7d: [ProviderID: Int] = [:]
    @State private var cacheStamp: Date = .distantPast

    private static let cacheTTL: TimeInterval = 60

    /// Total tile height. Big enough to accommodate icon + name + the
    /// 2-pt bottom activity bar without crowding.
    private static let tileHeight: CGFloat = 68

    /// Pre-populate `available` from a synchronous registry probe so
    /// the tile grid renders on the very first frame. Going through
    /// `ProviderRegistry`'s actor would force an async hop and the
    /// menubar would briefly appear with no tiles between the search
    /// bar and the RECENT section — exactly the regression Team B was
    /// chasing. Each `Provider.isAvailable()` is a synchronous
    /// filesystem stat, so calling them inline is cheap.
    init() {
        let candidates: [any Provider] = [
            ClaudeProvider(),
            CodexProvider(),
            GeminiProvider(),
        ]
        let canonicalOrder: [ProviderID] = [.claude, .codex, .gemini]
        let detected = candidates.filter { $0.isAvailable() }.map { type(of: $0).id }
        let ordered = canonicalOrder.filter { detected.contains($0) }
        self._available = State(initialValue: ordered)

        // Match AppState's persisted active provider so the highlight
        // doesn't flicker from "claude" to the actual active provider
        // on first render.
        let activeID: ProviderID = {
            if let raw = UserDefaults.standard.string(forKey: AppState.activeProviderDefaultsKey),
               let parsed = ProviderID(rawValue: raw),
               ordered.contains(parsed) {
                return parsed
            }
            return ordered.first ?? .claude
        }()
        self._active = State(initialValue: activeID)
    }

    var body: some View {
        if available.count > 1 {
            HStack(spacing: 6) {
                ForEach(available, id: \.self) { id in
                    tile(for: id)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .onAppear { refresh() }
            .onReceive(NotificationCenter.default.publisher(
                for: .chronicleActiveProviderChanged
            )) { _ in
                refresh()
            }
        } else {
            EmptyView()
                .onAppear { refresh() }
        }
    }

    private func tile(for id: ProviderID) -> some View {
        let isActive = active == id
        return Button {
            switchTo(id)
        } label: {
            ZStack(alignment: .bottom) {
                // Icon + name stack, centered vertically inside the tile.
                VStack(spacing: 4) {
                    ProviderIconView(id: id, size: 22)
                        .foregroundStyle(isActive ? Theme.Color.bg : Theme.Color.text)
                    Text(id.displayName)
                        .font(Theme.Font.body(size: 11, wght: 600))
                        .foregroundStyle(isActive ? Theme.Color.bg : Theme.Color.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 12)

                // Activity bar absolutely pinned to the bottom edge.
                // Suppressed on the active tile — the accent fill itself
                // is already the activity signal there.
                if !isActive {
                    activityBar(for: id)
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: Self.tileHeight)
            .background(isActive ? Theme.Color.accent : Theme.Color.bgElev)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(helpText(for: id))
    }

    /// Thin horizontal bar at the bottom of an inactive tile. Width is
    /// `count[id] / max(counts)` of the tile's own width. Full-width
    /// rule-fill background; accent-fill foreground sized
    /// proportionally to recent activity. Renders an empty rule strip
    /// for providers with zero recent sessions so the tile silhouette
    /// is consistent across the row.
    private func activityBar(for id: ProviderID) -> some View {
        let count = counts7d[id] ?? 0
        let maxCount = counts7d.values.max() ?? 0
        let fraction: Double = maxCount > 0 ? Double(count) / Double(maxCount) : 0
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Theme.Color.rule)
                Rectangle()
                    .fill(Theme.Color.accent)
                    .frame(width: max(0, geo.size.width * fraction))
            }
        }
    }

    private func helpText(for id: ProviderID) -> String {
        let count = counts7d[id] ?? 0
        guard count > 0 else { return "\(id.displayName) sessions" }
        return "\(id.displayName) sessions — \(count) in the last 7 days"
    }

    /// Re-probe `ProviderRegistry`, read UserDefaults, and refresh the
    /// 7-day counts. Counts are cached for 60s so rapid menubar
    /// re-opens don't issue back-to-back DB reads.
    private func refresh() {
        let registry = ProviderRegistry(candidates: [
            ClaudeProvider(),
            CodexProvider(),
            GeminiProvider(),
        ])
        let repo = repository as? SessionsRepository
        Task { @MainActor in
            let ids = await registry.availableIDs()
            self.available = ids
            if let raw = UserDefaults.standard.string(forKey: AppState.activeProviderDefaultsKey),
               let parsed = ProviderID(rawValue: raw) {
                self.active = parsed
            }

            // Activity counts: skip the DB hit when our cache is fresh.
            if Date().timeIntervalSince(cacheStamp) < Self.cacheTTL,
               !counts7d.isEmpty {
                return
            }
            guard let repo else { return }
            var fresh: [ProviderID: Int] = [:]
            for id in ids {
                let n = (try? await repo.sessionCountLast(days: 7, provider: id)) ?? 0
                fresh[id] = n
            }
            counts7d = fresh
            cacheStamp = Date()
        }
    }

    private func switchTo(_ id: ProviderID) {
        guard id != active else { return }
        guard available.contains(id) else { return }
        active = id
        UserDefaults.standard.set(id.rawValue, forKey: AppState.activeProviderDefaultsKey)
        NotificationCenter.default.post(
            name: .chronicleActiveProviderChanged,
            object: nil,
            userInfo: ["providerID": id.rawValue]
        )
    }
}

extension Notification.Name {
    /// Posted whenever the menubar tile grid switches the active
    /// provider. The main window's AppView observes this and calls
    /// `state.switchTo(_:)` so all lists / counts / stats reload.
    /// `userInfo["providerID"]` is the new provider's `rawValue`.
    public static let chronicleActiveProviderChanged = Notification.Name(
        "chronicle.activeProviderChanged"
    )
}
