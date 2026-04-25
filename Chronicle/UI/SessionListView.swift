import SwiftUI

struct SessionListView: View {
    @Environment(AppState.self) private var state
    @Environment(\.userMetadataActions) private var actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            listHead
            Rectangle().fill(Theme.Color.rule).frame(height: 1)
            listFilter
            Rectangle().fill(Theme.Color.rule).frame(height: 1)
            toasts
            listBody
        }
        .frame(width: 380)
        .background(Theme.Color.bg)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.Color.rule).frame(width: 1)
        }
        .sheet(item: noteSheetBinding) { session in
            NoteEditorSheet(session: session,
                            initialNote: currentNote(for: session)) { result in
                actions.saveNote(session, result)
            } onCancel: {
                state.notingSessionID = nil
            }
        }
    }

    // MARK: - Head

    private var listHead: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(headTitle)
                .font(Theme.Font.listTitle)
                .foregroundStyle(Theme.Color.text)
                .kerning(-0.44) // -0.02em at 22pt
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 14) {
                if state.isSearching {
                    metaItem(value: "\(state.displayedSessions.count)", label: "matches")
                    metaItem(value: "\(state.displayedWorkspaceCount)", label: "workspaces")
                } else {
                    metaItem(value: "\(state.sessionsForSelected.count)", label: "sessions")
                    metaItem(value: "\(state.activeThisWeekCount)", label: "active this week")
                    metaItem(value: formatTokens(state.selectedTokenTotal), label: "tokens")
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headTitle: String {
        if state.isSearching {
            return "Search results"
        }
        if let folder = state.activeSmartFolder {
            return folder.name
        }
        if state.showingArchive {
            return "Archive"
        }
        if let tag = state.activeTag {
            return "#\(tag.name)"
        }
        return state.selectedWorkspace?.displayName ?? "—"
    }

    private func metaItem(value: String, label: String) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(Theme.Font.mono(size: 11, wght: 500))
                .foregroundStyle(Theme.Color.textMuted)
            Text(label)
                .font(Theme.Font.listMeta)
                .foregroundStyle(Theme.Color.textDim)
        }
    }

    // MARK: - Filter row

    private var listFilter: some View {
        @Bindable var s = state
        return HStack(spacing: 10) {
            Text("▾")
                .font(Theme.Font.listFilter)
                .foregroundStyle(Theme.Color.textFaint)

            TextField("", text: $s.listFilter, prompt:
                Text("Filter within this workspace…")
                    .foregroundStyle(Theme.Color.textFaint)
            )
            .textFieldStyle(.plain)
            .font(Theme.Font.listFilterIn)
            .foregroundStyle(Theme.Color.text)

            Spacer()

            Button(action: {}) {
                HStack(spacing: 4) {
                    Text("Recent")
                        .font(Theme.Font.listSort)
                        .foregroundStyle(Theme.Color.textMuted)
                    Text("▾")
                        .font(Theme.Font.mono(size: 10))
                        .foregroundStyle(Theme.Color.textMuted)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Theme.Color.ruleStrong, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 18)
        .padding(.trailing, 14)
        .padding(.vertical, 8)
    }

    // Plan 06's inline toast strip is superseded by the global ToastOverlay
    // from Plan 08. Left intentionally blank so the layout keeps its slot.
    @ViewBuilder
    private var toasts: some View {
        EmptyView()
    }

    // MARK: - Body

    private var listBody: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(state.displayedSessions) { session in
                    SessionRow(
                        session: session,
                        workspace: workspaceFor(session),
                        isSelected: state.selectedSession?.sessionID == session.sessionID,
                        isPinned: state.pinnedBySession[session.sessionID.description] ?? false,
                        customTitle: state.customTitleBySession[session.sessionID.description],
                        tags: state.tagsBySession[session.sessionID.description] ?? [],
                        isRenaming: state.renamingSessionID == session.sessionID
                    ) {
                        state.select(session: session)
                    }
                    .popover(isPresented: tagPickerBinding(for: session),
                             attachmentAnchor: .rect(.bounds),
                             arrowEdge: .trailing) {
                        TagPicker(
                            session: session,
                            appliedTagIDs: Set(state.tagsBySession[session.sessionID.description]?.map(\.id) ?? []),
                            allTags: state.allTags,
                            onSave: { ids in
                                actions.setTags(session, ids)
                                state.taggingSessionID = nil
                            },
                            onClose: { state.taggingSessionID = nil },
                            onCreateTag: { name, hue in await actions.createTag(name, hue) },
                            onRenameTag: { id, name in await actions.renameTag(id, name) },
                            onDeleteTag: { id in await actions.deleteTag(id) }
                        )
                    }
                }
            }
            .padding(.bottom, 16)
        }
    }

    /// Pick the workspace label for a session row. When searching across every
    /// workspace, each row may belong to a different workspace than the one
    /// currently selected in the sidebar; so look it up by id.
    private func workspaceFor(_ session: SessionMetadata) -> Workspace? {
        if let selected = state.selectedWorkspace, selected.id == session.workspaceID {
            return selected
        }
        return state.workspaces.first { $0.id == session.workspaceID }
    }

    // MARK: - Sheet bindings

    private var noteSheetBinding: Binding<SessionMetadata?> {
        Binding {
            guard let sid = state.notingSessionID else { return nil }
            return state.displayedSessions.first { $0.sessionID == sid }
                ?? state.selectedSession
        } set: { newVal in
            if newVal == nil { state.notingSessionID = nil }
        }
    }

    private func tagPickerBinding(for session: SessionMetadata) -> Binding<Bool> {
        Binding {
            state.taggingSessionID == session.sessionID
        } set: { newVal in
            if !newVal && state.taggingSessionID == session.sessionID {
                state.taggingSessionID = nil
            }
        }
    }

    private func currentNote(for session: SessionMetadata) -> String {
        if state.selectedSession?.sessionID == session.sessionID,
           let note = state.selectedUserMetadata?.note {
            return note
        }
        return ""
    }
}

// MARK: - Session row

private struct SessionRow: View {
    @Environment(\.userMetadataActions) private var actions
    @Environment(AppState.self) private var state

    let session: SessionMetadata
    let workspace: Workspace?
    let isSelected: Bool
    let isPinned: Bool
    let customTitle: String?
    let tags: [Tag]
    let isRenaming: Bool
    let onTap: () -> Void

    @State private var isHovering = false
    @FocusState private var renameFieldFocused: Bool

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 0) {
                // 2pt selection marker column (kept even when unselected to preserve
                // horizontal alignment).
                Rectangle()
                    .fill(isSelected ? Theme.Color.accent : .clear)
                    .frame(width: 2)
                    .padding(.vertical, 14)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top, spacing: 10) {
                        if isPinned {
                            Text("★")
                                .font(Theme.Font.body(size: 11, wght: 600))
                                .foregroundStyle(Theme.Color.accent)
                                .padding(.top, 2)
                        }

                        titleOrRename

                        Spacer(minLength: 0)

                        Text(relative(session.lastModifiedAt))
                            .font(Theme.Font.sessionWhen)
                            .foregroundStyle(Theme.Color.textDim)
                            .padding(.top, 3)
                            .fixedSize()
                            .help(absoluteTimestamp(session.lastModifiedAt))
                    }

                    metaLine
                    if !tags.isEmpty {
                        tagPills
                    }
                }
                .padding(.leading, 16) // 18 - 2 (marker column)
                .padding(.trailing, 18)
                .padding(.top, 12)
                .padding(.bottom, 13)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.Color.rule).frame(height: 1)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contextMenu { rowContextMenu }
    }

    @ViewBuilder
    private var titleOrRename: some View {
        if isRenaming {
            @Bindable var s = state
            TextField("", text: $s.renamingDraft, onCommit: {
                actions.commitRename(session, s.renamingDraft)
            })
                .textFieldStyle(.plain)
                .font(Theme.Font.sessionTitle)
                .foregroundStyle(Theme.Color.text)
                .focused($renameFieldFocused)
                .onAppear { renameFieldFocused = true }
                .onSubmit {
                    actions.commitRename(session, s.renamingDraft)
                }
                .onExitCommand {
                    state.renamingSessionID = nil
                    state.renamingDraft = ""
                }
        } else {
            Text(customTitle ?? session.title)
                .font(Theme.Font.sessionTitle)
                .foregroundStyle(Theme.Color.text)
                .kerning(-0.0725)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var rowContextMenu: some View {
        Button(isPinned ? "Unpin" : "Pin") {
            actions.togglePin(session)
        }
        Button("Tag…") {
            actions.openTagPicker(session)
        }
        Button("Rename…") {
            actions.beginRename(session)
        }
        Button("Add note…") {
            actions.openNote(session)
        }
        Button("Archive") {
            actions.archive(session)
        }
        Divider()
        Button("Move to Trash", role: .destructive) {
            actions.moveToTrash(session)
        }
    }

    private var rowBackground: SwiftUI.Color {
        if isSelected { return Theme.Color.bgSelected }
        if isHovering { return Theme.Color.bgHover }
        return .clear
    }

    @ViewBuilder
    private var metaLine: some View {
        HStack(spacing: 14) {
            // Prefer the live-watcher signal over the stale snapshot flag so
            // the green pulse shows up as soon as the LiveSessionsWatcher
            // first ticks for this session.
            if isLiveNow {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Theme.Color.live)
                        .frame(width: 6, height: 6)
                        .shadow(color: Theme.Color.live.opacity(0.18), radius: 1.5, x: 0, y: 0)
                    Text("live")
                        .font(Theme.Font.sessionMeta)
                        .foregroundStyle(Theme.Color.live)
                }
            }
            Text(workspaceBreadcrumb)
                .font(Theme.Font.sessionMeta)
                .foregroundStyle(Theme.Color.textDim)
                .lineLimit(1)
        }
    }

    private var isLiveNow: Bool {
        state.liveSessionIDs.contains(session.sessionID.description) || session.isLive
    }

    @ViewBuilder
    private var tagPills: some View {
        HStack(spacing: 6) {
            ForEach(tags.prefix(3), id: \.id) { tag in
                Text(tag.name)
                    .font(Theme.Font.tag)
                    .foregroundStyle(tag.swiftUIColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(tag.swiftUIColor.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(tag.swiftUIColor.opacity(0.32), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            if tags.count > 3 {
                Text("+\(tags.count - 3)")
                    .font(Theme.Font.sessionMeta)
                    .foregroundStyle(Theme.Color.textDim)
            }
        }
    }

    private var workspaceBreadcrumb: String {
        let shortName: String = {
            if let display = workspace?.displayName,
               let last = display.components(separatedBy: "/").last {
                return last.trimmingCharacters(in: .whitespaces)
            }
            return workspace?.group ?? "workspace"
        }()
        return "\(shortName) · \(session.messageCount) messages · \(formatTokens(session.tokenCount)) tokens"
    }

    private func relative(_ date: Date) -> String {
        RelativeTime.shortAgo(from: date)
    }

    /// Tooltip-friendly absolute timestamp like "Apr 24, 2026 · 14:32".
    /// Used for the row's relative-time badge so the user can hover to see
    /// the exact moment of last activity.
    private func absoluteTimestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy · HH:mm"
        return f.string(from: date)
    }
}

// MARK: - Note editor sheet

private struct NoteEditorSheet: View {
    let session: SessionMetadata
    let initialNote: String
    let onSave: (String?) -> Void
    let onCancel: () -> Void

    @State private var draft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Add note")
                    .font(Theme.Font.titleSmall)
                    .foregroundStyle(Theme.Color.text)
                Spacer()
            }
            Text(session.title)
                .font(Theme.Font.mono(size: 11, wght: 400))
                .foregroundStyle(Theme.Color.textMuted)
                .lineLimit(1)
                .truncationMode(.tail)

            TextEditor(text: $draft)
                .font(Theme.Font.bodyBase)
                .foregroundStyle(Theme.Color.text)
                .scrollContentBackground(.hidden)
                .background(Theme.Color.bgElev)
                .frame(minHeight: 160)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Theme.Color.ruleStrong, lineWidth: 1)
                )

            HStack {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .font(Theme.Font.btn)
                    .foregroundStyle(Theme.Color.textMuted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                Spacer()
                Button("Save") {
                    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(trimmed.isEmpty ? nil : trimmed)
                }
                .buttonStyle(.plain)
                .font(Theme.Font.btnPrimary)
                .foregroundStyle(Theme.Color.onAccent)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Theme.Color.accent)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(20)
        .frame(minWidth: 420)
        .background(Theme.Color.bg)
        .onAppear { draft = initialNote }
    }
}

// MARK: - Shared formatting

/// Formats a raw token count as a short human-readable string (e.g. "38k", "2.4m").
/// Falls back to thousand-grouped integers for small numbers.
internal func formatTokens(_ n: Int) -> String {
    switch n {
    case 0..<1_000:
        return "\(n)"
    case 1_000..<1_000_000:
        let k = Double(n) / 1_000
        return k >= 100
            ? "\(Int(k.rounded()))k"
            : String(format: "%.0fk", k.rounded())
    default:
        let m = Double(n) / 1_000_000
        return String(format: "%.1fm", m)
    }
}
