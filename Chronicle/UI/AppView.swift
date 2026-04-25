import SwiftUI
import AppKit

struct AppView: View {
    @State private var state = AppState()
    @State private var showAllWarnings = false
    private let repository: SessionsRepositoryProtocol
    private let projectsRoot: URL
    private let launcher: any SessionLauncherProtocol
    private let terminalPref: TerminalPreference?
    private let transcriptRepo: TranscriptRepository
    private let watcherCoordinator: WatcherCoordinator?

    init(repository: SessionsRepositoryProtocol,
         launcher: any SessionLauncherProtocol = SessionLauncher(),
         terminalPref: TerminalPreference? = nil,
         watcherCoordinator: WatcherCoordinator? = nil,
         projectsRoot: URL = URL(fileURLWithPath: NSString(string: "~/.claude/projects").expandingTildeInPath, isDirectory: true)) {
        self.repository = repository
        self.launcher = launcher
        self.terminalPref = terminalPref
        self.watcherCoordinator = watcherCoordinator
        self.projectsRoot = projectsRoot
        self.transcriptRepo = TranscriptRepository(projectsRoot: projectsRoot)
    }

    /// Action bundle for Plan 06 context menus / preview buttons. Rebuilt
    /// every render; the closures close over `self` so they get the current
    /// repository + state instance.
    private var userMetadataActions: UserMetadataActions {
        UserMetadataActions(
            togglePin: { session in userMeta_togglePin(session: session) },
            archive: { session in userMeta_archive(session: session) },
            moveToTrash: { session in userMeta_moveToTrash(session: session) },
            beginRename: { [state] session in
                state.renamingSessionID = session.sessionID
                let current = state.customTitleBySession[session.sessionID.description] ?? session.title
                state.renamingDraft = current
            },
            commitRename: { session, title in
                userMeta_commitRename(session: session, title: title)
            },
            openNote: { [state] session in
                state.notingSessionID = session.sessionID
            },
            saveNote: { session, note in
                userMeta_saveNote(session: session, note: note)
            },
            openTagPicker: { [state] session in
                state.taggingSessionID = session.sessionID
            },
            setTags: { session, tagIDs in
                userMeta_setTags(session: session, tagIDs: tagIDs)
            },
            createTag: { name, hue in
                await userMeta_createTag(name: name, colorHue: hue)
            },
            renameTag: { id, newName in
                await userMeta_renameTag(id: id, to: newName)
            },
            deleteTag: { id in
                await userMeta_deleteTag(id: id)
            },
            createSmartFolder: { name, query in
                await smartFolder_create(name: name, query: query)
            },
            renameSmartFolder: { id, newName in
                await smartFolder_rename(id: id, to: newName)
            },
            deleteSmartFolder: { id in
                await smartFolder_delete(id: id)
            }
        )
    }

    // MARK: - Smart folder actions (Plan 08)

    @MainActor
    func smartFolder_create(name: String, query: SmartFolderQuery) async -> SmartFolder? {
        do {
            let folder = try await repository.createSmartFolder(name: name, query: query)
            await reloadSmartFolders()
            await reloadSmartFolderCounts()
            ToastCenter.shared.success("Saved Smart Folder")
            return folder
        } catch {
            ToastCenter.shared.error(
                "Failed to save folder: \(error.localizedDescription)"
            )
            return nil
        }
    }

    @MainActor
    func smartFolder_rename(id: Int64, to newName: String) async {
        do {
            try await repository.renameSmartFolder(id, to: newName)
            await reloadSmartFolders()
            ToastCenter.shared.info("Renamed Smart Folder")
        } catch {
            ToastCenter.shared.error(
                "Failed to rename: \(error.localizedDescription)"
            )
        }
    }

    @MainActor
    func smartFolder_delete(id: Int64) async {
        do {
            try await repository.deleteSmartFolder(id)
            // Clear active selection if we just deleted it.
            if state.activeSmartFolder?.id == id {
                state.activeSmartFolder = nil
            }
            await reloadSmartFolders()
            await reloadSmartFolderCounts()
            ToastCenter.shared.info("Deleted Smart Folder")
        } catch {
            ToastCenter.shared.error(
                "Failed to delete: \(error.localizedDescription)"
            )
        }
    }

    var body: some View {
        ZStack {
            // Hide the entire 3-pane shell behind the splash while indexing , 
            // the user complained that toolbar / sidebar peek through during
            // first-launch loading. Splash should be the ONLY visible thing.
            if state.isBootstrapping && state.workspaces.isEmpty {
                ChronicleApp.BootstrapSplash(
                    progress: state.bootstrapProgress,
                    message: state.bootstrapStatus.isEmpty
                        ? "Reading ~/.claude/projects"
                        : state.bootstrapStatus
                )
                .transition(.opacity)
                .zIndex(3)
            } else {
                mainBody
            }
            if let ts = state.transcriptSession {
                TranscriptView(session: ts)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(1)
            }
            ToastOverlay(center: .shared)
                .zIndex(2)
                .allowsHitTesting(true)
        }
        .background(WindowChromeAccessor())
        .ignoresSafeArea(.container, edges: .top)
        .environment(state)
        .environment(\.sessionLauncher, launcher)
        .environment(\.terminalPreference, terminalPref)
        .environment(\.transcriptRepository, transcriptRepo)
        .environment(\.userMetadataActions, userMetadataActions)
        .frame(minWidth: 1320, minHeight: 820)
        .background(Theme.Color.bg)
        .animation(.easeInOut(duration: 0.22), value: state.transcriptSession?.id)
        .task {
            do {
                // Detect which providers are usable on this machine and
                // restore the last-used selection. Defaults to .claude
                // for v0.1.x upgraders even when other providers are
                // installed. Done before bootstrap so the segmented
                // control renders correctly the moment the splash drops.
                let registry = ProviderRegistry(candidates: [
                    ClaudeProvider(),
                    CodexProvider(),
                    GeminiProvider(),
                ])
                state.availableProviders = await registry.availableIDs()
                state.loadActiveProviderFromDefaults()
                if !state.availableProviders.contains(state.activeProvider) {
                    // Selected provider went away (uninstalled etc.) —
                    // fall back to the canonical first available.
                    state.activeProvider = state.availableProviders.first ?? .claude
                    state.saveActiveProviderToDefaults()
                }
                if let repo = repository as? SessionsRepository {
                    await repo.setActiveProvider(state.activeProvider)
                }

                // Use the progress-reporting overload when the concrete
                // SessionsRepository is in play so we can populate the
                // bootstrap indexing card.
                if let repo = repository as? SessionsRepository {
                    try await repo.bootstrap(rootURL: projectsRoot) { frac, msg in
                        Task { @MainActor in
                            state.bootstrapProgress = frac
                            state.bootstrapStatus = msg
                        }
                    }
                } else {
                    try await repository.bootstrap(rootURL: projectsRoot)
                }
                // First-launch indexed Claude — record so the segmented
                // control's onChange handler doesn't re-index Claude
                // every time the user toggles back to it.
                state.bootstrappedProviders.insert(.claude)
                state.saveActiveProviderToDefaults()
                // Order matters: load workspaces BEFORE flipping isBootstrapping
                // off, otherwise mainBody renders for a tick with empty state
                // and shows the FDA "can't see your sessions" card by mistake.
                state.bootstrapProgress = 1.0
                if let repo = repository as? SessionsRepository {
                    let warnings = await repo.recentBootstrapErrors()
                    if !warnings.isEmpty {
                        state.bootstrapWarnings = warnings
                    }
                }
                state.workspaces = try await repository.allWorkspaces()
                state.lastIndexedAt = Date()

                // Terminal launcher preferences; populate installed list and
                // default choice so the action bar renders the correct name.
                state.availableTerminals = Terminal.installed()
                if let pref = terminalPref {
                    state.defaultTerminal = await pref.defaultTerminal()
                }

                if let first = state.workspaces.first {
                    state.select(workspace: first)
                    await reloadCurrentSessionList()
                }

                await reloadUserMetadataOverlays()
                await reloadSmartFolders()
                await reloadSmartFolderCounts()

                // NOW flip the splash off; mainBody will see populated
                // workspaces + a selected first workspace + an already-loaded
                // session list, so there's no flicker and no empty-state card.
                state.isBootstrapping = false

                // Wire the live watcher + FS watcher to state mutations.
                // Done here (not in init) so we have a live AppState instance.
                if let coord = watcherCoordinator {
                    wireWatcherCallbacks(coord: coord)
                }

                // Kick off a background loop to refresh smart-folder counts
                // every 30s; cheap COUNT(*) queries, fine to poll.
                startSmartFolderCountsLoop()
            } catch {
                state.bootstrapError = error.localizedDescription
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .chronicleDefaultTerminalChanged)) { _ in
            // Settings → Terminal picker writes a new default and fires this
            // notification. Refetch so the "Resume in {Term}" button + the
            // "launch with X" pill reflect the change without an app relaunch.
            if let pref = terminalPref {
                Task { @MainActor in
                    state.defaultTerminal = await pref.defaultTerminal()
                }
            }
        }
        .onChange(of: state.selectedWorkspace) { _, _ in
            Task { await reloadCurrentSessionList() }
        }
        .onChange(of: state.activeTag) { _, _ in
            Task { await reloadCurrentSessionList() }
        }
        .onChange(of: state.showingArchive) { _, _ in
            Task { await reloadCurrentSessionList() }
        }
        .onChange(of: state.activeSmartFolder?.id) { _, _ in
            Task { await reloadCurrentSessionList() }
        }
        .onChange(of: state.selectedSession) { _, newSession in
            // Reload per-session override whenever the selection changes.
            if let session = newSession, let pref = terminalPref {
                Task {
                    let ov = (try? await pref.override(for: session.sessionID)) ?? nil
                    state.overrideForSelected = ov
                }
            } else {
                state.overrideForSelected = nil
            }
            // Load selected session user metadata + tags for the preview pane.
            if let session = newSession {
                Task {
                    state.selectedUserMetadata = try? await repository.userMetadata(for: session.sessionID)
                    state.selectedTags = (try? await repository.tags(for: session.sessionID)) ?? []
                }
                // Eager-load transcript stats so Files touched / Tools used /
                // Messages split populate rather than showing `—`. Cancels
                // any previously in-flight parse.
                state.loadPreviewStats(for: session, from: transcriptRepo)
            } else {
                state.selectedUserMetadata = nil
                state.selectedTags = []
                state.clearPreviewStats()
            }
        }
        .onChange(of: state.searchQuery) { _, _ in scheduleSearch() }
        .onChange(of: state.activeTimeWindow) { _, _ in scheduleSearch() }
        .onChange(of: state.showAllWorkspaces) { _, _ in scheduleSearch() }
        .onChange(of: state.mainTab) { _, tab in
            if tab == .stats {
                Task { await reloadStats() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: .chronicleActiveProviderChanged
        )) { note in
            // Menubar tile click. Translate the notification's payload
            // into a state.switchTo so the main window's onChange
            // handler reloads through the same code path the segmented
            // control uses.
            guard let raw = note.userInfo?["providerID"] as? String,
                  let id = ProviderID(rawValue: raw) else { return }
            state.switchTo(id)
        }
        .onChange(of: state.activeProvider) { _, newProvider in
            // The user clicked a different segment. Tell the repository
            // to swap its provider scope, run per-provider bootstrap
            // the first time we see this provider in this DB, then
            // reload everything from scratch — workspaces, the
            // current selection's session list, user metadata
            // overlays, smart folder counts, stats (if currently
            // shown).
            //
            // `currentProvider` is captured into a `let` because the
            // Task closure is `Sendable` and `state.activeProvider`
            // is non-Sendable across the boundary.
            let currentProvider = newProvider
            let projectsRoot = self.projectsRoot
            Task {
                if let repo = repository as? SessionsRepository {
                    await repo.setActiveProvider(currentProvider)

                    // First-time bootstrap for this provider's
                    // on-disk format. Show the splash so the user
                    // sees indexing progress instead of a blank
                    // pane while we walk thousands of files.
                    if !state.bootstrappedProviders.contains(currentProvider) {
                        state.isBootstrapping = true
                        state.bootstrapProgress = 0.0
                        state.bootstrapStatus = "Indexing \(currentProvider.displayName)"
                        let progress: @Sendable (Double, String) -> Void = { frac, msg in
                            Task { @MainActor in
                                state.bootstrapProgress = frac
                                state.bootstrapStatus = msg
                            }
                        }
                        switch currentProvider {
                        case .claude:
                            try? await repo.bootstrap(rootURL: projectsRoot, progress: progress)
                        case .codex:
                            try? await repo.bootstrapCodex(progress: progress)
                        case .gemini:
                            try? await repo.bootstrapGemini(progress: progress)
                        }
                        state.bootstrappedProviders.insert(currentProvider)
                        state.saveActiveProviderToDefaults()
                        state.isBootstrapping = false
                        state.bootstrapProgress = nil
                    }
                }
                state.workspaces = (try? await repository.allWorkspaces()) ?? []
                if let first = state.workspaces.first {
                    state.select(workspace: first)
                    await reloadCurrentSessionList()
                } else {
                    state.sessionsForSelected = []
                    state.selectedWorkspace = nil
                    state.selectedSession = nil
                }
                await reloadUserMetadataOverlays()
                await reloadSmartFolders()
                await reloadSmartFolderCounts()
                if state.mainTab == .stats {
                    await reloadStats()
                }
            }
        }
    }

    // MARK: - Watcher wiring

    /// Hooks the live + filesystem watchers up to AppState mutations. Pulled
    /// out of `body.task` so the body's expression complexity stays under the
    /// type-checker's budget. Captures `state` and `repository` explicitly so
    /// the closures don't capture `self` (a `var`-style View binding).
    @MainActor
    private func wireWatcherCallbacks(coord: WatcherCoordinator) {
        let repo = repository
        coord.onLiveUpdate = { [state] live in
            await MainActor.run {
                state.liveSessions = live
            }
        }
        coord.onFileChange = { [state] _ in
            // Refresh smart folder counts + overlays on any FS change. We
            // don't reload the session list here , the user's in-flight
            // selection shouldn't jump.
            let counts = (try? await repo.smartFolderCounts()) ?? [:]
            await MainActor.run {
                state.smartFolderCounts = counts
            }
        }
    }

    // MARK: - Stats loading (Plan 08)

    @MainActor
    func reloadStats() async {
        state.statsLoading = true
        defer { state.statsLoading = false }

        async let ws: [WorkspaceStats] = (try? await repository.statsByWorkspace()) ?? []
        async let totals: (sessions: Int, tokens: Int, estimatedCostUSD: Double) =
            (try? await repository.totalStats()) ?? (0, 0, 0)
        async let heat: [HeatmapCell] = (try? await repository.hourWeekdayHeatmap(days: 90)) ?? []
        async let calendar: [CalendarHeatmapCell] =
            (try? await repository.calendarHeatmap(days: 90)) ?? []
        async let models: [(model: String, tokens: Int, cost: Double)] =
            (try? await repository.statsByModel()) ?? []

        state.workspaceStats    = await ws
        state.totals            = await totals
        state.hourWeekdayHeatmap = await heat
        state.calendarHeatmap   = await calendar
        state.modelBreakdown = (await models).map {
            AppState.ModelBreakdown(model: $0.model, tokens: $0.tokens, cost: $0.cost)
        }
    }

    // MARK: - Main body (3-pane)

    /// The default 3-pane layout. Extracted so the transcript overlay
    /// can float on top of it via `ZStack` in `body`.
    ///
    /// The custom `TitleBar` is overlapped onto the macOS title-bar Y range
    /// via `WindowChromeAccessor` (which sets `titlebarAppearsTransparent`
    /// and `fullSizeContentView` on the underlying `NSWindow`). That gives us
    /// the unified-title-bar look without inheriting SwiftUI's chip-style
    /// toolbar item backgrounds.
    private var mainBody: some View {
        VStack(spacing: 0) {
            ShellTitleBar(state: state)
            hairline
            SearchBar()
            if case .indexing(let p) = state.searchState {
                indexingBanner(progress: p)
            }
            hairline

            if !state.bootstrapWarnings.isEmpty {
                warningsBanner
            }
            if let err = state.bootstrapError {
                errorBanner(err)
            }

            if state.mainTab == .stats {
                StatsView(onOpenDay: { day in
                    // Return to Sessions, date-scope via search filter.
                    let cal = Calendar.current
                    let daysAgo = max(0, Int(Date().timeIntervalSince(day) / 86_400))
                    state.activeTimeWindow = daysAgo == 0 ? .today : .relative(days: max(1, daysAgo + 1))
                    state.mainTab = .sessions
                    _ = cal
                })
            } else {
                HStack(spacing: 0) {
                    SidebarView()
                    if !state.isBootstrapping
                        && state.workspaces.isEmpty
                        && state.bootstrapError == nil {
                        FullDiskAccessEmptyState(
                            provider: state.activeProvider,
                            onReload: { await reloadAfterEmpty() }
                        )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        SessionListView()
                        PreviewView()
                    }
                }
            }
        }
    }

    /// Re-runs bootstrap and reloads UI state after the user clicks "Reload"
    /// on the FDA empty-state card. Used because the user is unlikely to
    /// quit Chronicle just to retry; they'll have just granted FDA in
    /// System Settings and want to see results immediately.
    @MainActor
    private func reloadAfterEmpty() async {
        state.isBootstrapping = true
        state.bootstrapProgress = 0.0
        state.bootstrapStatus = "Re-scanning ~/.claude/projects"
        do {
            if let repo = repository as? SessionsRepository {
                try await repo.bootstrap(rootURL: projectsRoot) { frac, msg in
                    Task { @MainActor in
                        state.bootstrapProgress = frac
                        state.bootstrapStatus = msg
                    }
                }
            } else {
                try await repository.bootstrap(rootURL: projectsRoot)
            }
            state.workspaces = try await repository.allWorkspaces()
            state.lastIndexedAt = Date()
            await reloadSmartFolders()
            await reloadSmartFolderCounts()
        } catch {
            state.bootstrapError = error.localizedDescription
        }
        state.isBootstrapping = false
        state.bootstrapProgress = nil
    }

    // MARK: - Session list loading (workspace / tag / archive)

    /// Populate `state.sessionsForSelected` based on the current mode.
    /// Called after bootstrap, after workspace/tag/archive changes, and
    /// after writes that could affect membership.
    @MainActor
    private func reloadCurrentSessionList() async {
        // Preserve precedence: smart folder > archive > tag > workspace.
        if let folder = state.activeSmartFolder {
            let rows = (try? await repository.sessionsForSmartFolder(folder, limit: 500)) ?? []
            state.sessionsForSelected = rows.map { $0.session }
            state.tagsBySession = Dictionary(uniqueKeysWithValues:
                rows.map { ($0.session.sessionID.description, $0.tags) })
            state.pinnedBySession = Dictionary(uniqueKeysWithValues:
                rows.map { ($0.session.sessionID.description, $0.isPinned) })
            state.customTitleBySession = Dictionary(uniqueKeysWithValues:
                rows.compactMap { r -> (String, String)? in
                    guard let t = r.userMetadata.customTitle else { return nil }
                    return (r.session.sessionID.description, t)
                })
            return
        }
        if state.showingArchive {
            let rows = (try? await repository.archivedSessions(limit: 500)) ?? []
            state.sessionsForSelected = rows.map { $0.session }
            state.tagsBySession = Dictionary(uniqueKeysWithValues:
                rows.map { ($0.session.sessionID.description, $0.tags) })
            state.pinnedBySession = Dictionary(uniqueKeysWithValues:
                rows.map { ($0.session.sessionID.description, $0.isPinned) })
            state.customTitleBySession = Dictionary(uniqueKeysWithValues:
                rows.compactMap { r -> (String, String)? in
                    guard let t = r.userMetadata.customTitle else { return nil }
                    return (r.session.sessionID.description, t)
                })
        } else if let tag = state.activeTag {
            let rows = (try? await repository.sessionsForTag(tag, limit: 500)) ?? []
            state.sessionsForSelected = rows.map { $0.session }
            state.tagsBySession = Dictionary(uniqueKeysWithValues:
                rows.map { ($0.session.sessionID.description, $0.tags) })
            state.pinnedBySession = Dictionary(uniqueKeysWithValues:
                rows.map { ($0.session.sessionID.description, $0.isPinned) })
            state.customTitleBySession = Dictionary(uniqueKeysWithValues:
                rows.compactMap { r -> (String, String)? in
                    guard let t = r.userMetadata.customTitle else { return nil }
                    return (r.session.sessionID.description, t)
                })
        } else if let ws = state.selectedWorkspace {
            let base = (try? await repository.sessions(inWorkspaceID: ws.id)) ?? []
            state.sessionsForSelected = base
            // For the workspace view we hydrate per-session overlays in one
            // batch; small set, cheap per-row reads on the actor.
            var tagsMap: [String: [Tag]] = [:]
            var pinnedMap: [String: Bool] = [:]
            var customMap: [String: String] = [:]
            for s in base {
                if let applied = try? await repository.tags(for: s.sessionID) {
                    tagsMap[s.sessionID.description] = applied
                }
                if let meta = try? await repository.userMetadata(for: s.sessionID) {
                    pinnedMap[s.sessionID.description] = meta.isPinned
                    if let t = meta.customTitle { customMap[s.sessionID.description] = t }
                }
            }
            state.tagsBySession = tagsMap
            state.pinnedBySession = pinnedMap
            state.customTitleBySession = customMap
        } else {
            state.sessionsForSelected = []
            state.tagsBySession = [:]
            state.pinnedBySession = [:]
            state.customTitleBySession = [:]
        }
    }

    /// Refresh pinned + archivedCount + allTags. Called on bootstrap and
    /// after any user-metadata write that could shift those caches.
    @MainActor
    private func reloadUserMetadataOverlays() async {
        async let pinnedTask: [SessionWithMetadata] = (try? await repository.pinnedSessions(limit: 50)) ?? []
        async let archivedCountTask: Int = await fetchArchivedCount()
        async let tagsTask: [Tag] = (try? await repository.allTags()) ?? []
        async let countsTask: [Int64: Int] = await fetchTagCounts()

        state.pinnedSessions = await pinnedTask
        state.archivedCount = await archivedCountTask
        state.allTags = await tagsTask
        state.tagCounts = await countsTask
    }

    private func fetchArchivedCount() async -> Int {
        guard let concrete = repository as? SessionsRepository else { return 0 }
        return (try? await concrete.archivedCount()) ?? 0
    }

    private func fetchTagCounts() async -> [Int64: Int] {
        guard let concrete = repository as? SessionsRepository else { return [:] }
        return (try? await concrete.tagCounts()) ?? [:]
    }

    // MARK: - Smart folders (Plan 07)

    @MainActor
    private func reloadSmartFolders() async {
        state.smartFolders = (try? await repository.smartFolders()) ?? []
    }

    @MainActor
    func reloadSmartFolderCounts() async {
        let counts = (try? await repository.smartFolderCounts()) ?? [:]
        state.smartFolderCounts = counts
    }

    /// 30-second background loop that refreshes `state.smartFolderCounts`.
    /// Started once after bootstrap succeeds.
    @MainActor
    private func startSmartFolderCountsLoop() {
        guard state.bootstrapError == nil else { return }
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30 s
                if Task.isCancelled { return }
                await reloadSmartFolderCounts()
            }
        }
    }

    // MARK: - User metadata actions (wired to the row context menu + preview)

    @MainActor
    func userMeta_togglePin(session: SessionMetadata) {
        let sid = session.sessionID
        Task {
            let currentlyPinned = state.pinnedBySession[sid.description] ?? false
            try? await repository.setPinned(!currentlyPinned, for: sid)
            await reloadUserMetadataOverlays()
            await reloadCurrentSessionList()
            // Refresh selected overlay when the affected session is selected.
            if state.selectedSession?.sessionID == sid {
                state.selectedUserMetadata = try? await repository.userMetadata(for: sid)
            }
            ToastCenter.shared.success(currentlyPinned ? "Unpinned" : "Pinned")
        }
    }

    @MainActor
    func userMeta_archive(session: SessionMetadata) {
        Task {
            try? await repository.setArchived(true, for: session.sessionID)
            await reloadUserMetadataOverlays()
            await reloadCurrentSessionList()
            if state.selectedSession?.sessionID == session.sessionID {
                state.selectedSession = nil
                state.selectedUserMetadata = nil
                state.selectedTags = []
            }
            ToastCenter.shared.successWithUndo("Archived") { [self] in
                Task {
                    try? await repository.setArchived(false, for: session.sessionID)
                    await reloadUserMetadataOverlays()
                    await reloadCurrentSessionList()
                    ToastCenter.shared.info("Archive undone")
                }
            }
        }
    }

    @MainActor
    func userMeta_moveToTrash(session: SessionMetadata) {
        Task {
            try? await repository.softDelete(session.sessionID, workspaceID: session.workspaceID)
            await reloadUserMetadataOverlays()
            await reloadCurrentSessionList()
            if state.selectedSession?.sessionID == session.sessionID {
                state.selectedSession = nil
                state.selectedUserMetadata = nil
                state.selectedTags = []
            }
            ToastCenter.shared.successWithUndo("Moved to Trash") { [self] in
                Task {
                    try? await repository.undelete(session.sessionID)
                    await reloadUserMetadataOverlays()
                    await reloadCurrentSessionList()
                    ToastCenter.shared.info("Restored from Trash")
                }
            }
        }
    }

    @MainActor
    func userMeta_commitRename(session: SessionMetadata, title: String?) {
        Task {
            try? await repository.setCustomTitle(title, for: session.sessionID)
            await reloadCurrentSessionList()
            if state.selectedSession?.sessionID == session.sessionID {
                state.selectedUserMetadata = try? await repository.userMetadata(for: session.sessionID)
            }
            state.renamingSessionID = nil
            state.renamingDraft = ""
        }
    }

    @MainActor
    func userMeta_saveNote(session: SessionMetadata, note: String?) {
        Task {
            try? await repository.setNote(note, for: session.sessionID)
            if state.selectedSession?.sessionID == session.sessionID {
                state.selectedUserMetadata = try? await repository.userMetadata(for: session.sessionID)
            }
            state.notingSessionID = nil
        }
    }

    @MainActor
    func userMeta_setTags(session: SessionMetadata, tagIDs: [Int64]) {
        Task {
            try? await repository.setTags(tagIDs, for: session.sessionID)
            state.allTags = (try? await repository.allTags()) ?? state.allTags
            state.tagCounts = await fetchTagCounts()
            await reloadCurrentSessionList()
            if state.selectedSession?.sessionID == session.sessionID {
                state.selectedTags = (try? await repository.tags(for: session.sessionID)) ?? []
            }
        }
    }

    @MainActor
    func userMeta_renameTag(id: Int64, to newName: String) async {
        do {
            try await repository.renameTag(id, to: newName)
            state.allTags = (try? await repository.allTags()) ?? state.allTags
            state.tagCounts = await fetchTagCounts()
            await reloadCurrentSessionList()
            ToastCenter.shared.success("Renamed tag")
        } catch let err as SessionsRepository.TagError {
            ToastCenter.shared.error(err.errorDescription ?? "Tag rename failed")
        } catch {
            ToastCenter.shared.error("Tag rename failed")
        }
    }

    @MainActor
    func userMeta_deleteTag(id: Int64) async {
        do {
            try await repository.deleteTag(id)
            state.allTags = (try? await repository.allTags()) ?? state.allTags
            state.tagCounts = await fetchTagCounts()
            // If the active tag scope was the one we just removed, drop it.
            if state.activeTag?.id == id { state.activeTag = nil }
            await reloadCurrentSessionList()
            if let session = state.selectedSession {
                state.selectedTags = (try? await repository.tags(for: session.sessionID)) ?? []
            }
            ToastCenter.shared.success("Deleted tag")
        } catch {
            ToastCenter.shared.error("Tag delete failed")
        }
    }

    @MainActor
    func userMeta_createTag(name: String, colorHue: Int) async -> Tag? {
        do {
            let tag = try await repository.createTag(name: name, colorHue: colorHue)
            state.allTags = (try? await repository.allTags()) ?? (state.allTags + [tag])
            return tag
        } catch let err as SessionsRepository.TagError {
            ToastCenter.shared.error(err.errorDescription ?? "Tag error")
            return nil
        } catch {
            ToastCenter.shared.error("Failed to create tag")
            return nil
        }
    }

    // MARK: - Search wiring

    @MainActor
    private func scheduleSearch() {
        // Cancel any previously-pending debounce task. A fresh keystroke
        // supersedes any earlier in-flight one.
        state.cancelPendingSearch()

        // If the user just cleared everything, drop back to workspace view immediately.
        if !state.isSearching {
            state.searchResults = []
            state.searchState = .idle
            return
        }

        // Kick off a new debounced search. We capture `state` + `repository`
        // explicitly ,  `state` is a class (shared instance), `repository` is
        // Sendable, and the Task inherits the main-actor context from our
        // surrounding @MainActor function.
        let repo = repository
        state.searchDebounceTask = Task { @MainActor [weak state] in
            try? await Task.sleep(nanoseconds: 180_000_000) // 180 ms
            if Task.isCancelled { return }
            guard let state else { return }
            await state.runSearch(using: repo)
        }
    }

    private var hairline: some View {
        Rectangle().fill(Theme.Color.rule).frame(height: 1)
    }

    // MARK: - Indexing banner

    private func indexingBanner(progress: Double) -> some View {
        HStack(spacing: 10) {
            Text("Building search index…")
                .font(Theme.Font.mono)
                .foregroundStyle(Color.black.opacity(0.85))
            Text("\(Int(progress * 100))%")
                .font(Theme.Font.mono(size: 11, wght: 500))
                .foregroundStyle(Color.black.opacity(0.85))
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Color.accent)
    }

    // MARK: - Bootstrap banners

    private var warningsBanner: some View {
        HStack(spacing: 8) {
            Text("⚠ \(state.bootstrapWarnings.count) indexing warning(s) during bootstrap.")
                .font(Theme.Font.mono)
                .foregroundStyle(Color.black.opacity(0.85))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Spacer()
            Button("Show all (\(state.bootstrapWarnings.count))") {
                showAllWarnings = true
            }
            .font(Theme.Font.mono)
            .foregroundStyle(Color.black.opacity(0.75))
            .padding(.trailing, 12)
            .popover(isPresented: $showAllWarnings) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(state.bootstrapWarnings.enumerated()), id: \.offset) { _, msg in
                            Text(msg)
                                .font(Theme.Font.mono)
                                .foregroundStyle(Theme.Color.text)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(16)
                }
                .frame(minWidth: 520, minHeight: 200)
                .background(Theme.Color.bg)
            }
        }
        .frame(maxWidth: .infinity)
        .background(Color.yellow.opacity(0.85))
    }

    private func errorBanner(_ err: String) -> some View {
        HStack {
            Text("⚠ Bootstrap error: \(err)")
                .font(Theme.Font.mono)
                .foregroundStyle(Color.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Theme.Color.accent)
    }
}

