import SwiftUI
import Observation

@MainActor
@Observable
public final class AppState {
    // MARK: - Multi-provider (v0.2)

    /// UserDefaults key for the persisted active-provider selection.
    /// Read at app launch, written every time `switchTo(_:)` succeeds.
    public static let activeProviderDefaultsKey = "chronicle.activeProvider"

    /// Provider whose data is currently surfaced by every list, count,
    /// and stat. Defaults to `.claude` on first v0.2 launch regardless of
    /// which providers are detected — least-surprise for v0.1.x users.
    /// `loadActiveProviderFromDefaults()` overwrites this from
    /// UserDefaults during app boot.
    public var activeProvider: ProviderID = .claude

    /// Set of providers whose first-time bootstrap has completed in this
    /// install. Switching to a provider not in this set triggers the
    /// bootstrap splash; switching back to one already here is instant.
    /// Persisted across launches so the splash isn't shown twice.
    public var bootstrappedProviders: Set<ProviderID> = []

    /// Providers detected as installed/usable on this machine, in
    /// canonical order. Populated once during app boot from the
    /// `ProviderRegistry`. The segmented control + menubar tile grid
    /// render only these, in this order.
    public var availableProviders: [ProviderID] = [.claude]

    public var workspaces: [Workspace] = []
    public var selectedWorkspace: Workspace?

    /// Set of workspace-parent-group names (e.g. "StealthZero", "apps") that
    /// the user has manually expanded in the sidebar. Groups with <= 3
    /// workspaces default to expanded implicitly; groups with more collapse
    /// until the user opens them.
    public var expandedWorkspaceGroups: Set<String> = []
    public var sessionsForSelected: [SessionMetadata] = []
    public var selectedSession: SessionMetadata?
    public var bootstrapError: String?
    public var bootstrapWarnings: [String] = []

    // MARK: - Bootstrap progress (Bug 5)

    /// Fraction [0, 1] of bootstrap work completed; 0 while the FS scan
    /// runs, moves monotonically toward 1 as workspaces finish indexing.
    /// nil means "not started" or "completed" (callers should show the
    /// real UI once nil again).
    public var bootstrapProgress: Double? = nil

    /// Human-readable status like "Scanning ~/.claude/projects" or
    /// "Indexed 120 of 340 workspaces". Updated alongside
    /// `bootstrapProgress`. Empty string during idle.
    public var bootstrapStatus: String = ""

    /// True during the indexing pass so the ChronicleApp bootstrap overlay
    /// stays on-screen until the initial scan completes. Flipped to false
    /// by AppView's `.task` when the first workspace list arrives.
    public var isBootstrapping: Bool = true

    // MARK: - Search state

    /// Raw text from the global search bar.
    public var searchQuery: String = ""

    /// Raw text from the per-workspace filter row (client-side title substring match).
    public var listFilter: String = ""

    /// Results of the most recent `repository.search(...)` invocation.
    public var searchResults: [SessionMetadata] = []

    /// Lifecycle of the current search request.
    public enum SearchState: Equatable {
        case idle
        case loading
        case indexing(Double)   // 0.0 ... 1.0
        case ready              // results delivered, list is showing them
        case error(String)
    }
    public var searchState: SearchState = .idle

    /// Active time-window pill (nil = pill inactive). Toggled by "Last 30 days" button.
    public var activeTimeWindow: SearchQuery.TimeWindow? = nil

    /// When true, searches span every workspace (default). When false, they
    /// limit to `selectedWorkspace`, effectively an implicit `/in:<ws>` clause.
    public var showAllWorkspaces: Bool = true

    /// True when any search-bar signal is active and the list should show
    /// `searchResults` rather than `sessionsForSelected`.
    public var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || activeTimeWindow != nil
            || !showAllWorkspaces
    }

    /// When the repository last finished a bootstrap scan. Used to drive the
    /// "indexed Xs ago" readout in the title bar.
    public var lastIndexedAt: Date?

    // MARK: - Terminal launcher state (Plan 03)

    /// Terminals that appear to be installed on this machine. Populated at
    /// bootstrap from `Terminal.installed()`. The action-bar menu uses this
    /// to decide which rows to render.
    public var availableTerminals: [Terminal] = []

    /// User's default terminal, loaded from `TerminalPreference` at startup
    /// and updated whenever "Set as default" is invoked from the menu.
    public var defaultTerminal: Terminal = .terminal

    /// Per-session override for the currently-selected session. `nil` means
    /// the session uses `defaultTerminal`. Reloaded when `selectedSession`
    /// changes; written when the user picks a new terminal from the menu.
    public var overrideForSelected: Terminal?

    /// The terminal that the `Resume in <name>` button will actually launch
    /// when clicked; override wins, falling back to the default.
    public var resolvedTerminalForSelected: Terminal {
        overrideForSelected ?? defaultTerminal
    }

    // MARK: - User metadata (Plan 06)

    /// Cached pinned sessions for the sidebar Pinned section. Refreshed on
    /// bootstrap and after any write that changes pin state.
    public var pinnedSessions: [SessionWithMetadata] = []

    /// Total number of archived (non-deleted) sessions; drives the sidebar
    /// `Archive (N)` header.
    public var archivedCount: Int = 0

    /// All tags in the catalogue, ordered by name ascending.
    public var allTags: [Tag] = []

    /// Count of sessions per tag id, used to render the tag row totals.
    public var tagCounts: [Int64: Int] = [:]

    /// When non-nil, the session list shows sessions tagged with this tag
    /// (all workspaces). Setting this clears `showingArchive`.
    public var activeTag: Tag? = nil

    /// When true, the session list shows every archived session across
    /// workspaces (read-only). Setting this clears `activeTag`.
    public var showingArchive: Bool = false

    /// Per-session user metadata for whichever session is currently selected.
    /// Refreshed whenever `selectedSession` changes. Defaults to `.empty(for:)`
    /// when there's no user_metadata row yet.
    public var selectedUserMetadata: UserMetadata? = nil

    /// Tags applied to the currently-selected session. Refreshed when the
    /// selection changes or after `setTags(...)` writes.
    public var selectedTags: [Tag] = []

    /// Precomputed per-session tag maps for the session list so rows don't
    /// need async reads. Populated alongside `sessionsForSelected`.
    public var tagsBySession: [String: [Tag]] = [:]

    /// Precomputed per-session pin-state overlays. `true` means render a coral
    /// star at the leading edge.
    public var pinnedBySession: [String: Bool] = [:]

    /// Precomputed per-session custom-title overrides (for renderers that
    /// need to show the original title alongside).
    public var customTitleBySession: [String: String] = [:]

    /// Lightweight toast channel for user-metadata feedback ("Archived",
    /// "Moved to Trash"). UI strips it after a few seconds. Plan 08 will
    /// replace this with a real toast component.
    public var toasts: [String] = []

    /// Session id whose row is currently in inline-rename mode. Nil = no row.
    public var renamingSessionID: SessionID? = nil

    /// Buffer for the inline-rename TextField. Reset when rename begins.
    public var renamingDraft: String = ""

    /// Session id whose note editor sheet is open. Nil = no sheet.
    public var notingSessionID: SessionID? = nil

    /// Session id whose tag picker popover is open. Nil = closed.
    public var taggingSessionID: SessionID? = nil

    // MARK: - Live sessions + Smart folders (Plan 07)

    /// Sessions the LiveSessionsWatcher currently reports as active (backed
    /// by `ps`/`lsof` probing every 2s). UI uses the session IDs as a
    /// fast-lookup set when rendering the "live" green pulse.
    public var liveSessions: [SessionMetadata] = []

    /// Convenience set of live session IDs for rendering.
    public var liveSessionIDs: Set<String> {
        Set(liveSessions.map { $0.sessionID.description })
    }

    /// Persisted + built-in Smart Folders rendered by the sidebar.
    public var smartFolders: [SmartFolder] = []

    /// Matching-session count per smart folder id. Updated after bootstrap,
    /// after watcher deliveries, and every 30 s in the background.
    public var smartFolderCounts: [Int64: Int] = [:]

    /// When non-nil, the session list shows the smart-folder's sessions
    /// instead of the workspace / tag / archive view. Setting this clears
    /// `activeTag` + `showingArchive`.
    public var activeSmartFolder: SmartFolder? = nil

    // MARK: - Tab switcher (Plan 08)

    /// Top-level tab in the main window. `sessions` = the 3-pane layout;
    /// `stats` = the Stats dashboard (totals + per-project + heatmaps).
    public enum MainTab: Equatable {
        case sessions
        case stats
    }
    public var mainTab: MainTab = .sessions

    // MARK: - Stats data (Plan 08)

    /// Per-workspace totals powering the Stats view. Refreshed on demand
    /// when the user switches into the `.stats` tab.
    public var workspaceStats: [WorkspaceStats] = []

    /// Global totals shown in the Stats header card row.
    public var totals: (sessions: Int, tokens: Int, estimatedCostUSD: Double) = (0, 0, 0)

    /// 24×7 heatmap for last 90 days of activity.
    public var hourWeekdayHeatmap: [HeatmapCell] = []

    /// 90-day calendar heatmap (oldest → newest).
    public var calendarHeatmap: [CalendarHeatmapCell] = []

    /// Per-model token + cost breakdown shown in the Stats header. Tuples
    /// because we don't need a richer struct yet; model name, sum of
    /// tokens, sum of estimated cost in USD.
    public struct ModelBreakdown: Equatable, Hashable, Sendable {
        public var model: String
        public var tokens: Int
        public var cost: Double
        public init(model: String, tokens: Int, cost: Double) {
            self.model = model; self.tokens = tokens; self.cost = cost
        }
    }
    public var modelBreakdown: [ModelBreakdown] = []

    /// True while Stats queries are in flight. Used to toggle a simple
    /// loading state so the Stats view doesn't flash empty cards.
    public var statsLoading: Bool = false

    // MARK: - Transcript presentation (Plan 05)

    /// When non-nil, a full-window `TranscriptView` overlays the 3-pane
    /// body. Set by `openTranscript(for:)`; cleared when the user hits
    /// the `← back` button inside the transcript. Kept as a session
    /// rather than a SessionID so the view can show the title + workspace
    /// while the transcript body loads.
    public var transcriptSession: SessionMetadata? = nil

    /// The most recently loaded transcript. `nil` while loading or when
    /// `transcriptSession` is nil. Updated by the TranscriptView's `.task`
    /// block so AppState doesn't need to depend on TranscriptRepository.
    public var loadedTranscript: Transcript? = nil

    /// True once the TranscriptView's `.task` has finished a load (success
    /// or error); differentiates "loading…" from "loaded but empty".
    public var transcriptLoadError: String? = nil

    // MARK: - Preview stats (Bug 4 — eager-load on selection)

    /// Lightweight transcript stats for the currently-selected session,
    /// eagerly loaded when the selection changes. Populated
    /// asynchronously by `loadPreviewStats(for:from:)`. Cleared to nil while
    /// a new load is in flight or when selection goes away.
    public var previewStats: Transcript.Stats? = nil

    /// SessionID for which `previewStats` was last loaded. Used to gate
    /// reads; if the user switched selection before the parse finished,
    /// we drop the stale result on the floor.
    public var previewStatsSessionID: SessionID? = nil

    /// True while an eager transcript parse is in flight for the current
    /// selection. UI uses this to show "Loading…" rather than "—".
    public var previewStatsLoading: Bool = false

    /// In-flight eager-preview parse; cancelled whenever selection changes.
    public var previewStatsTask: Task<Void, Never>? = nil

    public init() {}

    // MARK: - Search execution (testable)

    /// Debounce handle for the search task. Public so callers (AppView) can
    /// cancel any in-flight search when the user clears the input.
    public var searchDebounceTask: Task<Void, Never>? = nil

    /// Build a SearchQuery from current AppState (searchQuery text + active
    /// time window + workspace scope). Extracted so it can be unit-tested
    /// without touching the repository.
    public func composeSearchQuery() -> SearchQuery {
        var query = SearchQueryParser.parse(searchQuery)
        if let window = activeTimeWindow {
            query.timeWindow = window
        }
        // When the user explicitly narrowed to the current workspace, inject
        // an implicit `/in:<workspace-display-name>` clause. We match on the
        // displayName via LIKE in the repo.
        if !showAllWorkspaces,
           let ws = selectedWorkspace,
           query.workspaces.isEmpty {
            query.workspaces.append(ws.displayName)
        }
        return query
    }

    /// Execute a search against `repository` and publish results to
    /// `searchResults` / `searchState`. Extracted from AppView so tests can
    /// exercise the full pipeline (parse → compose → search → publish).
    /// Safe to call from any actor; hops to MainActor when mutating state.
    public func runSearch(using repository: any SessionsReadProtocol) async {
        let query = composeSearchQuery()

        if query.isEmpty {
            searchResults = []
            searchState = .idle
            return
        }

        searchState = query.needsFullText ? .indexing(0.0) : .loading
        do {
            let results = try await repository.search(query: query)
            if Task.isCancelled { return }
            searchResults = results
            searchState = .ready
        } catch is CancellationError {
            // ignore; a newer search already superseded us
        } catch {
            searchState = .error(error.localizedDescription)
        }
    }

    /// Cancel any in-flight debounce task. Called when searchQuery clears or
    /// when the view goes away.
    public func cancelPendingSearch() {
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
    }

    /// Present the transcript view for a session. The TranscriptView's
    /// `.task` modifier does the actual jsonl read + parse.
    public func openTranscript(for session: SessionMetadata) {
        transcriptSession = session
        loadedTranscript = nil
        transcriptLoadError = nil
    }

    /// Dismiss the transcript view (triggered by the `← back` button).
    public func closeTranscript() {
        transcriptSession = nil
        loadedTranscript = nil
        transcriptLoadError = nil
    }

    /// Kick off an eager transcript parse for the given session so the
    /// preview pane can show real Files touched / Tools used / Messages
    /// split / token breakdown instead of `—`. Cancels any previous
    /// in-flight parse. Safe to call from MainActor.
    public func loadPreviewStats(
        for session: SessionMetadata,
        from repo: TranscriptRepository
    ) {
        previewStatsTask?.cancel()
        previewStats = nil
        previewStatsSessionID = nil
        previewStatsLoading = true

        let targetID = session.sessionID
        let workspaceID = session.workspaceID

        previewStatsTask = Task { @MainActor [weak self] in
            do {
                try Task.checkCancellation()
                let t = try await repo.transcript(
                    forSessionID: targetID,
                    workspaceID: workspaceID
                )
                try Task.checkCancellation()
                guard let self else { return }
                // Only publish if the selection hasn't changed.
                guard self.selectedSession?.sessionID == targetID else { return }
                self.previewStats = t.stats
                self.previewStatsSessionID = targetID
                self.previewStatsLoading = false
            } catch {
                guard let self else { return }
                if self.selectedSession?.sessionID == targetID {
                    self.previewStatsLoading = false
                }
            }
        }
    }

    /// Clear preview-stat caches (e.g. when selection goes to nil).
    public func clearPreviewStats() {
        previewStatsTask?.cancel()
        previewStatsTask = nil
        previewStats = nil
        previewStatsSessionID = nil
        previewStatsLoading = false
    }

    public func select(workspace: Workspace) {
        selectedWorkspace = workspace
        selectedSession = nil
        sessionsForSelected = []
    }

    public func select(session: SessionMetadata) {
        selectedSession = session
    }

    // MARK: - Derived readouts (for the title bar / list header)

    /// Rough "N projects" count = distinct top-level workspace group.
    public var projectCount: Int {
        Set(workspaces.map { $0.group }).count
    }

    /// Whole-number seconds since `lastIndexedAt`, or nil if we haven't indexed yet.
    public var indexedSecondsAgo: Int? {
        guard let last = lastIndexedAt else { return nil }
        return max(0, Int(Date().timeIntervalSince(last)))
    }

    /// Sum of `messageCount` as a convenient metric for the list header.
    public var selectedMessageTotal: Int {
        sessionsForSelected.reduce(0) { $0 + $1.messageCount }
    }

    /// Sessions in the selected workspace modified within the last 7 days.
    public var activeThisWeekCount: Int {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        return sessionsForSelected.filter { $0.lastModifiedAt >= cutoff }.count
    }

    /// Total tokens across the selected workspace's sessions.
    public var selectedTokenTotal: Int {
        sessionsForSelected.reduce(0) { $0 + $1.tokenCount }
    }

    // MARK: - Derived session list (what SessionListView actually displays)

    /// The sessions to render in the middle pane. When the user is actively
    /// searching, this is `searchResults` filtered by the per-workspace
    /// `listFilter`. Otherwise it's `sessionsForSelected` filtered the same way.
    public var displayedSessions: [SessionMetadata] {
        let base: [SessionMetadata]
        if isSearching {
            base = searchResults
        } else {
            // Archive mode + tag filter both substitute for the default
            // workspace list; both populate sessionsForSelected themselves
            // when activated via the sidebar so we don't need a separate array.
            base = sessionsForSelected
        }
        return Self.applyListFilter(listFilter, to: base)
    }

    /// Distinct workspace IDs present in `displayedSessions`, used for the
    /// "N matches across W workspaces" meta row.
    public var displayedWorkspaceCount: Int {
        Set(displayedSessions.map(\.workspaceID)).count
    }

    internal static func applyListFilter(_ raw: String, to sessions: [SessionMetadata]) -> [SessionMetadata] {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return sessions }
        return sessions.filter { $0.title.lowercased().contains(q) }
    }

    // MARK: - Active provider persistence (v0.2)

    /// UserDefaults key for the persisted bootstrappedProviders set.
    /// Stored as `[String]` (rawValues) so older Chronicle builds don't
    /// fail to decode.
    public static let bootstrappedProvidersDefaultsKey = "chronicle.bootstrappedProviders"

    /// Read the persisted active-provider selection (and bootstrap-set
    /// memory) from UserDefaults. Called once at app launch so the user
    /// returns to whichever provider they last had open.
    /// `defaults` is injectable for tests.
    public func loadActiveProviderFromDefaults(_ defaults: UserDefaults = .standard) {
        if let raw = defaults.string(forKey: Self.activeProviderDefaultsKey),
           let parsed = ProviderID(rawValue: raw) {
            activeProvider = parsed
        }
        if let raws = defaults.array(forKey: Self.bootstrappedProvidersDefaultsKey) as? [String] {
            bootstrappedProviders = Set(raws.compactMap(ProviderID.init(rawValue:)))
        }
    }

    /// Persist the current `activeProvider` and `bootstrappedProviders`
    /// to UserDefaults. Called from `switchTo(_:)` and after the first
    /// bootstrap of a new provider completes.
    public func saveActiveProviderToDefaults(_ defaults: UserDefaults = .standard) {
        defaults.set(activeProvider.rawValue, forKey: Self.activeProviderDefaultsKey)
        defaults.set(
            bootstrappedProviders.map(\.rawValue).sorted(),
            forKey: Self.bootstrappedProvidersDefaultsKey
        )
    }

    /// Switch the segmented control / menubar tile selection to a
    /// different provider. The view layer rebinds `activeProvider`,
    /// the repository swaps its internal provider scope, and any
    /// open async work is cancelled before reload tasks start.
    ///
    /// `repository` and `reload` are passed in by the caller so the
    /// AppState type doesn't have to know about SessionsRepository
    /// directly (keeps it testable in isolation). The runtime path
    /// from AppView calls this with the live repo and the existing
    /// reloadAll(...) task.
    public func switchTo(
        _ providerID: ProviderID,
        repository: (any SessionsRepositoryProtocol)? = nil,
        reload: (@Sendable () -> Void)? = nil
    ) {
        guard providerID != activeProvider else { return }
        guard availableProviders.contains(providerID) else { return }

        // Cancel anything tied to the previous provider — search,
        // preview-stat parses, debounced operations.
        cancelPendingSearch()
        clearPreviewStats()

        activeProvider = providerID
        saveActiveProviderToDefaults()

        // The repository's internal scope flips before any reloads
        // run so the very next read returns the new provider's data.
        if let repo = repository as? SessionsRepository {
            Task { await repo.setActiveProvider(providerID) }
        }

        reload?()
    }

    /// Lightweight overload used from `ProviderSwitcher.button` where
    /// the AppState doesn't carry the repository. AppView wires in the
    /// real switchTo via `.environment(\.providerSwitcher, …)` style;
    /// for now the button-driven path just sets the field, and the
    /// ChronicleApp init-bound observer kicks the reload.
    public func switchTo(_ providerID: ProviderID) {
        switchTo(providerID, repository: nil, reload: nil)
    }
}
