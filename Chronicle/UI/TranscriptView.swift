import SwiftUI
import MarkdownUI
import AppKit

/// Full-window transcript view. Layout matches `transcript.html`:
/// - Sticky title bar (back / session title / export + pin + quick-look)
/// - Sticky action bar (resume + open-in-editor + terminal picker)
/// - 3-column body: TOC | editorial column | meta sidebar
struct TranscriptView: View {
    @Environment(AppState.self) private var state
    @Environment(\.transcriptRepository) private var transcriptRepo

    let session: SessionMetadata

    // Scroll target for TOC clicks.
    @State private var activeMessageID: String?
    // Toggle for collapsing/expanding individual tool calls.
    @State private var expandedToolIDs: Set<String> = []
    // Quick Peek panel presentation flag (⌘Y / title-bar button).
    @State private var showQuickLook: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            TitleBar(
                session: session,
                onBack: { state.closeTranscript() },
                onExport: exportMarkdown,
                onQuickLook: { showQuickLook = true }
            )
            Rectangle().fill(Theme.Color.rule).frame(height: 1)

            ActionBar(session: session)
            Rectangle().fill(Theme.Color.rule).frame(height: 1)

            body3Col
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Color.bg)
        .task(id: session.sessionID) {
            await loadTranscript()
        }
        .popover(isPresented: $showQuickLook, arrowEdge: .top) {
            QuickLookPanel(session: session, onJumpToFull: nil)
        }
        .background(
            Button("", action: { showQuickLook.toggle() })
                .keyboardShortcut("y", modifiers: [.command])
                .opacity(0)
        )
    }

    // MARK: - Body

    @ViewBuilder
    private var body3Col: some View {
        if let transcript = state.loadedTranscript {
            HStack(spacing: 0) {
                TOCColumn(
                    transcript: transcript,
                    activeID: $activeMessageID
                )
                .frame(width: 220)
                .background(Theme.Color.bg)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(Theme.Color.rule).frame(width: 1)
                }

                CenterColumn(
                    session: session,
                    transcript: transcript,
                    activeID: $activeMessageID,
                    expandedToolIDs: $expandedToolIDs
                )
                .frame(maxWidth: .infinity)
                .background(Theme.Color.bg)

                MetaSidebar(session: session, transcript: transcript)
                    .frame(width: 280)
                    .background(Theme.Color.bgElev)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Theme.Color.rule).frame(width: 1)
                    }
            }
        } else if let err = state.transcriptLoadError {
            errorState(err)
        } else {
            loadingState
        }
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Loading transcript…")
                .font(Theme.Font.mono(size: 11))
                .foregroundStyle(Theme.Color.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Color.bg)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Text("Couldn't load transcript")
                .font(Theme.Font.display(size: 14, wght: 600))
                .foregroundStyle(Theme.Color.text)
            Text(message)
                .font(Theme.Font.mono(size: 11))
                .foregroundStyle(Theme.Color.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Color.bg)
    }

    // MARK: - Loader

    private func loadTranscript() async {
        do {
            guard let repo = transcriptRepo else {
                state.transcriptLoadError = "Transcript repository not configured."
                return
            }
            let t = try await repo.transcript(
                forSessionID: session.sessionID,
                workspaceID: session.workspaceID,
                provider: session.provider,
                filePath: session.filePath
            )
            if state.transcriptSession?.sessionID == session.sessionID {
                state.loadedTranscript = t
            }
        } catch is CancellationError {
            // ignore; user navigated away
        } catch {
            state.transcriptLoadError = error.localizedDescription
        }
    }

    // MARK: - Export .md

    private func exportMarkdown() {
        guard let transcript = state.loadedTranscript else { return }
        let markdown = TranscriptMarkdownExporter.export(
            session: session,
            transcript: transcript,
            workspaceDisplayName: workspaceDisplayName
        )
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "chronicle-\(session.sessionID.description.prefix(8)).md"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try markdown.write(to: url, atomically: true, encoding: .utf8)
                ToastCenter.shared.success("Exported \(url.lastPathComponent)")
            } catch {
                ToastCenter.shared.error("Export failed: \(error.localizedDescription)")
            }
        }
    }

    private var workspaceDisplayName: String {
        state.workspaces.first { $0.id == session.workspaceID }?.displayName ?? session.workspaceID
    }
}

// MARK: - Title bar

private struct TitleBar: View {
    let session: SessionMetadata
    let onBack: () -> Void
    let onExport: () -> Void
    let onQuickLook: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            // Reserve room for the OS traffic-light buttons that draw on top
            // of our content (window uses fullSizeContentView so the window
            // chrome and our title bar share the same Y range).
            Spacer().frame(width: 70)

            Button(action: onBack) {
                Text("← back")
                    .font(Theme.Font.mono(size: 11.5, wght: 400))
                    .foregroundStyle(Theme.Color.textMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(title)
                .font(Theme.Font.tlTitle)
                .foregroundStyle(Theme.Color.textMuted)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            HStack(spacing: 12) {
                actionButton("↗ Export .md", action: onExport)
                actionButton("★ Pin", action: {})
                actionButton("⤤ Quick Look", action: onQuickLook)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .background(Theme.Color.bgElev)
    }

    private var title: String {
        let shortID = String(session.sessionID.description.prefix(8))
        return "session \(shortID) · \(session.title)"
    }

    @ViewBuilder
    private func actionButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Theme.Font.mono(size: 11, wght: 400))
                .foregroundStyle(Theme.Color.textFaint)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            // hover color handled by default; kept as affordance hook
            _ = hovering
        }
    }
}

// MARK: - Action bar

private struct ActionBar: View {
    @Environment(AppState.self) private var state
    @Environment(\.sessionLauncher) private var launcher
    @Environment(\.terminalPreference) private var terminalPref
    @Environment(\.editorLauncher) private var editorLauncher
    @EnvironmentObject private var editorPref: EditorPreferenceStore

    let session: SessionMetadata

    var body: some View {
        HStack(spacing: 10) {
            primaryButton
            if let editor = editorPref.editor {
                editorButton(editor: editor)
            }
            Spacer()
            terminalPick
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Theme.Color.bgElev)
    }

    private func editorButton(editor: Editor) -> some View {
        Button(action: { openEditor(editor: editor) }) {
            Text("⤤ Open in \(editor.displayName) too")
                .font(Theme.Font.btn)
                .foregroundStyle(Theme.Color.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Theme.Color.bg)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Theme.Color.ruleStrong, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private func openEditor(editor: Editor) {
        guard let workspace = state.workspaces.first(where: { $0.id == session.workspaceID }) else { return }
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
        .buttonStyle(.plain)
    }

    private func secondaryButton(_ label: String) -> some View {
        Button(action: {}) {
            Text(label)
                .font(Theme.Font.btn)
                .foregroundStyle(Theme.Color.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Theme.Color.bg)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Theme.Color.ruleStrong, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private var terminalPick: some View {
        Menu {
            ForEach(state.availableTerminals.isEmpty ? Terminal.allCases : state.availableTerminals) { terminal in
                Button {
                    state.overrideForSelected = terminal
                } label: {
                    HStack {
                        Text(terminal.displayName)
                        Spacer()
                        if terminal == state.resolvedTerminalForSelected {
                            Text("✓")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text("launch with:")
                    .font(Theme.Font.terminalPick)
                    .foregroundStyle(Theme.Color.textDim)
                Text(state.resolvedTerminalForSelected.displayName)
                    .font(Theme.Font.terminalPickB)
                    .foregroundStyle(Theme.Color.text)
                Text("▾")
                    .font(Theme.Font.mono(size: 10))
                    .foregroundStyle(Theme.Color.textDim)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func resume() {
        guard let workspace = state.workspaces.first(where: { $0.id == session.workspaceID }) else {
            ToastCenter.shared.error("Cannot resume: workspace not loaded.")
            return
        }
        let terminal = state.resolvedTerminalForSelected
        // Use authoritative cwd from jsonl (workspace.cwd) when available , 
        // dash-decoded paths are often wrong.
        let cwd = workspace.resumeCWD
        let sid = session.sessionID.description

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
                    ToastCenter.shared.error("Failed to launch \(terminal.displayName): \(error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - TOC

private struct TOCColumn: View {
    let transcript: Transcript
    @Binding var activeID: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                Text("CONTENTS")
                    .font(Theme.Font.label)
                    .foregroundStyle(Theme.Color.textFaint)
                    .kerning(1.6)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 10)

                ForEach(Array(numberedEntries.enumerated()), id: \.element.id) { _, entry in
                    TOCRow(entry: entry, isActive: activeID == entry.id)
                        .onTapGesture {
                            activeID = entry.id
                        }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 22)
            .padding(.bottom, 24)
        }
    }

    private var numberedEntries: [TOCEntry] {
        var out: [TOCEntry] = []
        var counter = 1
        for msg in transcript.messages {
            switch msg {
            case .user(let u):
                out.append(TOCEntry(id: msg.id, number: counter,
                                    role: .you, text: firstLine(u.markdown)))
                counter += 1
            case .assistant(let a):
                out.append(TOCEntry(id: msg.id, number: counter,
                                    role: .claude, text: firstLine(a.markdown)))
                counter += 1
            case .toolCall(let c):
                out.append(TOCEntry(id: msg.id, number: counter,
                                    role: .tool(c.name),
                                    text: c.inlineSummary))
                counter += 1
            }
        }
        return out
    }

    private func firstLine(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "(no content)" }
        return String(trimmed.split(whereSeparator: \.isNewline).first ?? "")
    }
}

private struct TOCEntry: Identifiable {
    let id: String
    let number: Int
    let role: Role
    let text: String

    enum Role: Equatable {
        case you
        case claude
        case tool(String)

        var label: String {
            switch self {
            case .you: return "You"
            case .claude: return "Claude"
            case .tool(let name): return name
            }
        }
        var isAssistant: Bool { if case .claude = self { return true } else { return false } }
        var isTool: Bool { if case .tool = self { return true } else { return false } }
    }
}

private struct TOCRow: View {
    let entry: TOCEntry
    let isActive: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(String(format: "%02d", entry.number))
                .font(Theme.Font.txTocNum)
                .foregroundStyle(isActive ? Theme.Color.accent : Theme.Color.textFaint)
                .frame(width: 24, alignment: .leading)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.role.label.uppercased())
                    .font(Theme.Font.txTocRole)
                    .foregroundStyle(roleColor)
                    .kerning(0.72)
                Text(entry.text)
                    .font(Theme.Font.txTocItem)
                    .foregroundStyle(isActive ? Theme.Color.text : Theme.Color.textMuted)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isActive ? Theme.Color.accentSoft : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
    }

    private var roleColor: SwiftUI.Color {
        if entry.role.isAssistant { return Theme.Color.accent }
        if entry.role.isTool { return Theme.Color.txToolBlue }
        return Theme.Color.textFaint
    }
}

// MARK: - Center column

private struct CenterColumn: View {
    let session: SessionMetadata
    let transcript: Transcript
    @Binding var activeID: String?
    @Binding var expandedToolIDs: Set<String>

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // LazyVStack so off-screen messages don't materialise their
                // markdown bodies until scrolled into view. Critical for
                // sessions with megabytes of bash output; eager
                // VStack would parse them all up-front and freeze the UI.
                LazyVStack(alignment: .leading, spacing: 0) {
                    HeaderBlock(session: session, transcript: transcript)
                        .padding(.bottom, 16)

                    ForEach(Array(numberedMessages.enumerated()), id: \.element.message.id) { _, item in
                        messageView(for: item.message, number: item.number)
                            .id(item.message.id)
                            .padding(.vertical, 14)
                            .overlay(alignment: .bottom) {
                                if item.number < numberedMessages.count {
                                    Rectangle()
                                        .fill(Theme.Color.rule)
                                        .frame(height: 1)
                                }
                            }
                    }
                }
                .padding(.horizontal, 48)
                .padding(.top, 32)
                .padding(.bottom, 80)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .onChange(of: activeID) { _, newID in
                guard let newID else { return }
                withAnimation(.easeInOut(duration: 0.24)) {
                    proxy.scrollTo(newID, anchor: .top)
                }
            }
        }
    }

    private struct Item {
        let number: Int
        let message: TranscriptMessage
    }

    private var numberedMessages: [Item] {
        var out: [Item] = []
        var i = 1
        for m in transcript.messages {
            out.append(Item(number: i, message: m))
            i += 1
        }
        return out
    }

    @ViewBuilder
    private func messageView(for message: TranscriptMessage, number: Int) -> some View {
        switch message {
        case .user(let turn):
            UserMessageView(number: number, turn: turn)
        case .assistant(let turn):
            AssistantMessageView(number: number, turn: turn)
        case .toolCall(let call):
            ToolCallView(
                number: number,
                call: call,
                isExpanded: expandedToolIDs.contains(call.id),
                onToggle: {
                    if expandedToolIDs.contains(call.id) {
                        expandedToolIDs.remove(call.id)
                    } else {
                        expandedToolIDs.insert(call.id)
                    }
                }
            )
        }
    }
}

// MARK: - Header block

private struct HeaderBlock: View {
    let session: SessionMetadata
    let transcript: Transcript

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(eyebrow.uppercased())
                .font(Theme.Font.txEyebrow)
                .foregroundStyle(Theme.Color.accent)
                .kerning(0.63)

            Text(session.title)
                .font(Theme.Font.txHero)
                .foregroundStyle(Theme.Color.text)
                .kerning(-0.96)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)

            bylineRow
                .padding(.top, 6)
                .padding(.bottom, 16)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Theme.Color.rule)
                        .frame(height: 1)
                }
        }
    }

    private var eyebrow: String {
        let f = DateFormatter()
        f.dateFormat = "MMM d · HH:mm"
        let prefix = session.isLive ? "▸ still active" : "▸ last activity"
        return "\(f.string(from: session.createdAt)) · \(prefix)"
    }

    private var bylineRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            byline("\(messageTotal)", " messages · \(transcript.stats.userTurns) you · \(transcript.stats.assistantTurns) claude")
            byline("\(numberFmt(transcript.stats.totalTokens))", " tokens")
            if let model = transcript.stats.model {
                byline(model, "")
            }
            byline("started ", RelativeTime.shortAgo(from: transcript.stats.createdAt))
        }
        .font(Theme.Font.txByline)
        .foregroundStyle(Theme.Color.textDim)
    }

    private var messageTotal: Int {
        transcript.stats.userTurns + transcript.stats.assistantTurns
    }

    private func byline(_ bold: String, _ rest: String) -> some View {
        HStack(spacing: 0) {
            Text(bold).foregroundStyle(Theme.Color.textMuted)
            Text(rest)
        }
    }

    private func numberFmt(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.groupingSeparator = ","
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

// MARK: - User / Assistant

/// Defensive maximum body length we feed into MarkdownUI. Beyond this we
/// trade the markdown render for plain monospace `Text`, with a marker.
/// In practice user / assistant turns rarely exceed this; but pathological
/// pasted-in build logs can push past 200 KB.
private let kMaxMarkdownChars = 64 * 1024

@ViewBuilder
private func safeMarkdownRender(_ raw: String) -> some View {
    if raw.count <= kMaxMarkdownChars {
        Markdown(raw)
            .markdownTheme(TranscriptMarkdownStyle.theme)
            .textSelection(.enabled)
    } else {
        let truncated = String(raw.prefix(kMaxMarkdownChars))
            + "\n\n…[truncated \(raw.count - kMaxMarkdownChars) chars]"
        Text(truncated)
            .font(Theme.Font.mono(size: 11.5, wght: 400))
            .foregroundStyle(Theme.Color.textMuted)
            .textSelection(.enabled)
    }
}

private struct UserMessageView: View {
    let number: Int
    let turn: UserTurn

    var body: some View {
        MessageContainer(
            number: number,
            role: "YOU",
            roleColor: Theme.Color.txRoleYou,
            numberColor: Theme.Color.txNumber,
            timestamp: turn.timestamp
        ) {
            safeMarkdownRender(turn.markdown)
                .foregroundStyle(Theme.Color.textMuted)
        }
    }
}

private struct AssistantMessageView: View {
    let number: Int
    let turn: AssistantTurn

    var body: some View {
        MessageContainer(
            number: number,
            role: "CLAUDE",
            roleColor: Theme.Color.txRoleClaude,
            numberColor: Theme.Color.txNumberAssistant,
            timestamp: turn.timestamp
        ) {
            if turn.markdown.isEmpty {
                Text("(no text response)")
                    .font(Theme.Font.txBody)
                    .foregroundStyle(Theme.Color.textDim)
            } else {
                safeMarkdownRender(turn.markdown)
                    .foregroundStyle(Theme.Color.text)
            }
        }
    }
}

private struct MessageContainer<Content: View>: View {
    let number: Int
    let role: String
    let roleColor: SwiftUI.Color
    let numberColor: SwiftUI.Color
    let timestamp: Date
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .trailing, spacing: 4) {
                Text(String(format: "%02d", number))
                    .font(Theme.Font.txNumber)
                    .foregroundStyle(numberColor)
                    .kerning(-0.88)
                Text(role)
                    .font(Theme.Font.txRole)
                    .foregroundStyle(roleColor)
                    .kerning(1.05)
                Text(timeString)
                    .font(Theme.Font.txTime)
                    .foregroundStyle(Theme.Color.textFaint)
            }
            .frame(width: 68, alignment: .trailing)
            .padding(.top, 2)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var timeString: String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: timestamp)
    }
}

// MARK: - Tool call

private struct ToolCallView: View {
    let number: Int
    let call: ToolCall
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .trailing, spacing: 4) {
                Text(String(format: "%02d", number))
                    .font(Theme.Font.txNumber)
                    .foregroundStyle(Theme.Color.txToolBlue.opacity(0.65))
                Text(call.name.uppercased())
                    .font(Theme.Font.txRole)
                    .foregroundStyle(Theme.Color.txToolBlue)
                    .kerning(1.05)
                Text(durationString)
                    .font(Theme.Font.txTime)
                    .foregroundStyle(Theme.Color.textFaint)
            }
            .frame(width: 68, alignment: .trailing)
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 0) {
                header
                if isExpanded {
                    expandedBody
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Color.txToolBg)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Theme.Color.txToolBorder, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var header: some View {
        Button(action: onToggle) {
            HStack(spacing: 10) {
                Text("▸")
                    .font(Theme.Font.display(size: 13, wdth: 90, wght: 700))
                    .foregroundStyle(Theme.Color.txToolBlue)
                Text(call.name)
                    .font(Theme.Font.txToolHead)
                    .foregroundStyle(Theme.Color.txToolBlue)
                Text(call.inlineSummary)
                    .font(Theme.Font.txToolHead)
                    .foregroundStyle(Theme.Color.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 10)
                if let ms = call.durationMs {
                    Text("\(ms)ms")
                        .font(Theme.Font.mono(size: 11))
                        .foregroundStyle(Theme.Color.textFaint)
                }
                Text(isExpanded ? "▾" : "▸")
                    .font(Theme.Font.mono(size: 11))
                    .foregroundStyle(Theme.Color.textFaint)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !call.args.isEmpty {
                argsTable
            }
            if let result = call.resultText, !result.isEmpty {
                Divider().background(Theme.Color.txToolBorder)
                ScrollView {
                    Text(result)
                        .font(Theme.Font.txToolBody)
                        .foregroundStyle(Theme.Color.textMuted)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }
                .frame(maxHeight: 400)
                .background(Theme.Color.txToolResultBg)
            }
        }
        .padding(.top, 2)
        .padding(.bottom, 2)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.Color.txToolBorder)
                .frame(height: 1)
        }
    }

    private var argsTable: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(call.args.keys.sorted()), id: \.self) { key in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(key)
                        .font(Theme.Font.mono(size: 11, wght: 500))
                        .foregroundStyle(Theme.Color.textDim)
                        .frame(width: 100, alignment: .leading)
                    Text(call.args[key]?.prettyJSONString() ?? "")
                        .font(Theme.Font.mono(size: 11))
                        .foregroundStyle(Theme.Color.textMuted)
                        .lineLimit(3)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var durationString: String {
        if let ms = call.durationMs { return "\(ms)ms" }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: call.timestamp)
    }
}

// MARK: - Meta sidebar

private struct MetaSidebar: View {
    @Environment(AppState.self) private var state
    let session: SessionMetadata
    let transcript: Transcript

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                aboutSection
                tagsSection
                filesSection
                toolsSection
                notesSection
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: sections

    private var aboutSection: some View {
        section("About this session") {
            stat("Started", startedString)
            stat("Last active", RelativeTime.shortAgo(from: transcript.stats.lastModifiedAt))
            stat("Duration", durationString)
            if let model = transcript.stats.model {
                stat("Model", model, mono: true)
            }
            stat("Tokens", numberFmt(transcript.stats.totalTokens), mono: true)
            stat("Session ID", String(session.sessionID.description.prefix(8)), mono: true)
        }
    }

    private var tagsSection: some View {
        section("Tags") {
            Text("No tags yet")
                .font(Theme.Font.mono(size: 11))
                .foregroundStyle(Theme.Color.textDim)
                .italic()
        }
    }

    private var filesSection: some View {
        section("Files touched · \(transcript.stats.filesTouched.count)") {
            if transcript.stats.filesTouched.isEmpty {
                Text("None recorded")
                    .font(Theme.Font.mono(size: 11))
                    .foregroundStyle(Theme.Color.textDim)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(visibleFiles, id: \.path) { touch in
                        HStack {
                            Text(touch.path)
                                .font(Theme.Font.txMetaFile)
                                .foregroundStyle(Theme.Color.textMuted)
                                .lineLimit(1)
                                .truncationMode(.head)
                            Spacer()
                            Text("\(touch.edits) edit\(touch.edits == 1 ? "" : "s")")
                                .font(Theme.Font.txMetaFileCount)
                                .foregroundStyle(Theme.Color.accent)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
    }

    private var toolsSection: some View {
        section("Tools used") {
            if transcript.stats.toolUseCounts.isEmpty {
                Text("No tools used")
                    .font(Theme.Font.mono(size: 11))
                    .foregroundStyle(Theme.Color.textDim)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(sortedTools), id: \.0) { name, count in
                        HStack {
                            Text(name)
                                .font(Theme.Font.txMetaKey)
                                .foregroundStyle(Theme.Color.textDim)
                            Spacer()
                            Text("\(count) call\(count == 1 ? "" : "s")")
                                .font(Theme.Font.txMetaValMono)
                                .foregroundStyle(Theme.Color.text)
                        }
                        .padding(.vertical, 5)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(Theme.Color.rule).frame(height: 1)
                        }
                    }
                }
            }
        }
    }

    private var notesSection: some View {
        section("Notes") {
            if let note = state.selectedUserMetadata?.note, !note.isEmpty {
                Text(note)
                    .font(Theme.Font.bodyBase)
                    .foregroundStyle(Theme.Color.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                Text("No notes yet. Add one from the session's overflow menu.")
                    .font(Theme.Font.mono(size: 11))
                    .foregroundStyle(Theme.Color.textMuted)
                    .italic()
            }
        }
    }

    // MARK: helpers

    @ViewBuilder
    private func section<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label.uppercased())
                .font(Theme.Font.txMetaLabel)
                .foregroundStyle(Theme.Color.textFaint)
                .kerning(1.6)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stat(_ key: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key)
                .font(Theme.Font.txMetaKey)
                .foregroundStyle(Theme.Color.textDim)
            Spacer()
            Text(value)
                .font(mono ? Theme.Font.txMetaValMono : Theme.Font.txMetaValText)
                .foregroundStyle(Theme.Color.text)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Color.rule).frame(height: 1)
        }
    }

    private var startedString: String {
        let f = DateFormatter(); f.dateFormat = "MMM d · HH:mm"
        return f.string(from: transcript.stats.createdAt)
    }

    private var durationString: String {
        let secs = max(0, transcript.stats.lastModifiedAt.timeIntervalSince(transcript.stats.createdAt))
        if secs < 60 { return "\(Int(secs))s" }
        if secs < 3600 { return "\(Int(secs / 60))m" }
        if secs < 86400 { return "\(Int(secs / 3600))h \(Int((secs.truncatingRemainder(dividingBy: 3600)) / 60))m" }
        let days = Int(secs / 86400)
        let hours = Int((secs.truncatingRemainder(dividingBy: 86400)) / 3600)
        return "\(days)d \(hours)h"
    }

    private var visibleFiles: [Transcript.FileTouch] {
        Array(transcript.stats.filesTouched.prefix(20))
    }

    private var sortedTools: [(String, Int)] {
        transcript.stats.toolUseCounts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { ($0.key, $0.value) }
    }

    private func numberFmt(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.groupingSeparator = ","
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

// MARK: - Environment key for TranscriptRepository

private struct TranscriptRepositoryKey: EnvironmentKey {
    static let defaultValue: TranscriptRepository? = nil
}

extension EnvironmentValues {
    var transcriptRepository: TranscriptRepository? {
        get { self[TranscriptRepositoryKey.self] }
        set { self[TranscriptRepositoryKey.self] = newValue }
    }
}

// MARK: - Markdown Exporter

/// Stateless helper that renders a Transcript into a markdown string. Kept
/// separate from TranscriptView so it's easy to unit-test and re-use for
/// the `codeReview` / `pin + export` flows later.
enum TranscriptMarkdownExporter {
    static func export(
        session: SessionMetadata,
        transcript: Transcript,
        workspaceDisplayName: String
    ) -> String {
        var out = ""
        out += "# \(session.title)\n\n"
        out += "- Workspace: \(workspaceDisplayName)\n"
        out += "- Started: \(iso(transcript.stats.createdAt))\n"
        if let model = transcript.stats.model {
            out += "- Model: \(model)\n"
        }
        out += "- Messages: \(transcript.stats.userTurns) user + \(transcript.stats.assistantTurns) assistant\n"
        out += "- Tokens: \(transcript.stats.totalTokens) (in \(transcript.stats.tokensInput) / out \(transcript.stats.tokensOutput))\n"
        if !transcript.stats.toolUseCounts.isEmpty {
            let toolLine = transcript.stats.toolUseCounts
                .sorted { $0.value > $1.value }
                .map { "\($0.key)·\($0.value)" }
                .joined(separator: ", ")
            out += "- Tools used: \(toolLine)\n"
        }
        out += "\n---\n\n"

        var counter = 1
        for msg in transcript.messages {
            switch msg {
            case .user(let u):
                out += "## \(String(format: "%02d", counter)) · You\n\n"
                out += u.markdown + "\n\n"
                counter += 1
            case .assistant(let a):
                out += "## \(String(format: "%02d", counter)) · Claude\n\n"
                out += a.markdown.isEmpty ? "_(no text response)_\n\n" : a.markdown + "\n\n"
                counter += 1
            case .toolCall(let c):
                out += "### \(String(format: "%02d", counter)) · Tool: \(c.name)\n\n"
                let prettyArgs = JSONValue.object(c.args).prettyJSONString()
                out += "```json\n\(prettyArgs)\n```\n\n"
                if let result = c.resultText, !result.isEmpty {
                    out += "**Result:**\n\n```\n\(result)\n```\n\n"
                }
                counter += 1
            }
        }
        return out
    }

    private static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }
}
