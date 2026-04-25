import Foundation
import Observation

/// State backing the menubar dropdown.
///
/// Intentionally separate from `AppState` so the menubar doesn't have to
/// carry the main-window's sidebar / preview / filter state. The main window
/// and menubar can both be open simultaneously; keeping their stores apart
/// means a search in one doesn't clobber selection in the other.
@Observable
@MainActor
public final class MenubarModel {
    // MARK: - Inputs

    /// Raw text from the dropdown's search field.
    public var query: String = ""

    // MARK: - Sections (cached from the repository)

    /// Currently-running sessions (last_modified within the live window).
    public var liveSessions: [SessionMetadata] = []

    /// Sessions modified in the last 7 days, capped at 5 for the dropdown.
    public var recentSessions: [SessionMetadata] = []

    /// Pinned sessions. Plan 06 wires storage; stub empty for now.
    public var pinnedSessions: [SessionMetadata] = []

    /// Results of the most-recent live search (debounced in the view).
    public var searchResults: [SessionMetadata] = []

    /// Total non-deleted, non-archived session count for the search placeholder.
    public var totalSessionCount: Int = 0

    // MARK: - Keyboard selection

    /// Index into `visibleRows` of the currently-selected row. Clamped on
    /// every reload so the selection never points past the end of the list.
    public var selectedIndex: Int = 0

    // MARK: - Derived

    /// True when the user has typed into the search field. Collapses the
    /// Live/Recent/Pinned layout into a single Results list.
    public var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The flat ordered list of rows the dropdown currently renders. Keyboard
    /// shortcuts (↑↓, ⌘N, ⏎) operate against this list.
    public var visibleRows: [SessionMetadata] {
        isSearching
            ? searchResults
            : (liveSessions + recentSessions + pinnedSessions)
    }

    // MARK: - Init

    public init() {}

    // MARK: - Loaders

    /// Refreshes the three cached sections from `repo`. Called on open and
    /// after `⌘⇧O` toggles the popover visible. Errors are swallowed; the
    /// menubar is a best-effort projection of state, and the main window shows
    /// the authoritative bootstrap errors.
    public func reload(from repo: any SessionsReadProtocol & WorkspaceRepositoryProtocol & UserMetadataRepositoryProtocol) async {
        let live = (try? await repo.liveSessions()) ?? []
        let recent = (try? await repo.recentSessions(days: 7, limit: 5)) ?? []
        let pinned = (try? await repo.pinnedSessions(limit: 5)) ?? []
        let total = (try? await repo.totalSessionCount()) ?? 0
        self.totalSessionCount = total
        self.liveSessions = live
        // Drop any session from "recent" that's already visible in "live";
        // otherwise the same row appears twice and the ⌘N shortcut collides.
        let liveIDs = Set(live.map(\.sessionID))
        self.recentSessions = recent.filter { !liveIDs.contains($0.sessionID) }
        // `pinnedSessions` on the protocol returns SessionWithMetadata (Plan 06),
        // but the menubar renders the base SessionMetadata rows. Flatten.
        self.pinnedSessions = pinned.map(\.session)
        clampSelection()
    }

    /// Runs a repository search using the current `query`. Caller is
    /// responsible for debouncing.
    public func runSearch(using repo: any SessionsReadProtocol) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            self.searchResults = []
            clampSelection()
            return
        }
        let parsed = SearchQueryParser.parse(trimmed)
        if parsed.isEmpty {
            self.searchResults = []
            clampSelection()
            return
        }
        let results = (try? await repo.search(query: parsed)) ?? []
        // Dropdown shows first 8 matches; the rest are available via "Open full window →".
        self.searchResults = Array(results.prefix(8))
        clampSelection()
    }

    // MARK: - Helpers

    /// Keeps `selectedIndex` inside the bounds of `visibleRows`. Called after
    /// every data change; avoids `⏎ launch` crashing on a stale index.
    public func clampSelection() {
        let rows = visibleRows
        if rows.isEmpty {
            selectedIndex = 0
            return
        }
        if selectedIndex < 0 {
            selectedIndex = 0
        } else if selectedIndex >= rows.count {
            selectedIndex = rows.count - 1
        }
    }

    /// Moves the selection up or down in the visible list, clamped.
    public func moveSelection(by delta: Int) {
        let rows = visibleRows
        guard !rows.isEmpty else { return }
        let next = max(0, min(rows.count - 1, selectedIndex + delta))
        selectedIndex = next
    }

    /// Returns the currently-selected session, if any.
    public var selectedSession: SessionMetadata? {
        let rows = visibleRows
        guard !rows.isEmpty, selectedIndex >= 0, selectedIndex < rows.count else { return nil }
        return rows[selectedIndex]
    }
}
