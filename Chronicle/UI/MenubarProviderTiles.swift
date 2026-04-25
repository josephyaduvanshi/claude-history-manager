import SwiftUI

/// Provider tile grid that lives at the top of the menubar dropdown.
/// Renders one tile per detected provider; clicking a tile switches
/// every list / count / stat in Chronicle to that provider's data.
///
/// The menubar runs in its own scene scope, so it doesn't share the
/// main window's `AppState` instance. Switching is wired through
/// `UserDefaults` + a notification (`Notification.Name.chronicleActiveProviderChanged`)
/// that AppView listens for. This keeps the two scenes loosely
/// coupled — no need to lift state up to the app level.
///
/// Active tile: theme `accent` fill, no activity bar.
/// Inactive tile: theme `bgElev` background, theme `textMuted` label.
///
/// Hidden when only one provider is detected — there's nothing to
/// switch to and the tiles would just be visual noise above the
/// session list.
struct MenubarProviderTiles: View {
    @Environment(\.sessionsRepository) private var repository
    @State private var available: [ProviderID] = []
    @State private var active: ProviderID = .claude
    /// Per-provider session count over the last 7 days. Cached for 60 s
    /// per `cacheStamp` so opening / closing the menubar in rapid
    /// succession doesn't hammer the DB.
    @State private var counts7d: [ProviderID: Int] = [:]
    @State private var cacheStamp: Date = .distantPast

    private static let cacheTTL: TimeInterval = 60

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
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: id.iconSymbol)
                        .font(.system(size: 11, weight: .semibold))
                    Text(id.displayName)
                        .font(Theme.Font.body(size: 12, wght: 600))
                }
                .foregroundStyle(isActive ? Theme.Color.bg : Theme.Color.text)

                // Activity bar — fraction of busiest provider's
                // last-7-days session count. Active tile suppresses
                // the bar (the accent fill itself is the activity
                // signal); inactive tiles show a thin coral bar
                // stretched proportionally.
                if !isActive {
                    activityBar(for: id)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(isActive ? Theme.Color.accent : Theme.Color.bgElev)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(helpText(for: id))
    }

    /// Thin horizontal bar at the bottom of an inactive tile. Width is
    /// `count[id] / max(counts)` of the tile's own width. Renders
    /// nothing for providers with zero recent sessions.
    private func activityBar(for id: ProviderID) -> some View {
        let count = counts7d[id] ?? 0
        let maxCount = counts7d.values.max() ?? 0
        let fraction: Double = maxCount > 0 ? Double(count) / Double(maxCount) : 0
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Theme.Color.rule)
                    .frame(height: 2)
                Rectangle()
                    .fill(Theme.Color.accent)
                    .frame(
                        width: max(0, geo.size.width * fraction),
                        height: 2
                    )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 2)
        .padding(.horizontal, 14)
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
