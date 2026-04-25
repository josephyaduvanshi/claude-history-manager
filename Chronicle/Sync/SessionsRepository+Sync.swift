import Foundation
import GRDB

// Repository surface used by `ICloudSync` to export and import user metadata,
// tags, session_tags, and user-created smart folders. Kept in a separate file
// so `SessionsRepository.swift` stays focused on the main indexing API.

public extension SessionsRepository {

    // MARK: - Export

    /// Every `user_metadata` row, including archived / soft-deleted. The sync
    /// merge rules use `updated_at` to decide newer-wins; we export everything
    /// so the remote copy can authoritatively represent cross-machine state.
    func allUserMetadata() async throws -> [UserMetadata] {
        try await databaseForSync.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT session_id, is_pinned, is_archived, is_deleted, deleted_at,
                       custom_title, note, updated_at
                FROM user_metadata
                """)
            return rows.compactMap { row -> UserMetadata? in
                guard let sid = try? SessionID(string: row["session_id"]) else { return nil }
                let updatedAt: Int64 = row["updated_at"]
                let deletedAt: Int64? = row["deleted_at"]
                return UserMetadata(
                    sessionID: sid,
                    isPinned: (row["is_pinned"] as Int64) != 0,
                    isArchived: (row["is_archived"] as Int64) != 0,
                    isDeleted: (row["is_deleted"] as Int64) != 0,
                    deletedAt: deletedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                    customTitle: row["custom_title"],
                    note: row["note"],
                    updatedAt: Date(timeIntervalSince1970: TimeInterval(updatedAt))
                )
            }
        }
    }

    /// Every tag, ordered by name (case-insensitive).
    func allTagsForSync() async throws -> [Tag] {
        try await allTags()
    }

    /// Every `(session_id, tag_name)` pair. We dereference tag IDs to names on
    /// export so the sync payload is stable across machines with different
    /// auto-increment IDs.
    func allSessionTagPairsForSync() async throws -> [(sessionID: String, tagName: String)] {
        try await databaseForSync.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT st.session_id AS sid, t.name AS name
                FROM session_tags st
                INNER JOIN tags t ON t.id = st.tag_id
                """)
            return rows.map { ($0["sid"] as String, $0["name"] as String) }
        }
    }

    /// Every smart folder; callers filter out `isBuiltIn` before pushing.
    func allSmartFoldersForSync() async throws -> [SmartFolder] {
        try await smartFolders()
    }

    // MARK: - Merge (apply a remote payload)

    /// Upsert a remote `user_metadata` row only when the remote `updated_at`
    /// is strictly newer than the local row's. Returns `true` when a write
    /// happened.
    @discardableResult
    func mergeUserMetadata(_ remote: UserMetadata) async throws -> Bool {
        try await databaseForSync.write { db in
            let existing = try Row.fetchOne(db, sql: """
                SELECT updated_at FROM user_metadata WHERE session_id = ?
                """, arguments: [remote.sessionID.description])
            if let existing, let localUpdated = existing["updated_at"] as Int64?,
               localUpdated >= Int64(remote.updatedAt.timeIntervalSince1970.rounded()) {
                return false
            }
            let deletedAt: Int64? = remote.deletedAt.map {
                Int64($0.timeIntervalSince1970.rounded())
            }
            try db.execute(sql: """
                INSERT INTO user_metadata
                    (session_id, is_pinned, is_archived, is_deleted, deleted_at,
                     custom_title, note, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(session_id) DO UPDATE SET
                    is_pinned = excluded.is_pinned,
                    is_archived = excluded.is_archived,
                    is_deleted = excluded.is_deleted,
                    deleted_at = excluded.deleted_at,
                    custom_title = excluded.custom_title,
                    note = excluded.note,
                    updated_at = excluded.updated_at
                """, arguments: [
                    remote.sessionID.description,
                    remote.isPinned ? 1 : 0,
                    remote.isArchived ? 1 : 0,
                    remote.isDeleted ? 1 : 0,
                    deletedAt,
                    remote.customTitle,
                    remote.note,
                    Int64(remote.updatedAt.timeIntervalSince1970.rounded()),
                ])
            return true
        }
    }

    /// Insert a tag by name if none with that name (case-insensitive) exists.
    /// Returns the surviving tag id for the given name.
    @discardableResult
    func ensureTagForSync(name: String, colorHue: Int) async throws -> Int64 {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TagError.emptyName }
        return try await databaseForSync.write { db in
            if let existing = try Row.fetchOne(db, sql: """
                SELECT id FROM tags WHERE name = ? COLLATE NOCASE
                """, arguments: [trimmed]) {
                return existing["id"]
            }
            try db.execute(sql: """
                INSERT INTO tags (name, color_hue) VALUES (?, ?)
                """, arguments: [trimmed, Tag.clampHue(colorHue)])
            return db.lastInsertedRowID
        }
    }

    /// Attach a tag (by name, case-insensitive) to a session. No-op if the
    /// pairing already exists.
    func attachTagForSync(sessionID: String, tagName: String) async throws {
        let trimmed = tagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try await databaseForSync.write { db in
            guard let tagID: Int64 = try Row.fetchOne(db, sql: """
                SELECT id FROM tags WHERE name = ? COLLATE NOCASE
                """, arguments: [trimmed])?["id"] else {
                // Tag missing; happens if a remote pairing referenced a tag
                // that never got its own row. Insert a fallback with the
                // default coral hue and attach.
                try db.execute(sql: """
                    INSERT OR IGNORE INTO tags (name, color_hue) VALUES (?, ?)
                    """, arguments: [trimmed, 30])
                let fallback = try Int64.fetchOne(db, sql: """
                    SELECT id FROM tags WHERE name = ? COLLATE NOCASE
                    """, arguments: [trimmed]) ?? 0
                guard fallback > 0 else { return }
                try db.execute(sql: """
                    INSERT OR IGNORE INTO session_tags (session_id, tag_id) VALUES (?, ?)
                    """, arguments: [sessionID, fallback])
                return
            }
            try db.execute(sql: """
                INSERT OR IGNORE INTO session_tags (session_id, tag_id) VALUES (?, ?)
                """, arguments: [sessionID, tagID])
        }
    }

    /// Insert a user-authored smart folder if none with that name exists.
    /// Remote smart folders always land as non-builtin rows so they sort
    /// below the four seeded built-ins.
    func ensureSmartFolderForSync(name: String,
                                   query: SmartFolderQuery,
                                   sortOrder: Int) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try await databaseForSync.write { db in
            let existing = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM smart_folders WHERE name = ? COLLATE NOCASE
                """, arguments: [trimmed]) ?? 0
            guard existing == 0 else { return }
            let encoder = JSONEncoder()
            guard let data = try? encoder.encode(query),
                  let json = String(data: data, encoding: .utf8) else {
                return
            }
            try db.execute(sql: """
                INSERT INTO smart_folders (name, query_json, sort_order, is_builtin)
                VALUES (?, ?, ?, 0)
                """, arguments: [trimmed, json, sortOrder])
        }
    }

    /// Test-only hook exposing the underlying writer. Production code in
    /// `ICloudSync` funnels through this so we don't widen `databaseForTests`
    /// visibility beyond the module.
    internal var databaseForSync: any DatabaseWriter { databaseForTests }
}

// MARK: - Protocol surface

/// Minimal sync-oriented API that `ICloudSync` depends on. Mirrors the
/// concrete methods above but kept as a protocol so tests can supply a
/// lightweight in-memory double without standing up a GRDB database.
public protocol SessionsSyncRepositoryProtocol: Sendable {
    func allUserMetadata() async throws -> [UserMetadata]
    func allTagsForSync() async throws -> [Tag]
    func allSessionTagPairsForSync() async throws -> [(sessionID: String, tagName: String)]
    func allSmartFoldersForSync() async throws -> [SmartFolder]

    @discardableResult
    func mergeUserMetadata(_ remote: UserMetadata) async throws -> Bool

    @discardableResult
    func ensureTagForSync(name: String, colorHue: Int) async throws -> Int64

    func attachTagForSync(sessionID: String, tagName: String) async throws

    func ensureSmartFolderForSync(name: String,
                                   query: SmartFolderQuery,
                                   sortOrder: Int) async throws
}

extension SessionsRepository: SessionsSyncRepositoryProtocol {}
