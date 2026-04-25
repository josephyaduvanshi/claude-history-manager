import Foundation
import GRDB

// Repository surface used by `ICloudSync` to export and import user metadata,
// tags, session_tags, and user-created smart folders. Kept in a separate file
// so `SessionsRepository.swift` stays focused on the main indexing API.

public extension SessionsRepository {

    // MARK: - Export

    /// Every `user_metadata` row across every provider, paired with the
    /// provider that owns it. Sync exports the full picture (not just
    /// the active provider) so a Mac with multiple providers' data
    /// pushes a complete snapshot.
    func allUserMetadataForSync() async throws -> [(metadata: UserMetadata, provider: ProviderID)] {
        try await databaseForSync.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT session_id, is_pinned, is_archived, is_deleted, deleted_at,
                       custom_title, note, updated_at, provider
                FROM user_metadata
                """)
            return rows.compactMap { row -> (UserMetadata, ProviderID)? in
                guard let sid = try? SessionID(string: row["session_id"]) else { return nil }
                let updatedAt: Int64 = row["updated_at"]
                let deletedAt: Int64? = row["deleted_at"]
                let providerRaw: String = row["provider"]
                let provider = ProviderID(rawValue: providerRaw) ?? .claude
                let m = UserMetadata(
                    sessionID: sid,
                    isPinned: (row["is_pinned"] as Int64) != 0,
                    isArchived: (row["is_archived"] as Int64) != 0,
                    isDeleted: (row["is_deleted"] as Int64) != 0,
                    deletedAt: deletedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                    customTitle: row["custom_title"],
                    note: row["note"],
                    updatedAt: Date(timeIntervalSince1970: TimeInterval(updatedAt))
                )
                return (m, provider)
            }
        }
    }

    /// Backwards-compatible accessor used by callers that don't care
    /// about the provider tag. Always operates on the active provider's
    /// rows so it doesn't accidentally leak cross-provider metadata to
    /// callers expecting v0.1.x semantics.
    func allUserMetadata() async throws -> [UserMetadata] {
        let providerKey = activeProvider().rawValue
        return try await databaseForSync.read { [providerKey] db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT session_id, is_pinned, is_archived, is_deleted, deleted_at,
                       custom_title, note, updated_at
                FROM user_metadata
                WHERE provider = ?
                """, arguments: [providerKey])
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

    /// Every tag across every provider, paired with its provider.
    func allTagsForSync() async throws -> [(tag: Tag, provider: ProviderID)] {
        try await databaseForSync.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, name, color_hue, provider FROM tags
                ORDER BY name COLLATE NOCASE ASC
                """)
            return rows.map { row in
                let raw: String = row["provider"]
                let p = ProviderID(rawValue: raw) ?? .claude
                let tag = Tag(id: row["id"], name: row["name"], colorHue: row["color_hue"])
                return (tag, p)
            }
        }
    }

    /// Every `(session_id, tag_name, provider)` triple across every
    /// provider. Tag IDs are dereferenced to names on export so the
    /// sync payload is stable across machines with different
    /// auto-increment IDs.
    func allSessionTagPairsForSync() async throws -> [(sessionID: String, tagName: String, provider: ProviderID)] {
        try await databaseForSync.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT st.session_id AS sid, t.name AS name, st.provider AS p
                FROM session_tags st
                INNER JOIN tags t ON t.id = st.tag_id AND t.provider = st.provider
                """)
            return rows.map { row -> (String, String, ProviderID) in
                let raw: String = row["p"]
                return (row["sid"] as String,
                        row["name"] as String,
                        ProviderID(rawValue: raw) ?? .claude)
            }
        }
    }

    /// Every smart folder across every provider, paired with its provider.
    func allSmartFoldersForSync() async throws -> [(folder: SmartFolder, provider: ProviderID)] {
        try await databaseForSync.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, name, query_json, sort_order, is_builtin, provider
                FROM smart_folders
                ORDER BY sort_order ASC, id ASC
                """)
            return rows.compactMap { row -> (SmartFolder, ProviderID)? in
                let jsonText: String = row["query_json"]
                guard let data = jsonText.data(using: .utf8),
                      let q = try? JSONDecoder().decode(SmartFolderQuery.self, from: data) else {
                    return nil
                }
                let f = SmartFolder(
                    id: row["id"],
                    name: row["name"],
                    query: q,
                    sortOrder: Int(row["sort_order"] as Int64),
                    isBuiltIn: (row["is_builtin"] as Int64) != 0
                )
                let raw: String = row["provider"]
                return (f, ProviderID(rawValue: raw) ?? .claude)
            }
        }
    }

    // MARK: - Merge (apply a remote payload)

    /// Upsert a remote `user_metadata` row only when the remote `updated_at`
    /// is strictly newer than the local row's. Returns `true` when a write
    /// happened.
    @discardableResult
    func mergeUserMetadata(_ remote: UserMetadata, provider: ProviderID = .claude) async throws -> Bool {
        let providerKey = provider.rawValue
        return try await databaseForSync.write { [providerKey] db in
            let existing = try Row.fetchOne(db, sql: """
                SELECT updated_at FROM user_metadata
                WHERE provider = ? AND session_id = ?
                """, arguments: [providerKey, remote.sessionID.description])
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
                     custom_title, note, updated_at, provider)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(provider, session_id) DO UPDATE SET
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
                    providerKey,
                ])
            return true
        }
    }

    /// Insert a tag by name if none with that name (case-insensitive) exists
    /// for the given provider. Returns the surviving tag id.
    @discardableResult
    func ensureTagForSync(name: String, colorHue: Int, provider: ProviderID = .claude) async throws -> Int64 {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TagError.emptyName }
        let providerKey = provider.rawValue
        return try await databaseForSync.write { [providerKey] db in
            if let existing = try Row.fetchOne(db, sql: """
                SELECT id FROM tags WHERE name = ? COLLATE NOCASE AND provider = ?
                """, arguments: [trimmed, providerKey]) {
                return existing["id"]
            }
            try db.execute(sql: """
                INSERT INTO tags (name, color_hue, provider) VALUES (?, ?, ?)
                """, arguments: [trimmed, Tag.clampHue(colorHue), providerKey])
            return db.lastInsertedRowID
        }
    }

    /// Attach a tag (by name, case-insensitive) to a session under the
    /// given provider. No-op if the pairing already exists.
    func attachTagForSync(sessionID: String, tagName: String, provider: ProviderID = .claude) async throws {
        let trimmed = tagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let providerKey = provider.rawValue
        try await databaseForSync.write { [providerKey] db in
            guard let tagID: Int64 = try Row.fetchOne(db, sql: """
                SELECT id FROM tags WHERE name = ? COLLATE NOCASE AND provider = ?
                """, arguments: [trimmed, providerKey])?["id"] else {
                // Tag missing — fall back to inserting one. Default coral hue.
                try db.execute(sql: """
                    INSERT OR IGNORE INTO tags (name, color_hue, provider) VALUES (?, ?, ?)
                    """, arguments: [trimmed, 30, providerKey])
                let fallback = try Int64.fetchOne(db, sql: """
                    SELECT id FROM tags WHERE name = ? COLLATE NOCASE AND provider = ?
                    """, arguments: [trimmed, providerKey]) ?? 0
                guard fallback > 0 else { return }
                try db.execute(sql: """
                    INSERT OR IGNORE INTO session_tags (session_id, tag_id, provider) VALUES (?, ?, ?)
                    """, arguments: [sessionID, fallback, providerKey])
                return
            }
            try db.execute(sql: """
                INSERT OR IGNORE INTO session_tags (session_id, tag_id, provider) VALUES (?, ?, ?)
                """, arguments: [sessionID, tagID, providerKey])
        }
    }

    /// Insert a user-authored smart folder if none with that name exists
    /// under the given provider. Remote smart folders always land as
    /// non-builtin rows so they sort below the seeded built-ins.
    func ensureSmartFolderForSync(name: String,
                                   query: SmartFolderQuery,
                                   sortOrder: Int,
                                   provider: ProviderID = .claude) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let providerKey = provider.rawValue
        try await databaseForSync.write { [providerKey] db in
            let existing = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM smart_folders
                WHERE name = ? COLLATE NOCASE AND provider = ?
                """, arguments: [trimmed, providerKey]) ?? 0
            guard existing == 0 else { return }
            let encoder = JSONEncoder()
            guard let data = try? encoder.encode(query),
                  let json = String(data: data, encoding: .utf8) else {
                return
            }
            try db.execute(sql: """
                INSERT INTO smart_folders (name, query_json, sort_order, is_builtin, provider)
                VALUES (?, ?, ?, 0, ?)
                """, arguments: [trimmed, json, sortOrder, providerKey])
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
    func allUserMetadataForSync() async throws -> [(metadata: UserMetadata, provider: ProviderID)]
    func allTagsForSync() async throws -> [(tag: Tag, provider: ProviderID)]
    func allSessionTagPairsForSync() async throws -> [(sessionID: String, tagName: String, provider: ProviderID)]
    func allSmartFoldersForSync() async throws -> [(folder: SmartFolder, provider: ProviderID)]

    @discardableResult
    func mergeUserMetadata(_ remote: UserMetadata, provider: ProviderID) async throws -> Bool

    @discardableResult
    func ensureTagForSync(name: String, colorHue: Int, provider: ProviderID) async throws -> Int64

    func attachTagForSync(sessionID: String, tagName: String, provider: ProviderID) async throws

    func ensureSmartFolderForSync(name: String,
                                   query: SmartFolderQuery,
                                   sortOrder: Int,
                                   provider: ProviderID) async throws
}

extension SessionsRepository: SessionsSyncRepositoryProtocol {}
