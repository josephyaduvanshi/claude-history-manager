import SwiftUI
import AppKit

struct SidebarView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                allSessionsSection
                pinnedSection
                workspacesSection
                smartFoldersSection
                tagsSection
                archiveSection
                emptyStateBanner
            }
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
        .frame(width: 240)
        .background(Theme.Color.bg)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.Color.rule).frame(width: 1)
        }
    }

    // MARK: - Sections

    private var allSessionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            allSessionsRow
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    private var pinnedSection: some View {
        section(label: "Pinned", count: state.pinnedSessions.isEmpty ? nil : state.pinnedSessions.count) {
            if state.pinnedSessions.isEmpty {
                Text("— none yet —")
                    .font(Theme.Font.sbRow)
                    .foregroundStyle(Theme.Color.textDim)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
            } else {
                ForEach(state.pinnedSessions) { row in
                    PinnedRow(item: row) {
                        selectPinned(row)
                    }
                }
            }
        }
    }

    private var workspacesSection: some View {
        section(label: "Workspaces", count: state.workspaces.count) {
            workspaceGroupedList
        }
    }

    /// Bucket workspaces into ~8 colored CATEGORIES (flutter / security /
    /// ai-claude / work / rust / go / python / web / other). Buckets with
    /// > 5 workspaces render behind a colored disclosure header that
    /// defaults to collapsed; smaller buckets render their workspaces flat
    /// with a header but no disclosure (always expanded).
    @ViewBuilder
    private var workspaceGroupedList: some View {
        let buckets = bucketedWorkspaces()
        ForEach(buckets, id: \.category) { bucket in
            // Every bucket (any size) gets a clickable header so the user
            // can collapse small buckets too. Default-expanded for small
            // buckets, default-collapsed for large ones; see isBucketExpanded.
            WorkspaceCategoryRow(
                category: bucket.category,
                count: bucket.workspaces.count,
                isExpanded: isBucketExpanded(bucket)
            ) {
                let key = bucket.category.expansionKey
                // Toggle in the expanded set. The set tracks DEVIATIONS from
                // the default state for each bucket; see isBucketExpanded.
                if state.expandedWorkspaceGroups.contains(key) {
                    state.expandedWorkspaceGroups.remove(key)
                } else {
                    state.expandedWorkspaceGroups.insert(key)
                }
            }
            if isBucketExpanded(bucket) {
                ForEach(bucket.workspaces) { workspace in
                    workspaceRow(workspace, indented: true)
                }
            }
        }
    }

    /// A bucket's default expansion state depends on size: small buckets
    /// (≤ 5 items) default-expanded, large buckets default-collapsed. The
    /// `expandedWorkspaceGroups` set tracks DEVIATIONS from that default,
    /// so toggling a small bucket REMOVES it from the set (collapses it),
    /// while toggling a large bucket ADDS it (expands it).
    private func isBucketExpanded(_ bucket: WorkspaceBucket) -> Bool {
        let key = bucket.category.expansionKey
        let inSet = state.expandedWorkspaceGroups.contains(key)
        let defaultExpanded = !bucket.collapsible
        return defaultExpanded ? !inSet : inSet
    }

    private struct WorkspaceBucket {
        let category: WorkspaceCategory
        let workspaces: [Workspace]
        /// Large buckets (> 5) default-collapsed; small buckets default-expanded.
        let collapsible: Bool
    }

    private func bucketedWorkspaces() -> [WorkspaceBucket] {
        var buckets: [WorkspaceCategory: [Workspace]] = [:]
        for ws in state.workspaces {
            buckets[ws.category, default: []].append(ws)
        }
        return buckets.keys
            .sorted { $0.sortIndex < $1.sortIndex }
            .map { category in
                let list = buckets[category] ?? []
                return WorkspaceBucket(
                    category: category,
                    workspaces: list,
                    collapsible: list.count > 5
                )
            }
    }

    @ViewBuilder
    private func workspaceRow(_ workspace: Workspace, indented: Bool) -> some View {
        WorkspaceRow(
            workspace: workspace,
            indented: indented,
            isSelected: (state.activeTag == nil
                         && !state.showingArchive
                         && state.activeSmartFolder == nil
                         && state.selectedWorkspace?.id == workspace.id)
        ) {
            // Selecting a workspace leaves tag/archive/smart-folder modes.
            state.activeTag = nil
            state.showingArchive = false
            state.activeSmartFolder = nil
            state.select(workspace: workspace)
        }
    }

    @State private var smartFoldersHovering = false
    @State private var newSmartFolderOpen = false
    @State private var renamingSmartFolder: SmartFolder?

    private var smartFoldersSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            smartFoldersHeader
            if state.smartFolders.isEmpty {
                plainRow("— loading —")
            } else {
                ForEach(state.smartFolders) { folder in
                    SmartFolderRow(
                        folder: folder,
                        count: state.smartFolderCounts[folder.id] ?? 0,
                        isSelected: state.activeSmartFolder?.id == folder.id,
                        onRename: { renamingSmartFolder = folder }
                    ) {
                        // Clicking a smart folder clears workspace/tag/archive scope.
                        state.showingArchive = false
                        state.activeTag = nil
                        state.activeSmartFolder =
                            (state.activeSmartFolder?.id == folder.id) ? nil : folder
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
        .padding(.top, 18)
        .onHover { smartFoldersHovering = $0 }
        .sheet(isPresented: $newSmartFolderOpen) {
            NewSmartFolderSheet(isPresented: $newSmartFolderOpen)
        }
        .sheet(item: $renamingSmartFolder) { folder in
            RenameSmartFolderSheet(folder: folder, isPresented: Binding(
                get: { renamingSmartFolder != nil },
                set: { if !$0 { renamingSmartFolder = nil } }
            ))
        }
    }

    private var smartFoldersHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("SMART FOLDERS")
                .font(Theme.Font.sbLabel)
                .foregroundStyle(Theme.Color.textFaint)
                .kerning(1.6)
            Spacer()
            if smartFoldersHovering {
                Button {
                    newSmartFolderOpen = true
                } label: {
                    Text("+ New")
                        .font(Theme.Font.mono(size: 9, wght: 500))
                        .foregroundStyle(Theme.Color.accent)
                }
                .buttonStyle(.plain)
                .help("Create a new Smart Folder")
            } else if !state.smartFolders.isEmpty {
                Text("\(state.smartFolders.count)")
                    .font(Theme.Font.sbLabelCount)
                    .foregroundStyle(Theme.Color.textFaint)
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
    }

    private var tagsSection: some View {
        section(label: "Tags", count: state.allTags.isEmpty ? nil : state.allTags.count) {
            if state.allTags.isEmpty {
                Text("— none yet —")
                    .font(Theme.Font.sbRow)
                    .foregroundStyle(Theme.Color.textDim)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
            } else {
                ForEach(state.allTags) { tag in
                    TagRow(
                        tag: tag,
                        count: state.tagCounts[tag.id] ?? 0,
                        isSelected: state.activeTag?.id == tag.id
                    ) {
                        state.showingArchive = false
                        state.activeTag = (state.activeTag?.id == tag.id) ? nil : tag
                    }
                }
            }
        }
    }

    private var archiveSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                state.activeTag = nil
                state.showingArchive.toggle()
            } label: {
                HStack {
                    Text("ARCHIVE")
                        .font(Theme.Font.sbLabel)
                        .foregroundStyle(state.showingArchive ? Theme.Color.accent : Theme.Color.textFaint)
                        .kerning(1.6)
                    Spacer()
                    if state.archivedCount > 0 {
                        Text("\(state.archivedCount)")
                            .font(Theme.Font.sbLabelCount)
                            .foregroundStyle(Theme.Color.textFaint)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
        .padding(.top, 18)
    }

    @ViewBuilder
    private var emptyStateBanner: some View {
        if state.workspaces.isEmpty && state.bootstrapError == nil {
            VStack(alignment: .leading, spacing: 6) {
                Text("No workspaces found")
                    .font(Theme.Font.titleSmall)
                    .foregroundStyle(Theme.Color.text)
                Text("Give Chronicle Full Disk Access in System Settings → Privacy & Security to see your sessions.")
                    .font(Theme.Font.bodyBase)
                    .foregroundStyle(Theme.Color.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
        }
    }

    // MARK: - Actions

    /// Jump to a pinned session: select its workspace, clear tag/archive modes,
    /// and select the session itself so the preview pane updates.
    private func selectPinned(_ row: SessionWithMetadata) {
        state.showingArchive = false
        state.activeTag = nil
        if let ws = state.workspaces.first(where: { $0.id == row.session.workspaceID }) {
            state.select(workspace: ws)
        }
        // Defer selection so the onChange(selectedWorkspace) in AppView has a
        // chance to populate sessionsForSelected before we pick a row.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            state.selectedSession = row.session
        }
    }

    // MARK: - Building blocks

    @ViewBuilder
    private func section<Content: View>(
        label: String,
        count: Int?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel(label, count: count)
            content()
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
        .padding(.top, 18)
    }

    private func sectionLabel(_ text: String, count: Int?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text.uppercased())
                .font(Theme.Font.sbLabel)
                .foregroundStyle(Theme.Color.textFaint)
                .kerning(1.6) // 0.16em
            Spacer()
            if let count {
                Text("\(count)")
                    .font(Theme.Font.sbLabelCount)
                    .foregroundStyle(Theme.Color.textFaint)
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
    }

    private var allSessionsRow: some View {
        HStack(spacing: 10) {
            Circle().fill(Theme.Color.textMuted).frame(width: 6, height: 6)
            Text("All sessions")
                .font(Theme.Font.sbRowActive)
                .foregroundStyle(Theme.Color.text)
            Spacer()
            Text(state.workspaces.isEmpty ? "—" : "\(state.workspaces.count) ws")
                .font(Theme.Font.sbNum)
                .foregroundStyle(Theme.Color.textMuted)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Theme.Color.bgElev)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func plainRow(_ label: String) -> some View {
        HStack(spacing: 10) {
            Spacer().frame(width: 6, height: 6) // dot column placeholder
            Text(label)
                .font(Theme.Font.sbRow)
                .foregroundStyle(Theme.Color.textMuted)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }
}

// MARK: - Workspace row

private struct WorkspaceRow: View {
    let workspace: Workspace
    var indented: Bool = false
    let isSelected: Bool
    let onTap: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                if indented {
                    // 10pt left indent so grouped workspaces visually nest
                    // under their parent disclosure row.
                    Spacer().frame(width: 10)
                }
                Circle()
                    .fill(Theme.Color.dotColor(forGroup: workspace.group))
                    .frame(width: 6, height: 6)
                Text(indented ? workspace.leafName : workspace.shortName)
                    .font(isSelected ? Theme.Font.sbRowActive : Theme.Font.sbRow)
                    .foregroundStyle(isSelected ? Theme.Color.text : Theme.Color.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
            // Pointing-hand cursor while hovered so the row reads as
            // interactive; macOS otherwise leaves the arrow cursor.
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .help(tooltipText)
        .contextMenu {
            Button("Reveal in Finder") {
                let path = workspace.cwd ?? workspace.decodedPath
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: path)]
                )
            }
            Button("Copy path") {
                let path = workspace.cwd ?? workspace.decodedPath
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(path, forType: .string)
            }
            if let branch = workspace.gitBranch, !branch.isEmpty {
                Divider()
                Text("git: \(branch)")
            }
        }
    }

    /// Hover tooltip text; shows the canonical cwd, the git branch, and
    /// the Claude Code version when known. Falls back to displayName.
    private var tooltipText: String {
        var parts: [String] = []
        parts.append(workspace.cwd ?? workspace.decodedPath)
        if let b = workspace.gitBranch, !b.isEmpty { parts.append("branch: \(b)") }
        if let v = workspace.claudeVersion, !v.isEmpty { parts.append("claude \(v)") }
        return parts.joined(separator: "\n")
    }

    private var background: SwiftUI.Color {
        if isSelected { return Theme.Color.accentSoft }
        if isHovering { return Theme.Color.bgHover }
        return .clear
    }
}

// MARK: - Workspace group (rollup) row

/// Clickable disclosure row representing N sibling workspaces sharing a
/// parent directory (e.g. "StealthZero (6)"). Expanded/collapsed state
/// lives in AppState so it survives view recycling.
private struct WorkspaceGroupRow: View {
    let label: String
    let count: Int
    let isExpanded: Bool
    let onTap: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: { withAnimation(.easeOut(duration: 0.12)) { onTap() } }) {
            HStack(spacing: 8) {
                Text("▸")
                    .font(Theme.Font.mono(size: 9, wght: 500))
                    .foregroundStyle(Theme.Color.textFaint)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.easeOut(duration: 0.12), value: isExpanded)
                    .frame(width: 10, alignment: .leading)
                Text(label)
                    .font(Theme.Font.sbRow)
                    .foregroundStyle(Theme.Color.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("(\(count))")
                    .font(Theme.Font.mono(size: 10, wght: 400))
                    .foregroundStyle(Theme.Color.textFaint)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isHovering ? Theme.Color.bgHover : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

// MARK: - Workspace category (bucket) row

/// Header row for a workspace CATEGORY bucket; colored dot, uppercase
/// label ("FLUTTER"), workspace count, and an optional disclosure
/// chevron. Collapsible buckets (>5 workspaces) get the chevron and a
/// click handler; small buckets render the same row chrome with no
/// chevron and no tap target so the color cue still shows.
private struct WorkspaceCategoryRow: View {
    let category: WorkspaceCategory
    let count: Int
    let isExpanded: Bool
    var showsDisclosure: Bool = true
    let onTap: (() -> Void)?
    @State private var isHovering = false

    var body: some View {
        // Buttons need a non-optional action; gate the tap handler so
        // non-collapsible buckets don't expose a hover affordance.
        Button(action: {
            guard let onTap else { return }
            withAnimation(.easeOut(duration: 0.12)) { onTap() }
        }) {
            HStack(spacing: 10) {
                if showsDisclosure {
                    Text("▸")
                        .font(Theme.Font.mono(size: 9, wght: 500))
                        .foregroundStyle(Theme.Color.textFaint)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.easeOut(duration: 0.12), value: isExpanded)
                        .frame(width: 8, alignment: .leading)
                } else {
                    Spacer().frame(width: 8)
                }
                Circle()
                    .fill(Theme.Color.dotColor(forCategory: category))
                    .frame(width: 6, height: 6)
                Text(category.displayLabel)
                    .font(Theme.Font.sbLabel)
                    .foregroundStyle(Theme.Color.textMuted)
                    .kerning(1.4)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)")
                    .font(Theme.Font.sbLabelCount)
                    .foregroundStyle(Theme.Color.textFaint)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(onTap != nil && isHovering ? Theme.Color.bgHover : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onTap == nil)
        .onHover { hovering in
            isHovering = hovering
            guard onTap != nil else { return }
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

// MARK: - Pinned row

private struct PinnedRow: View {
    let item: SessionWithMetadata
    let onTap: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Circle().fill(Theme.Color.accent).frame(width: 6, height: 6)
                Text(item.displayTitle)
                    .font(Theme.Font.sbRow)
                    .foregroundStyle(Theme.Color.textMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isHovering ? Theme.Color.bgHover : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Smart folder row

private struct SmartFolderRow: View {
    @Environment(AppState.self) private var state
    @Environment(\.userMetadataActions) private var actions

    let folder: SmartFolder
    let count: Int
    let isSelected: Bool
    let onRename: () -> Void
    let onTap: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                // Built-ins get a coral dot; user folders pick up the default
                // muted hue so the user can visually distinguish them.
                Circle()
                    .fill(folder.isBuiltIn ? Theme.Color.accent : Theme.Color.textDim)
                    .frame(width: 6, height: 6)
                Text(folder.name)
                    .font(isSelected ? Theme.Font.sbRowActive : Theme.Font.sbRow)
                    .foregroundStyle(isSelected ? Theme.Color.text : Theme.Color.textMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                if count > 0 {
                    Text("\(count)")
                        .font(Theme.Font.sbNum)
                        .foregroundStyle(Theme.Color.textDim)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contextMenu {
            if !folder.isBuiltIn {
                Button("Rename…") { onRename() }
                Button("Delete", role: .destructive) {
                    let id = folder.id
                    Task { await actions.deleteSmartFolder(id) }
                }
            }
        }
    }

    private var background: SwiftUI.Color {
        if isSelected { return Theme.Color.accentSoft }
        if isHovering { return Theme.Color.bgHover }
        return .clear
    }
}

// MARK: - Tag row

private struct TagRow: View {
    let tag: Tag
    let count: Int
    let isSelected: Bool
    let onTap: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Circle().fill(tag.swiftUIColor).frame(width: 6, height: 6)
                Text(tag.name)
                    .font(isSelected ? Theme.Font.sbRowActive : Theme.Font.sbRow)
                    .foregroundStyle(isSelected ? Theme.Color.text : Theme.Color.textMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                if count > 0 {
                    Text("\(count)")
                        .font(Theme.Font.sbNum)
                        .foregroundStyle(Theme.Color.textDim)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var background: SwiftUI.Color {
        if isSelected { return Theme.Color.accentSoft }
        if isHovering { return Theme.Color.bgHover }
        return .clear
    }
}

// MARK: - Smart folder sheets (Plan 08 / Plan 09)

/// Sheet for creating a new smart folder. Plan 09 introduces a richer
/// COMPOUND query form so the user can mix workspace + tags + token
/// range + since-days + flags + free-text search in one folder.
///
/// Quick-presets (Today / This week / Last N / Used git push / Errored /
/// From current search) live across the top: tapping one populates the
/// compound form below; the user can then refine before saving. A
/// "Save preset as-is" path is still available so naive users get
/// one-tap creation of the legacy simple shapes.
private struct NewSmartFolderSheet: View {
    @Environment(\.userMetadataActions) private var actions
    @Environment(AppState.self) private var state
    @Binding var isPresented: Bool

    // MARK: Form state

    @State private var name: String = ""
    @State private var lastPreset: Preset?
    @State private var workspaceID: String? = nil
    @State private var selectedTagIDs: Set<Int64> = []
    @State private var minTokensText: String = ""
    @State private var maxTokensText: String = ""
    @State private var sinceDaysEnabled: Bool = false
    @State private var sinceDays: Int = 7
    @State private var includeGitPush: Bool = false
    @State private var includeErrored: Bool = false
    @State private var searchText: String = ""

    // MARK: Quick preset buttons

    /// Quick-fill recipes that pre-populate the compound form. The user
    /// picks one to start, then refines. We keep the legacy preset names
    /// so the sheet's affordances match the existing built-in folders.
    enum Preset: String, CaseIterable, Identifiable {
        case today, thisWeek, lastN, usedGitPush, errored, fromSearch
        var id: String { rawValue }
        var label: String {
            switch self {
            case .today:       return "Today"
            case .thisWeek:    return "This week"
            case .lastN:       return "Last 7 days"
            case .usedGitPush: return "Used git push"
            case .errored:     return "Errored"
            case .fromSearch:  return "From current search"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    nameField
                    presetsSection
                    workspaceSection
                    tagsSection
                    tokenRangeSection
                    sinceDaysSection
                    flagsSection
                    searchSection
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
            }
            .frame(maxHeight: 460)

            Divider()
            footer
        }
        .frame(width: 480)
    }

    // MARK: Sections

    private var header: some View {
        Text("New Smart Folder")
            .font(Theme.Font.display(size: 18, wdth: 100, wght: 600, opsz: 24))
            .foregroundStyle(Theme.Color.text)
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 14)
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Name")
            TextField("Untitled Smart Folder", text: $name)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Quick Presets")
            // FlowLayout-style wrapping via a 3-column grid. Tapping a
            // preset clears the form and applies that recipe.
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(Preset.allCases) { preset in
                    Button(action: { applyPreset(preset) }) {
                        Text(preset.label)
                            .font(Theme.Font.mono(size: 11, wght: 500))
                            .foregroundStyle(lastPreset == preset ? Theme.Color.accent : Theme.Color.textMuted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(lastPreset == preset ? Theme.Color.accentSoft : Theme.Color.bgElev)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Tap a preset to pre-fill the filters below. You can refine after.")
                .font(Theme.Font.mono(size: 10, wght: 400))
                .foregroundStyle(Theme.Color.textFaint)
        }
    }

    private var workspaceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Workspace")
            Picker("", selection: $workspaceID) {
                Text("Any workspace").tag(String?.none)
                ForEach(state.workspaces) { ws in
                    Text(ws.shortName).tag(String?.some(ws.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Tags  (must include all)")
            if state.allTags.isEmpty {
                Text("No tags yet — create some on a session preview.")
                    .font(Theme.Font.mono(size: 11, wght: 400))
                    .foregroundStyle(Theme.Color.textFaint)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
                    ForEach(state.allTags) { tag in
                        Toggle(isOn: Binding(
                            get: { selectedTagIDs.contains(tag.id) },
                            set: { isOn in
                                if isOn { selectedTagIDs.insert(tag.id) }
                                else    { selectedTagIDs.remove(tag.id) }
                            }
                        )) {
                            HStack(spacing: 6) {
                                Circle().fill(tag.swiftUIColor).frame(width: 6, height: 6)
                                Text(tag.name)
                                    .font(Theme.Font.mono(size: 11, wght: 400))
                                    .foregroundStyle(Theme.Color.textMuted)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
        }
    }

    private var tokenRangeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Token Range")
            HStack(spacing: 10) {
                TextField("min", text: $minTokensText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 120)
                Text("—")
                    .foregroundStyle(Theme.Color.textFaint)
                TextField("max", text: $maxTokensText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 120)
                Spacer()
            }
            Text("Inclusive bounds on total tokens. Leave blank for no limit.")
                .font(Theme.Font.mono(size: 10, wght: 400))
                .foregroundStyle(Theme.Color.textFaint)
        }
    }

    private var sinceDaysSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Date Range")
            HStack(spacing: 10) {
                Toggle("Modified within", isOn: $sinceDaysEnabled)
                    .toggleStyle(.checkbox)
                Stepper("\(sinceDays) day\(sinceDays == 1 ? "" : "s")",
                        value: $sinceDays, in: 1...365)
                    .disabled(!sinceDaysEnabled)
                Spacer()
            }
        }
    }

    private var flagsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Flags  (must include all)")
            HStack(spacing: 16) {
                Toggle("Used git push", isOn: $includeGitPush)
                    .toggleStyle(.checkbox)
                Toggle("Errored", isOn: $includeErrored)
                    .toggleStyle(.checkbox)
                Spacer()
            }
        }
    }

    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Search Text  (optional)")
            TextField("e.g. /full:refactor or just 'auth'", text: $searchText)
                .textFieldStyle(.roundedBorder)
            Text("Matches transcripts via FTS when text is non-blank.")
                .font(Theme.Font.mono(size: 10, wght: 400))
                .foregroundStyle(Theme.Color.textFaint)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { isPresented = false }
                .keyboardShortcut(.cancelAction)
            Button("Save") {
                save()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(buildCompound().isEmpty)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    // MARK: Actions

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(Theme.Font.sbLabel)
            .foregroundStyle(Theme.Color.textFaint)
            .kerning(1.6)
    }

    /// Pre-fill the compound form from a legacy preset. Selecting a
    /// preset clears every other filter so the user starts from a known
    /// state rather than getting an unexpected combo.
    private func applyPreset(_ preset: Preset) {
        lastPreset = preset
        // Reset compound state.
        workspaceID = nil
        selectedTagIDs.removeAll()
        minTokensText = ""
        maxTokensText = ""
        sinceDaysEnabled = false
        sinceDays = 7
        includeGitPush = false
        includeErrored = false
        searchText = ""

        switch preset {
        case .today:
            sinceDaysEnabled = true
            sinceDays = 1
            if name.isEmpty { name = "Today" }
        case .thisWeek:
            sinceDaysEnabled = true
            sinceDays = 7
            if name.isEmpty { name = "This week" }
        case .lastN:
            sinceDaysEnabled = true
            sinceDays = 7
            if name.isEmpty { name = "Last 7 days" }
        case .usedGitPush:
            includeGitPush = true
            if name.isEmpty { name = "Used git push" }
        case .errored:
            includeErrored = true
            if name.isEmpty { name = "Errored" }
        case .fromSearch:
            searchText = state.searchQuery
            if name.isEmpty { name = "Saved search" }
        }
    }

    /// Translate the form into a `SmartFolderCompoundQuery`. Empty
    /// strings → nil so the SQL builder sees `Optional.none` for unused
    /// fields rather than an empty bound parameter.
    private func buildCompound() -> SmartFolderCompoundQuery {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var flags: [String] = []
        if includeGitPush { flags.append(JsonlParser.Flag.gitPush) }
        if includeErrored { flags.append(JsonlParser.Flag.errored) }
        return SmartFolderCompoundQuery(
            workspaceID: workspaceID,
            tagIDs: Array(selectedTagIDs).sorted(),
            minTokens: Int(minTokensText.trimmingCharacters(in: .whitespaces)),
            maxTokens: Int(maxTokensText.trimmingCharacters(in: .whitespaces)),
            sinceDays: sinceDaysEnabled ? sinceDays : nil,
            flags: flags,
            searchText: trimmedSearch.isEmpty ? nil : trimmedSearch
        )
    }

    private func save() {
        let cq = buildCompound()
        guard !cq.isEmpty else { return }
        let draftName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let effective = draftName.isEmpty ? "Smart Folder" : draftName
        let query: SmartFolderQuery = .compound(cq)
        isPresented = false
        Task { _ = await actions.createSmartFolder(effective, query) }
    }
}

/// Rename sheet for a user-authored smart folder.
private struct RenameSmartFolderSheet: View {
    @Environment(\.userMetadataActions) private var actions
    let folder: SmartFolder
    @Binding var isPresented: Bool
    @State private var draft: String

    init(folder: SmartFolder, isPresented: Binding<Bool>) {
        self.folder = folder
        self._isPresented = isPresented
        self._draft = State(initialValue: folder.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Smart Folder")
                .font(Theme.Font.display(size: 18, wdth: 100, wght: 600, opsz: 24))
                .foregroundStyle(Theme.Color.text)
            TextField("Name", text: $draft)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") {
                    let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    let id = folder.id
                    isPresented = false
                    Task { await actions.renameSmartFolder(id, name) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 360)
    }
}
