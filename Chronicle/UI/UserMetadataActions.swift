import SwiftUI

/// A thin dispatcher wired up by `AppView` and passed down the view tree via
/// `@Environment`. Child views call these closures to perform user-metadata
/// writes without needing a reference to the repository themselves. The
/// closures close over AppState + the SessionsRepositoryProtocol so they can
/// refresh caches after each write.
public struct UserMetadataActions {
    public var togglePin: @MainActor (SessionMetadata) -> Void
    public var archive: @MainActor (SessionMetadata) -> Void
    public var moveToTrash: @MainActor (SessionMetadata) -> Void
    public var beginRename: @MainActor (SessionMetadata) -> Void
    public var commitRename: @MainActor (SessionMetadata, String?) -> Void
    public var openNote: @MainActor (SessionMetadata) -> Void
    public var saveNote: @MainActor (SessionMetadata, String?) -> Void
    public var openTagPicker: @MainActor (SessionMetadata) -> Void
    public var setTags: @MainActor (SessionMetadata, [Int64]) -> Void
    public var createTag: @MainActor (String, Int) async -> Tag?
    /// Rename an existing tag. Implementations cascade through `session_tags`
    /// automatically because the join is keyed on tag id.
    public var renameTag: @MainActor (Int64, String) async -> Void
    /// Delete a tag. The repo cascades the deletion through `session_tags`
    /// via the foreign-key ON DELETE CASCADE clause.
    public var deleteTag: @MainActor (Int64) async -> Void

    // MARK: - Plan 08 — smart folder CRUD wired from the sidebar

    public var createSmartFolder: @MainActor (String, SmartFolderQuery) async -> SmartFolder?
    public var renameSmartFolder: @MainActor (Int64, String) async -> Void
    public var deleteSmartFolder: @MainActor (Int64) async -> Void

    /// No-op defaults so previews / tests can skip wiring.
    public static let noop = UserMetadataActions(
        togglePin: { _ in },
        archive: { _ in },
        moveToTrash: { _ in },
        beginRename: { _ in },
        commitRename: { _, _ in },
        openNote: { _ in },
        saveNote: { _, _ in },
        openTagPicker: { _ in },
        setTags: { _, _ in },
        createTag: { _, _ in nil },
        renameTag: { _, _ in },
        deleteTag: { _ in },
        createSmartFolder: { _, _ in nil },
        renameSmartFolder: { _, _ in },
        deleteSmartFolder: { _ in }
    )
}

private struct UserMetadataActionsKey: EnvironmentKey {
    static let defaultValue: UserMetadataActions = .noop
}

public extension EnvironmentValues {
    var userMetadataActions: UserMetadataActions {
        get { self[UserMetadataActionsKey.self] }
        set { self[UserMetadataActionsKey.self] = newValue }
    }
}
