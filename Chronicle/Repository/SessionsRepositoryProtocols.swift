import Foundation

// MARK: - Interface-segregated sub-protocols
//
// R1 of the SOLID refactor splits the (formerly) ~30-method
// `SessionsRepositoryProtocol` into focused surfaces. Each sub-protocol
// describes ONE collaborator concern (workspaces, session reads, tags,
// smart folders, user metadata) so callers can declare the narrowest
// dependency they actually use.
//
// The single concrete `SessionsRepository` actor (defined in
// `SessionsRepository.swift`) continues to conform to the full composite
//; transactional integrity is unchanged. We do NOT split the
// implementation here.

// MARK: - WorkspaceRepositoryProtocol

/// Workspace-level reads. The bootstrap entry point lives here too because
/// it's the only "workspace mutation" the app surface exposes.
public protocol WorkspaceRepositoryProtocol: Sendable {
    func bootstrap(rootURL: URL) async throws

    /// Progress-reporting bootstrap overload. The closure is invoked on
    /// indexing-progress callbacks (`fraction`, human-readable status); pass
    /// `nil` for the no-progress behavior. The callback is `@Sendable` so it
    /// can hop to `@MainActor` safely from the actor's executor.
    func bootstrap(rootURL: URL,
                   progress: (@Sendable (_ fraction: Double, _ message: String) -> Void)?) async throws

    func allWorkspaces() async throws -> [Workspace]

    /// Total non-deleted, non-archived session count across all workspaces.
    /// Used by the menubar placeholder ("Search 3,116 sessions…").
    func totalSessionCount() async throws -> Int
}

public extension WorkspaceRepositoryProtocol {
    /// Default routes the no-progress overload through the progress overload
    /// with `nil`, so concrete types only need to implement the progress
    /// variant. The composite concrete type may still override either.
    func bootstrap(rootURL: URL) async throws {
        try await bootstrap(rootURL: rootURL, progress: nil)
    }

    /// Default no-op progress overload so existing test stubs that only
    /// implement `bootstrap(rootURL:)` keep compiling. The real
    /// `SessionsRepository` overrides this.
    func bootstrap(rootURL: URL,
                   progress: (@Sendable (_ fraction: Double, _ message: String) -> Void)?) async throws {
        try await bootstrap(rootURL: rootURL)
    }
}

// MARK: - SessionsReadProtocol

/// Read-only session lookup surface. The menubar + sidebar consume this;
/// nothing here mutates state.
public protocol SessionsReadProtocol: Sendable {
    func sessions(inWorkspaceID id: String) async throws -> [SessionMetadata]
    func allSessions(limit: Int) async throws -> [SessionMetadata]
    func search(query: SearchQuery) async throws -> [SessionMetadata]

    /// Returns up to `limit` sessions modified within the last `days` days,
    /// ordered by `last_modified_at DESC`. Used by the menubar's "Recent" list.
    func recentSessions(days: Int, limit: Int) async throws -> [SessionMetadata]

    /// Returns sessions whose `last_modified_at` is within the live-window
    /// (60 s by default) as a proxy for "currently running". `isLive` is set
    /// to `true` on every returned row.
    func liveSessions() async throws -> [SessionMetadata]
}

// MARK: - TagsRepositoryProtocol

/// Tag CRUD + tag-driven session listing. Anything that talks tags goes here.
public protocol TagsRepositoryProtocol: Sendable {
    func allTags() async throws -> [Tag]
    func tags(for sessionID: SessionID) async throws -> [Tag]
    func createTag(name: String, colorHue: Int) async throws -> Tag
    func renameTag(_ id: Int64, to name: String) async throws
    func deleteTag(_ id: Int64) async throws
    func setTags(_ tagIDs: [Int64], for sessionID: SessionID) async throws

    /// Returns sessions tagged with the given tag. Excludes deleted + archived
    /// by default.
    func sessionsForTag(_ tag: Tag, limit: Int) async throws -> [SessionWithMetadata]
}

// MARK: - SmartFolderRepositoryProtocol

/// Smart-folder CRUD + saved-query session listing.
public protocol SmartFolderRepositoryProtocol: Sendable {
    func smartFolders() async throws -> [SmartFolder]
    func createSmartFolder(name: String, query: SmartFolderQuery) async throws -> SmartFolder
    func renameSmartFolder(_ id: Int64, to name: String) async throws
    func deleteSmartFolder(_ id: Int64) async throws
    func sessionsForSmartFolder(_ folder: SmartFolder, limit: Int) async throws -> [SessionWithMetadata]
    func smartFolderCounts() async throws -> [Int64: Int]
}

// MARK: - UserMetadataRepositoryProtocol

/// Per-session user metadata: pin, archive, custom title, note, soft-delete.
public protocol UserMetadataRepositoryProtocol: Sendable {
    func userMetadata(for sessionID: SessionID) async throws -> UserMetadata

    /// Returns up to `limit` pinned sessions (all workspaces), ordered by
    /// `user_metadata.updated_at DESC`. Excludes deleted and archived rows.
    func pinnedSessions(limit: Int) async throws -> [SessionWithMetadata]

    /// Returns up to `limit` archived sessions (all workspaces), ordered by
    /// `user_metadata.updated_at DESC`. Excludes deleted rows.
    func archivedSessions(limit: Int) async throws -> [SessionWithMetadata]

    /// Number of archived (non-deleted) sessions. Drives the sidebar's
    /// "Archived (N)" badge.
    func archivedCount() async throws -> Int

    func setPinned(_ pinned: Bool, for sessionID: SessionID) async throws
    func setArchived(_ archived: Bool, for sessionID: SessionID) async throws
    func setNote(_ note: String?, for sessionID: SessionID) async throws
    func setCustomTitle(_ title: String?, for sessionID: SessionID) async throws
    func softDelete(_ sessionID: SessionID, workspaceID: String?) async throws
    func undelete(_ sessionID: SessionID) async throws
}
