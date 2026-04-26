import SwiftUI

// MARK: - Custom title bar
//
// We draw our own title bar at the top of the window content and overlap it
// onto the macOS title-bar Y range via `WindowChromeAccessor` (which sets
// `titlebarAppearsTransparent` + `fullSizeContentView` on the underlying
// NSWindow). This avoids SwiftUI's chip-style toolbar item backgrounds and
// gives us pixel-perfect control over the layout.

struct ShellTitleBar: View {
    @Bindable var state: AppState

    var body: some View {
        HStack(spacing: 12) {
            // Reserve room for the OS traffic-light buttons that draw on top
            // of our content thanks to fullSizeContentView + transparent bar.
            Spacer().frame(width: 70)

            HStack(spacing: 0) {
                Text("chronicle")
                    .font(Theme.Font.tlTitleBold)
                    .foregroundStyle(Theme.Color.text)
                Text(" · history manager")
                    .font(Theme.Font.tlTitle)
                    .foregroundStyle(Theme.Color.textMuted)
            }
            .kerning(-0.13)
            .fixedSize()

            ProviderSwitcher(state: state)
                .padding(.leading, 12)

            Spacer()

            tabSwitcher

            Spacer()

            Text(metaString)
                .font(Theme.Font.tlMeta)
                .foregroundStyle(Theme.Color.textFaint)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .frame(maxWidth: .infinity)
        .background(Theme.Color.bgElev)
        .background(
            ZStack {
                Button("") { state.mainTab = .sessions }
                    .keyboardShortcut("1", modifiers: .command)
                    .opacity(0)
                Button("") { state.mainTab = .stats }
                    .keyboardShortcut("2", modifiers: .command)
                    .opacity(0)
            }
        )
    }

    private var tabSwitcher: some View {
        HStack(spacing: 0) {
            tabButton(label: "Sessions", tab: .sessions, shortcut: "⌘1")
            tabButton(label: "Stats",    tab: .stats,    shortcut: "⌘2")
        }
        .padding(2)
        .background(Theme.Color.bg)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Theme.Color.ruleStrong, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func tabButton(label: String, tab: AppState.MainTab, shortcut: String) -> some View {
        Button {
            state.mainTab = tab
        } label: {
            HStack(spacing: 6) {
                Text(label)
                    .font(Theme.Font.body(size: 11.5, wght: 500))
                    .foregroundStyle(state.mainTab == tab ? Theme.Color.text : Theme.Color.textMuted)
                Text(shortcut)
                    .font(Theme.Font.mono(size: 9.5, wght: 400))
                    .foregroundStyle(Theme.Color.textFaint)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(state.mainTab == tab ? Theme.Color.bgElev2 : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help("\(label) (\(shortcut))")
    }

    private var metaString: String {
        let workspaces = state.workspaces.count
        let sessionsLoaded = state.sessionsForSelected.count
        let parts: [String]
        if sessionsLoaded > 0 {
            parts = ["\(sessionsLoaded) loaded",
                     "\(workspaces) workspaces",
                     indexedFragment]
        } else {
            parts = ["\(workspaces) workspaces",
                     "\(state.projectCount) projects",
                     indexedFragment]
        }
        return parts.joined(separator: " · ")
    }

    private var indexedFragment: String {
        guard let s = state.indexedSecondsAgo else { return "indexing…" }
        if s < 60      { return "indexed \(s)s ago" }
        else if s < 3600 { return "indexed \(s / 60)m ago" }
        else              { return "indexed \(s / 3600)h ago" }
    }
}
