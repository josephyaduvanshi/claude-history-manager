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
    @State private var available: [ProviderID] = []
    @State private var active: ProviderID = .claude

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
            VStack(spacing: 4) {
                Text(displayName(for: id))
                    .font(Theme.Font.body(size: 12, wght: 600))
                    .foregroundStyle(isActive ? Theme.Color.bg : Theme.Color.text)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(isActive ? Theme.Color.accent : Theme.Color.bgElev)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help("\(displayName(for: id)) sessions")
    }

    private func displayName(for id: ProviderID) -> String {
        switch id {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        case .gemini: return "Gemini"
        }
    }

    /// Re-probe `ProviderRegistry` and read `UserDefaults` so the
    /// rendering matches whatever the main window or another menubar
    /// open last persisted. Cheap; the registry probe is filesystem
    /// stat, not parsing.
    private func refresh() {
        let registry = ProviderRegistry(candidates: [
            ClaudeProvider(),
            CodexProvider(),
            GeminiProvider(),
        ])
        Task { @MainActor in
            let ids = await registry.availableIDs()
            self.available = ids
            if let raw = UserDefaults.standard.string(forKey: AppState.activeProviderDefaultsKey),
               let parsed = ProviderID(rawValue: raw) {
                self.active = parsed
            }
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
