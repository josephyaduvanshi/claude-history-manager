import SwiftUI

struct PreviewView: View {
    @Environment(AppState.self) private var state
    /// Quick Look popover presentation flag; toggled by ⌘Y.
    @State private var quickLookOpen = false

    var body: some View {
        Group {
            if let session = state.selectedSession {
                content(for: session)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Color.bgElev)
        // ⌘Y opens an in-app Quick Look popover for the selected session.
        // The keyboard-shortcut button is sized 0×0 so the user only sees
        // the actual popover surface when triggered.
        .background(
            Button {
                guard state.selectedSession != nil else { return }
                quickLookOpen.toggle()
            } label: { Color.clear }
            .keyboardShortcut("y", modifiers: [.command])
            .frame(width: 0, height: 0)
            .opacity(0)
        )
        .popover(isPresented: $quickLookOpen, arrowEdge: .leading) {
            if let session = state.selectedSession {
                QuickLookPanel(session: session, onJumpToFull: {
                    quickLookOpen = false
                    state.openTranscript(for: session)
                })
            }
        }
    }

    private func content(for session: SessionMetadata) -> some View {
        VStack(spacing: 0) {
            PVHead(session: session)
            PVBody()
            Rectangle().fill(Theme.Color.rule).frame(height: 1)
            ActionBar()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("Select a session")
                .font(Theme.Font.titleLarge)
                .foregroundStyle(Theme.Color.textMuted)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Header

private struct PVHead: View {
    @Environment(AppState.self) private var state

    let session: SessionMetadata

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(eyebrowText)
                .font(Theme.Font.pvEyebrow)
                .foregroundStyle(Theme.Color.accent)
                .kerning(0.525) // 0.05em at 10.5pt
                .padding(.bottom, 8)

            Text(session.title)
                .font(Theme.Font.pvTitle)
                .foregroundStyle(Theme.Color.text)
                .kerning(-0.65) // -0.025em at 26pt
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 14)

            StatGrid(session: session)
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Color.rule).frame(height: 1)
        }
    }

    private var isLiveNow: Bool {
        state.liveSessionIDs.contains(session.sessionID.description) || session.isLive
    }

    private var eyebrowText: String {
        let rel = RelativeTime.shortAgo(from: session.lastModifiedAt).uppercased()
        let prefix = isLiveNow ? "▸ ACTIVE SESSION" : "▸ SESSION"
        return "\(prefix) · LAST MESSAGE \(rel)"
    }
}

// MARK: - Stat grid

private struct StatGrid: View {
    @Environment(AppState.self) private var state

    let session: SessionMetadata

    /// True when the eager transcript parse is in flight for THIS session.
    /// `previewStatsSessionID` lags behind selection, so we compare to the
    /// incoming `session.sessionID` rather than `state.selectedSession`.
    private var statsLoading: Bool {
        state.previewStatsLoading
            && state.previewStatsSessionID != session.sessionID
    }

    /// The stats to display; only use previewStats when they correspond
    /// to the current session row; otherwise treat as missing.
    private var liveStats: Transcript.Stats? {
        guard state.previewStatsSessionID == session.sessionID else { return nil }
        return state.previewStats
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(stats.enumerated()), id: \.offset) { idx, stat in
                stat.view
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .overlay(alignment: .trailing) {
                        if idx < stats.count - 1 {
                            Rectangle().fill(Theme.Color.rule).frame(width: 1)
                        }
                    }
            }
        }
        .padding(.horizontal, -24) // full-bleed to the pv-head edges
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.Color.rule).frame(height: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Color.rule).frame(height: 1)
        }
    }

    private struct Stat {
        let view: AnyView
    }

    private var stats: [Stat] {
        [
            Stat(view: AnyView(startedStat)),
            Stat(view: AnyView(tokensStat)),
            Stat(view: AnyView(messagesStat)),
            Stat(view: AnyView(toolsStat)),
        ]
    }

    private var startedStat: some View {
        statCell(label: "Started",
                 value: monthDay(session.createdAt),
                 valueFont: Theme.Font.pvStatValue,
                 sub: startedSub)
    }

    private var tokensStat: some View {
        statCell(label: "Tokens",
                 value: formatWithThousands(session.tokenCount),
                 valueFont: Theme.Font.pvStatValueMono,
                 sub: tokensSub)
    }

    /// Sub-label shows "in → out" split once transcript stats land.
    private var tokensSub: String {
        if let s = liveStats, s.totalTokens > 0 {
            return "\(formatWithThousands(s.tokensInput)) in · \(formatWithThousands(s.tokensOutput)) out"
        }
        return ""
    }

    private var messagesStat: some View {
        // When transcript stats are loaded, split into "U user · A assistant".
        let value: String
        let sub: String
        if let s = liveStats {
            let total = s.userTurns + s.assistantTurns
            value = total > 0 ? "\(total)" : "\(session.messageCount)"
            sub = total > 0 ? "\(s.userTurns) user · \(s.assistantTurns) assistant" : "\(session.messageCount) total"
        } else {
            value = "\(session.messageCount)"
            sub = statsLoading ? "Loading…" : "\(session.messageCount) total"
        }
        return statCell(label: "Messages",
                        value: value,
                        valueFont: Theme.Font.pvStatValueMono,
                        sub: sub)
    }

    private var toolsStat: some View {
        let value: String
        let sub: String
        if let s = liveStats {
            let total = s.toolUseCounts.values.reduce(0, +)
            value = total > 0 ? "\(total)" : "0"
            // Top two tools by count, "Read 12 · Edit 8".
            let top = s.toolUseCounts
                .sorted { $0.value > $1.value }
                .prefix(2)
                .map { "\($0.key) \($0.value)" }
                .joined(separator: " · ")
            sub = top
        } else if statsLoading {
            value = "…"
            sub = "Loading…"
        } else {
            value = "—"
            sub = ""
        }
        return statCell(label: "Tools used",
                        value: value,
                        valueFont: Theme.Font.pvStatValueMono,
                        sub: sub)
    }

    private func statCell(label: String,
                          value: String,
                          valueFont: Font,
                          sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(Theme.Font.pvStatLabel)
                .foregroundStyle(Theme.Color.textFaint)
                .kerning(0.95) // 0.1em at 9.5pt
                .padding(.bottom, 2)
            Text(value)
                .font(valueFont)
                .foregroundStyle(Theme.Color.text)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if !sub.isEmpty {
                Text(sub)
                    .font(Theme.Font.pvStatSub)
                    .foregroundStyle(Theme.Color.textDim)
            }
        }
    }

    private var startedSub: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let time = formatter.string(from: session.createdAt)
        let rel = RelativeTime.shortAgo(from: session.createdAt)
        let dayStr: String = (rel == "just now" || rel.hasSuffix("m ago") || rel.hasSuffix("h ago"))
            ? "today"
            : rel
        return "\(dayStr) · \(time)"
    }

    private func monthDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }

    private func formatWithThousands(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

// MARK: - Body

private struct PVBody: View {
    @Environment(AppState.self) private var state
    @State private var filesExpanded = false
    @State private var toolsExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                section(title: "Latest exchange",
                        more: "view full transcript →",
                        moreAction: openTranscript) {
                    placeholderCard(
                        "Open as transcript to read the full conversation."
                    )
                }

                section(title: "Files touched",
                        more: filesTouchedMore,
                        moreAction: nil) {
                    filesTouchedContent
                }

                section(title: "Tools used",
                        more: toolsUsedMore,
                        moreAction: nil) {
                    toolsUsedContent
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var toolsUsedMore: String {
        if let s = currentStats {
            let total = s.toolUseCounts.values.reduce(0, +)
            return total == 0 ? "—" : "\(total) call\(total == 1 ? "" : "s")"
        }
        return state.previewStatsLoading ? "loading…" : "—"
    }

    @ViewBuilder
    private var toolsUsedContent: some View {
        if let s = currentStats, !s.toolUseCounts.isEmpty {
            let sorted = s.toolUseCounts
                .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            let visible = toolsExpanded ? sorted : Array(sorted.prefix(5))
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(visible.enumerated()), id: \.offset) { _, pair in
                    HStack(spacing: 8) {
                        Text(pair.key)
                            .font(Theme.Font.mono)
                            .foregroundStyle(Theme.Color.text)
                        Spacer()
                        Text("\(pair.value) call\(pair.value == 1 ? "" : "s")")
                            .font(Theme.Font.mono(size: 10.5, wght: 400))
                            .foregroundStyle(Theme.Color.textDim)
                    }
                    .padding(.vertical, 4)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Theme.Color.rule).frame(height: 1)
                    }
                }
                if sorted.count > 5 {
                    Button(action: { withAnimation(.easeOut(duration: 0.15)) { toolsExpanded.toggle() } }) {
                        Text(toolsExpanded
                             ? "Show fewer"
                             : "+ \(sorted.count - 5) more")
                            .font(Theme.Font.pvMore)
                            .foregroundStyle(Theme.Color.accent)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
            }
        } else if state.previewStatsLoading {
            placeholderCard("Loading…")
        } else {
            placeholderCard("—")
        }
    }

    /// Right-side "N files" summary or "—" / "Loading…" depending on state.
    private var filesTouchedMore: String {
        if let stats = currentStats {
            let n = stats.filesTouched.count
            return n == 0 ? "—" : "\(n) file\(n == 1 ? "" : "s")"
        }
        return state.previewStatsLoading ? "loading…" : "—"
    }

    /// Small list of up to 6 files, newest-first. Falls back to a placeholder
    /// when the transcript parse is still running or no files were touched.
    /// `+ N more` is clickable; toggles between collapsed (6) and full list.
    @ViewBuilder
    private var filesTouchedContent: some View {
        if let stats = currentStats, !stats.filesTouched.isEmpty {
            let visible = filesExpanded ? stats.filesTouched : Array(stats.filesTouched.prefix(6))
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(visible.enumerated()), id: \.offset) { _, file in
                    HStack(spacing: 8) {
                        Text(file.path)
                            .font(Theme.Font.mono)
                            .foregroundStyle(Theme.Color.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text("\(file.edits) edit\(file.edits == 1 ? "" : "s")")
                            .font(Theme.Font.mono(size: 10.5, wght: 400))
                            .foregroundStyle(Theme.Color.textDim)
                    }
                    .padding(.vertical, 4)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Theme.Color.rule).frame(height: 1)
                    }
                }
                if stats.filesTouched.count > 6 {
                    Button(action: { withAnimation(.easeOut(duration: 0.15)) { filesExpanded.toggle() } }) {
                        Text(filesExpanded
                             ? "Show fewer"
                             : "+ \(stats.filesTouched.count - 6) more")
                            .font(Theme.Font.pvMore)
                            .foregroundStyle(Theme.Color.accent)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
            }
        } else if state.previewStatsLoading {
            placeholderCard("Loading…")
        } else {
            placeholderCard("—")
        }
    }

    /// Only return previewStats when they correspond to the currently-
    /// selected session; otherwise stale values from a previous selection
    /// could leak in while the new parse is pending.
    private var currentStats: Transcript.Stats? {
        guard let sel = state.selectedSession,
              state.previewStatsSessionID == sel.sessionID else { return nil }
        return state.previewStats
    }

    /// Present the full-window TranscriptView for the currently-selected
    /// session. Same pathway as the "Open as transcript" button in the
    /// action bar; wired here so the "view full transcript →" link in the
    /// Latest exchange section is actually interactive.
    private func openTranscript() {
        guard let session = state.selectedSession else { return }
        state.openTranscript(for: session)
    }

    @ViewBuilder
    private func section<Content: View>(
        title: String,
        more: String?,
        moreAction: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title.uppercased())
                    .font(Theme.Font.pvSectionTitle)
                    .foregroundStyle(Theme.Color.textFaint)
                    .kerning(1.76) // 0.16em at 11pt
                Spacer()
                if let more {
                    if let moreAction {
                        // Clickable link-style button so the "view full
                        // transcript →" affordance actually navigates.
                        Button(action: moreAction) {
                            Text(more)
                                .font(Theme.Font.pvMore)
                                .foregroundStyle(Theme.Color.accent)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Open as transcript")
                    } else {
                        Text(more)
                            .font(Theme.Font.pvMore)
                            .foregroundStyle(Theme.Color.textDim)
                    }
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func placeholderCard(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.msgContent)
            .foregroundStyle(Theme.Color.textDim)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.Color.rule).frame(height: 1)
            }
    }
}

// MARK: - Action bar

private struct ActionBar: View {
    @Environment(AppState.self) private var state
    @Environment(\.sessionLauncher) private var launcher
    @Environment(\.terminalPreference) private var terminalPref
    @Environment(\.userMetadataActions) private var userMetaActions
    @Environment(\.editorLauncher) private var editorLauncher
    @EnvironmentObject private var editorPref: EditorPreferenceStore

    @State private var terminalPickerOpen: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            primaryButton
            starButton
            openTranscriptButton
            if let editor = editorPref.editor {
                openInEditorButton(editor: editor)
            }
            overflowMenu
            Spacer()
            terminalPick
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(Theme.Color.bg)
    }

    /// Secondary "Open in {Editor}" button; only rendered when the user
    /// picked an editor in Settings. Launches via EditorLauncher (which
    /// falls back to a CLI shim when the desktop app isn't installed).
    private func openInEditorButton(editor: Editor) -> some View {
        Button(action: { openInEditor(editor: editor) }) {
            Text("Open in \(editor.displayName)")
                .font(Theme.Font.btn)
                .foregroundStyle(Theme.Color.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Theme.Color.bgElev)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Theme.Color.ruleStrong, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(state.selectedSession == nil)
    }

    private func openInEditor(editor: Editor) {
        guard let session = state.selectedSession,
              let workspace = state.workspaces.first(where: { $0.id == session.workspaceID })
        else { return }
        let path = workspace.resumeCWD
        Task {
            do {
                try await editorLauncher.open(editor: editor, path: path)
            } catch {
                await MainActor.run {
                    ToastCenter.shared.error(
                        "Failed to open \(editor.displayName): \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    /// Star/pin toggle button next to "Resume". Filled coral when pinned.
    private var starButton: some View {
        let pinned = state.selectedUserMetadata?.isPinned == true
        return Button {
            guard let session = state.selectedSession else { return }
            userMetaActions.togglePin(session)
        } label: {
            Text(pinned ? "★" : "☆")
                .font(Theme.Font.body(size: 14, wght: 600))
                .foregroundStyle(pinned ? Theme.Color.onAccent : Theme.Color.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(pinned ? Theme.Color.accent : Theme.Color.bgElev)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(pinned ? Color.clear : Theme.Color.ruleStrong, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(state.selectedSession == nil)
    }

    /// Overflow menu: Tag / Rename / Add note / Archive / Move to Trash.
    private var overflowMenu: some View {
        Menu {
            if let session = state.selectedSession {
                Button("Tag…") { userMetaActions.openTagPicker(session) }
                Button("Rename…") { userMetaActions.beginRename(session) }
                Button("Add note…") { userMetaActions.openNote(session) }
                Button("Archive") { userMetaActions.archive(session) }
                Divider()
                Button("Move to Trash", role: .destructive) {
                    userMetaActions.moveToTrash(session)
                }
            }
        } label: {
            Text("⋯")
                .font(Theme.Font.btn)
                .foregroundStyle(Theme.Color.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Theme.Color.bgElev)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Theme.Color.ruleStrong, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(state.selectedSession == nil)
    }

    /// "Open as transcript", sets `state.transcriptSession` which
    /// AppView watches to present the full-window TranscriptView overlay.
    private var openTranscriptButton: some View {
        Button(action: {
            guard let session = state.selectedSession else { return }
            state.openTranscript(for: session)
        }) {
            Text("Open as transcript")
                .font(Theme.Font.btn)
                .foregroundStyle(Theme.Color.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Theme.Color.bgElev)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Theme.Color.ruleStrong, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(state.selectedSession == nil)
    }

    private var primaryButton: some View {
        Button(action: resume) {
            HStack(spacing: 7) {
                Text("▸ Resume in \(state.resolvedTerminalForSelected.displayName)")
                    .font(Theme.Font.btnPrimary)
                Text("⏎")
                    .font(Theme.Font.btnKbd)
                    .padding(.horizontal, 4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Theme.Color.onAccent.opacity(0.45), lineWidth: 1)
                    )
            }
            .foregroundStyle(Theme.Color.onAccent)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Theme.Color.accent)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(ScaleOnPressStyle())
        .keyboardShortcut(.return, modifiers: [])
        .disabled(state.selectedSession == nil)
    }

    // MARK: - Terminal picker menu

    private var terminalPick: some View {
        Button {
            terminalPickerOpen.toggle()
        } label: {
            HStack(spacing: 6) {
                Text("launch with")
                    .font(Theme.Font.terminalPick)
                    .foregroundStyle(Theme.Color.textDim)
                Text(state.resolvedTerminalForSelected.displayName)
                    .font(Theme.Font.terminalPickB)
                    .foregroundStyle(Theme.Color.text)
                    .kerning(-0.12)
                Text("▾")
                    .font(Theme.Font.mono(size: 9))
                    .foregroundStyle(Theme.Color.textDim)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.Color.bgElev)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Theme.Color.ruleStrong, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $terminalPickerOpen, arrowEdge: .bottom) {
            terminalPickerContent
        }
    }

    private var terminalPickerContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(state.availableTerminals.isEmpty ? Terminal.allCases : state.availableTerminals) { terminal in
                Button {
                    setOverride(terminal)
                    terminalPickerOpen = false
                } label: {
                    HStack {
                        Text(terminal.displayName)
                            .font(Theme.Font.body(size: 13, wght: 500))
                            .foregroundStyle(Theme.Color.text)
                        Spacer()
                        if terminal == state.resolvedTerminalForSelected {
                            Text("✓")
                                .foregroundStyle(Theme.Color.accent)
                        }
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                }
                .buttonStyle(.plain)
            }
            Rectangle().fill(Theme.Color.rule).frame(height: 1)
            Button {
                setAsDefault(state.resolvedTerminalForSelected)
                terminalPickerOpen = false
            } label: {
                Text("Set \(state.resolvedTerminalForSelected.displayName) as default")
                    .font(Theme.Font.mono(size: 11, wght: 400))
                    .foregroundStyle(Theme.Color.textMuted)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if state.overrideForSelected != nil {
                Button {
                    setOverride(nil)
                    terminalPickerOpen = false
                } label: {
                    Text("Clear override")
                        .font(Theme.Font.mono(size: 11, wght: 400))
                        .foregroundStyle(Theme.Color.textMuted)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(minWidth: 200)
        .background(Theme.Color.bgElev)
    }

    // MARK: - Actions

    private func resume() {
        guard let session = state.selectedSession,
              let workspace = state.workspaces.first(where: { $0.id == session.workspaceID })
        else {
            ToastCenter.shared.error("Cannot resume: no workspace resolved for selected session.")
            return
        }
        let terminal = state.resolvedTerminalForSelected
        // Prefer the authoritative cwd extracted from inside the jsonl , 
        // the dash-decoded `decodedPath` is lossy and frequently wrong for
        // any path containing spaces, underscores, dashes or dots.
        let cwd = workspace.resumeCWD
        let sid = session.sessionID.rawValue.uuidString.lowercased()

        // Refuse to launch when the resolved cwd doesn't exist on disk , 
        // `claude --resume` would silently fail with "no conversation found"
        // because Claude Code scopes session lookups by encoded cwd.
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
            ToastCenter.shared.error(
                "Workspace path missing on disk — was it moved or deleted? (\(cwd))"
            )
            return
        }

        Task {
            do {
                try await launcher.launch(
                    terminal: terminal,
                    sessionID: sid,
                    workingDirectory: cwd,
                    provider: session.provider
                )
            } catch {
                await MainActor.run {
                    ToastCenter.shared.error(
                        "Failed to launch \(terminal.displayName): \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private func setOverride(_ terminal: Terminal?) {
        guard let session = state.selectedSession else { return }
        state.overrideForSelected = terminal
        guard let pref = terminalPref else { return }
        Task {
            do {
                try await pref.setOverride(terminal, for: session.sessionID)
            } catch {
                await MainActor.run {
                    ToastCenter.shared.error(
                        "Failed to save terminal override: \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private func setAsDefault(_ terminal: Terminal) {
        state.defaultTerminal = terminal
        guard let pref = terminalPref else { return }
        Task {
            await pref.setDefaultTerminal(terminal)
        }
    }
}

/// Subtle press feedback; scales down to 0.96 while pressed and pops back.
/// Reused across Chronicle's primary action buttons so clicks feel
/// registered without being noisy.
fileprivate struct ScaleOnPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.92 : 1.0)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}
