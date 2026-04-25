import SwiftUI
import AppKit

/// The 480pt menubar dropdown. Matches
/// `.superpowers/brainstorm/41923-1777027999/content/menubar.html`:
/// search bar on top, Live / Recent / Pinned sections, keyboard footer, and
/// an "Open full window →" anchor on the right of the footer.
///
/// Data comes from `MenubarModel` (separate from `AppState`, see the
/// matching file header). The view handles keyboard selection (↑↓, ⌘1-⌘9,
/// ⏎, ⌘⏎, ⎋) and coordinates session launches through the environment's
/// `SessionLauncher` + `TerminalPreference`.
public struct MenubarView: View {
    @Environment(MenubarModel.self) private var model
    @Environment(\.sessionsRepository) private var repository
    @Environment(\.sessionLauncher) private var launcher
    @Environment(\.terminalPreference) private var terminalPref
    @Environment(\.openWindow) private var openWindow

    /// Debounce tracker so typing into the search field doesn't fire a
    /// search on every keystroke. 150 ms is the sweet spot per the plan.
    @State private var searchDebounce: Task<Void, Never>? = nil

    /// Default terminal name shown in the footer (e.g. "launch in Ghostty").
    /// Populated via a lazy async load from `TerminalPreference`.
    @State private var defaultTerminal: Terminal = .terminal

    /// Available installed terminals, used by the ⌘⏎ picker popover.
    @State private var availableTerminals: [Terminal] = []

    /// Whether the ⌘⏎ terminal picker popover is visible.
    @State private var pickerOpen: Bool = false

    /// When set, the header's error banner shows this message briefly.
    /// Kept transient so it doesn't persist across opens of the dropdown.
    @State private var errorMessage: String? = nil

    /// Auto-focuses the search field on first render so the user can start
    /// typing immediately without clicking. Closed over by the TextField's
    /// `.focused($searchFocused)` modifier.
    @FocusState private var searchFocused: Bool

    public init() {}

    public var body: some View {
        @Bindable var m = model

        VStack(spacing: 0) {
            search(binding: $m.query)
            Rectangle().fill(Theme.Color.rule).frame(height: 1)

            if let err = errorMessage {
                errorBar(err)
            }

            ScrollView {
                VStack(spacing: 0) {
                    if model.isSearching {
                        searchResultsSection
                    } else {
                        if !model.liveSessions.isEmpty { liveSection; divider }
                        recentSection
                        divider
                        pinnedSection
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 480, height: 480)

            footer
        }
        .frame(width: 480)
        .background(Theme.Color.bg)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Theme.Color.ruleStrong.opacity(0.6), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.7), radius: 40, x: 0, y: 30)
        .shadow(color: .black.opacity(0.5), radius: 15, x: 0, y: 12)
        .focusable()
        .onAppear {
            Task { await refresh() }
            // Auto-focus the search field so the user can type immediately.
            // Tiny delay lets MenuBarExtra finish mounting the window before
            // we claim focus; without this, some macOS builds steal focus
            // back to the status-item.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                searchFocused = true
            }
        }
        .onChange(of: model.query) { _, _ in scheduleSearch() }
        .onKeyPress(.upArrow)     { model.moveSelection(by: -1); return .handled }
        .onKeyPress(.downArrow)   { model.moveSelection(by:  1); return .handled }
        .onKeyPress(keys: [.return]) { press in
            // ⌘⏎ → open the terminal picker popover; plain ⏎ → launch in default.
            if press.modifiers.contains(.command) {
                pickerOpen = true
            } else {
                launchSelected()
            }
            return .handled
        }
        .onKeyPress(.escape)      { dismiss(); return .handled }
        .onKeyPress(keys: ["1","2","3","4","5","6","7","8","9"]) { press in
            // ⌘N; launch the Nth visible row (1-indexed).
            if press.modifiers.contains(.command),
               let n = Int(String(press.characters.first ?? "0")),
               n >= 1, n <= model.visibleRows.count {
                launchRow(at: n - 1)
                return .handled
            }
            return .ignored
        }
    }

    // MARK: - Sections

    private var divider: some View {
        Rectangle().fill(Theme.Color.rule).frame(height: 1).padding(.vertical, 4)
    }

    private var liveSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(
                label: "Live now",
                leading: { liveDotHeader },
                right: countText(model.liveSessions.count)
            )
            ForEach(Array(model.liveSessions.enumerated()), id: \.element.sessionID) { idx, s in
                let globalIndex = idx
                MenubarSessionRow(
                    session: s,
                    isSelected: model.selectedIndex == globalIndex,
                    shortcutIndex: shortcut(for: globalIndex),
                    rightText: nil,
                    onTap: {
                        model.selectedIndex = globalIndex
                        launchRow(at: globalIndex)
                    },
                    onHover: { model.selectedIndex = globalIndex }
                )
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(label: "Recent", right: "last 7 days")
            if model.recentSessions.isEmpty {
                emptySection(label: "No sessions in the last 7 days.")
            } else {
                let base = model.liveSessions.count
                ForEach(Array(model.recentSessions.enumerated()), id: \.element.sessionID) { idx, s in
                    let globalIndex = base + idx
                    MenubarSessionRow(
                        session: s,
                        isSelected: model.selectedIndex == globalIndex,
                        shortcutIndex: shortcut(for: globalIndex),
                        rightText: RelativeTime.shortAgo(from: s.lastModifiedAt),
                        onTap: {
                            model.selectedIndex = globalIndex
                            launchRow(at: globalIndex)
                        },
                        onHover: { model.selectedIndex = globalIndex }
                    )
                }
            }
        }
    }

    private var pinnedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(label: "★ Pinned", right: countText(model.pinnedSessions.count))
            if model.pinnedSessions.isEmpty {
                emptySection(label: "No pinned sessions yet.")
            } else {
                let base = model.liveSessions.count + model.recentSessions.count
                ForEach(Array(model.pinnedSessions.enumerated()), id: \.element.sessionID) { idx, s in
                    let globalIndex = base + idx
                    MenubarSessionRow(
                        session: s,
                        isSelected: model.selectedIndex == globalIndex,
                        shortcutIndex: shortcut(for: globalIndex),
                        rightText: RelativeTime.shortAgo(from: s.lastModifiedAt),
                        onTap: {
                            model.selectedIndex = globalIndex
                            launchRow(at: globalIndex)
                        },
                        onHover: { model.selectedIndex = globalIndex }
                    )
                }
            }
        }
    }

    private var searchResultsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(label: "Results", right: countText(model.searchResults.count))
            if model.searchResults.isEmpty {
                emptySection(label: "No matches.")
            } else {
                ForEach(Array(model.searchResults.enumerated()), id: \.element.sessionID) { idx, s in
                    MenubarSessionRow(
                        session: s,
                        isSelected: model.selectedIndex == idx,
                        shortcutIndex: shortcut(for: idx),
                        rightText: RelativeTime.shortAgo(from: s.lastModifiedAt),
                        onTap: {
                            model.selectedIndex = idx
                            launchRow(at: idx)
                        },
                        onHover: { model.selectedIndex = idx }
                    )
                }
            }
        }
    }

    // MARK: - Helpers

    /// ⌘N badge logic: first 9 visible rows get ⌘1..⌘9. Beyond that, no badge.
    private func shortcut(for globalIndex: Int) -> Int? {
        let i = globalIndex + 1
        return (1...9).contains(i) ? i : nil
    }

    private func countText(_ n: Int) -> String {
        n == 1 ? "1 session" : "\(n) sessions"
    }

    @ViewBuilder
    private func sectionHeader<Leading: View>(
        label: String,
        @ViewBuilder leading: () -> Leading,
        right: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            HStack(spacing: 6) {
                leading()
                Text(label.uppercased())
                    .font(Theme.Font.display(size: 9.5, wdth: 110, wght: 600, opsz: 12))
                    .foregroundStyle(Theme.Color.textFaint)
                    .kerning(1.7) // 0.18em at 9.5pt
                    .textCase(.uppercase)
            }
            Spacer()
            Text(right)
                .font(Theme.Font.mono(size: 9.5, wght: 400))
                .foregroundStyle(Theme.Color.textDim)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
    }

    private func sectionHeader(label: String, right: String) -> some View {
        sectionHeader(label: label, leading: { EmptyView() }, right: right)
    }

    private var liveDotHeader: some View {
        Circle()
            .fill(Theme.Color.live)
            .frame(width: 6, height: 6)
            .shadow(color: Theme.Color.live.opacity(0.4), radius: 3)
    }

    private func emptySection(label: String) -> some View {
        Text(label)
            .font(Theme.Font.mono(size: 10.5, wght: 400))
            .foregroundStyle(Theme.Color.textFaint)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Search bar

    private func search(binding: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Text("⊳")
                .font(Theme.Font.display(size: 18, wdth: 95, wght: 600, opsz: 24))
                .foregroundStyle(Theme.Color.accent)
                .kerning(-0.72) // -0.04em at 18pt

            TextField("", text: binding, prompt:
                Text("Search \(formattedTotalCount) sessions or run a command…")
                    .foregroundStyle(Theme.Color.textFaint)
            )
            .textFieldStyle(.plain)
            .font(Theme.Font.body(size: 15, wght: 400))
            .foregroundStyle(Theme.Color.text)
            .kerning(-0.15) // -0.01em at 15pt
            .accentColor(Theme.Color.accent)
            .focused($searchFocused)

            // `⌘K` scope pill; mono badge matching the main window's pill
            // (bgElev2 background, ruleStrong border, textDim foreground).
            Text("⌘K")
                .font(Theme.Font.mono(size: 10.5, wght: 500))
                .foregroundStyle(Theme.Color.textDim)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Theme.Color.bgElev2)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Theme.Color.ruleStrong, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 14)
    }

    /// Total non-deleted, non-archived session count. Loaded by the model on
    /// every popover open via a cheap `SELECT COUNT(*)`.
    private var totalSessionCount: Int { model.totalSessionCount }

    /// Thousands-separated count for the placeholder ("3,116 sessions").
    private var formattedTotalCount: String {
        let n = totalSessionCount
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            kbd("↑↓", "navigate")
            kbd("⏎", "launch")
            kbd("⌘⏎", "pick term")
            Spacer(minLength: 8)
            Button {
                openMainWindow()
            } label: {
                Text("Open full window →")
                    .font(Theme.Font.body(size: 11.5, wght: 500))
                    .foregroundStyle(Theme.Color.accent)
                    .kerning(-0.0575) // -0.005em at 11.5pt
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $pickerOpen, arrowEdge: .bottom) {
                terminalPickerMenu
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Theme.Color.bgElev)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.Color.rule).frame(height: 1)
        }
    }

    private func kbd(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(Theme.Font.mono(size: 10.5, wght: 500))
                .foregroundStyle(Theme.Color.textMuted)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Theme.Color.bg)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Theme.Color.ruleStrong, lineWidth: 1)
                )
            Text(label)
                .font(Theme.Font.mono(size: 10.5, wght: 400))
                .foregroundStyle(Theme.Color.textDim)
        }
    }

    private var terminalPickerMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Launch \(model.selectedSession?.title ?? "session") in…")
                .font(Theme.Font.mono(size: 10.5, wght: 500))
                .foregroundStyle(Theme.Color.textMuted)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

            Rectangle().fill(Theme.Color.rule).frame(height: 1)

            ForEach(availableTerminals.isEmpty ? Terminal.allCases : availableTerminals) { terminal in
                Button {
                    pickerOpen = false
                    if let s = model.selectedSession {
                        launch(session: s, terminal: terminal)
                    }
                } label: {
                    HStack {
                        Text(terminal.displayName)
                            .font(Theme.Font.body(size: 12, wght: 500))
                            .foregroundStyle(Theme.Color.text)
                        Spacer()
                        if terminal == defaultTerminal {
                            Text("default")
                                .font(Theme.Font.mono(size: 10, wght: 400))
                                .foregroundStyle(Theme.Color.textDim)
                        }
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(minWidth: 260)
        .background(Theme.Color.bgElev)
    }

    // MARK: - Error bar

    private func errorBar(_ text: String) -> some View {
        HStack(spacing: 8) {
            Text("⚠")
                .font(Theme.Font.mono(size: 11, wght: 500))
            Text(text)
                .font(Theme.Font.mono(size: 11, wght: 400))
                .lineLimit(2)
            Spacer()
        }
        .foregroundStyle(Color.black.opacity(0.85))
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Theme.Color.accent)
    }

    // MARK: - Actions

    private func refresh() async {
        guard let repo = repository else { return }
        await model.reload(from: repo)
        if let pref = terminalPref {
            let d = await pref.defaultTerminal()
            self.defaultTerminal = d
        }
        self.availableTerminals = Terminal.installed()
    }

    private func scheduleSearch() {
        searchDebounce?.cancel()
        guard let repo = repository else { return }
        if !model.isSearching {
            model.searchResults = []
            model.clampSelection()
            return
        }
        searchDebounce = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }
            await model.runSearch(using: repo)
        }
    }

    /// Launches the currently-selected row in the default terminal.
    private func launchSelected() {
        launchRow(at: model.selectedIndex)
    }

    /// Launches the row at `index` in the default terminal.
    private func launchRow(at index: Int) {
        let rows = model.visibleRows
        guard rows.indices.contains(index) else { return }
        launch(session: rows[index], terminal: defaultTerminal)
    }

    private func launch(session: SessionMetadata, terminal: Terminal) {
        // Resolve the workspace decoded path so `cd <cwd>` runs in the right
        // directory. We fetch workspaces lazily from the repo to keep the
        // menubar decoupled from AppState.
        Task {
            let cwd = await resolveCwd(for: session) ?? FileManager.default.homeDirectoryForCurrentUser.path
            let sid = session.sessionID.rawValue.uuidString.lowercased()
            do {
                try await launcher.launch(
                    terminal: terminal,
                    sessionID: sid,
                    workingDirectory: cwd
                )
            } catch {
                await MainActor.run {
                    errorMessage = "Launch failed: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Look up the decoded workspace path for `session`. Returns nil if the
    /// workspace isn't in the index.
    private func resolveCwd(for session: SessionMetadata) async -> String? {
        guard let repo = repository else { return nil }
        guard let workspaces = try? await repo.allWorkspaces() else { return nil }
        return workspaces.first(where: { $0.id == session.workspaceID })?.decodedPath
    }

    private func dismiss() {
        // MenuBarExtra's `.window` style handles Escape natively; this is a
        // no-op fallback that simply defocuses. If the menubar popover
        // doesn't close automatically, Plan 09 will add an explicit close hook.
    }

    private func openMainWindow() {
        // SwiftUI 15+: open the main WindowGroup. If the window is already
        // visible this brings it forward.
        openWindow(id: "main")
        // Ensure Chronicle becomes the frontmost app; without this, clicking
        // the menubar link only unhides the window without activating it, so
        // it appears behind whatever the user was in.
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - MenubarSessionRow

/// One row in the menubar dropdown. Layout: dot (7pt) + title/sub vstack +
/// right-aligned `rightText` / ⌘N shortcut pill. Mirrors the `.dd-row`
/// styling in the mockup including the 2px coral selection marker.
struct MenubarSessionRow: View {
    let session: SessionMetadata
    let isSelected: Bool
    /// If non-nil, render a `⌘N` shortcut pill on the right.
    let shortcutIndex: Int?
    /// Right-hand text (usually a relative time). If nil and shortcutIndex
    /// is also nil, the right slot is empty.
    let rightText: String?
    let onTap: () -> Void
    let onHover: () -> Void

    @State private var hovering: Bool = false
    @Environment(\.sessionsRepository) private var repository
    @State private var group: String = ""

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Theme.Color.dotColor(forGroup: group))
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(Theme.Font.body(size: 13.5, wght: 500))
                    .foregroundStyle(Theme.Color.text)
                    .kerning(-0.0675) // -0.005em at 13.5pt
                    .lineLimit(1)
                    .truncationMode(.tail)

                subLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            rightSlot
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(backgroundColor)
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle()
                    .fill(Theme.Color.accent)
                    .frame(width: 2)
                    .padding(.vertical, 6)
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside { onHover() }
        }
        .onTapGesture { onTap() }
        .task(id: session.workspaceID) {
            // Resolve workspace group once on first display so the dot color
            // matches the sidebar. Cached in local @State; the dropdown is
            // transient so this is fine.
            guard group.isEmpty, let repo = repository else { return }
            if let ws = (try? await repo.allWorkspaces())?.first(where: { $0.id == session.workspaceID }) {
                group = ws.group
            }
        }
    }

    private var subLine: some View {
        HStack(spacing: 6) {
            if session.isLive {
                livePill
                Text("·")
                    .font(Theme.Font.mono(size: 10.5, wght: 400))
                    .foregroundStyle(Theme.Color.textDim)
            }
            Text(subText)
                .font(Theme.Font.mono(size: 10.5, wght: 400))
                .foregroundStyle(Theme.Color.textDim)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    /// Right-hand slot: shortcut pill (if any) + right text (if any).
    @ViewBuilder
    private var rightSlot: some View {
        HStack(spacing: 6) {
            if let text = rightText {
                Text(text)
                    .font(Theme.Font.mono(size: 10.5, wght: 400))
                    .foregroundStyle(Theme.Color.textDim)
            }
            if let i = shortcutIndex {
                Text("⌘\(i)")
                    .font(Theme.Font.mono(size: 9.5, wght: 400))
                    .foregroundStyle(Theme.Color.textDim)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Theme.Color.bgElev2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Theme.Color.ruleStrong, lineWidth: 1)
                    )
            }
        }
    }

    private var livePill: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Theme.Color.live)
                .frame(width: 6, height: 6)
                .shadow(color: Theme.Color.live.opacity(0.5), radius: 2)
            Text("live")
                .font(Theme.Font.mono(size: 9.5, wght: 400))
                .foregroundStyle(Theme.Color.live)
                .kerning(0.38) // 0.04em at 9.5pt
        }
    }

    private var subText: String {
        let msgs = "\(session.messageCount) msgs"
        if !group.isEmpty {
            return "\(group) · \(msgs)"
        } else {
            return msgs
        }
    }

    private var backgroundColor: Color {
        if isSelected { return Theme.Color.bgSelected }
        if hovering   { return Theme.Color.bgHover }
        return Color.clear
    }
}
