import XCTest
import GRDB
@testable import Chronicle

final class UserMetadataRepositoryTests: XCTestCase {
    private func fixturesRoot() -> URL {
        Bundle.module.url(forResource: "Fixtures/sample-sessions",
                          withExtension: nil)!
    }

    private func makeRepo(withProjectsRoot: URL? = nil) throws -> SessionsRepository {
        let dbq = try DatabaseQueue()
        try Migrations.all(dbq)
        return SessionsRepository(
            database: dbq,
            parser: JsonlParser(),
            decoder: WorkspacePathDecoder(),
            projectsRoot: withProjectsRoot
        )
    }

    // Two real session IDs pulled from the Fixtures jsonl files so
    // `sessions_index` has matching rows to attach user_metadata to.
    private func bootstrappedRepo() async throws -> (SessionsRepository, [SessionMetadata]) {
        let repo = try makeRepo()
        try await repo.bootstrap(rootURL: fixturesRoot())
        let sessions = try await repo.allSessions(limit: 100)
        XCTAssertGreaterThanOrEqual(sessions.count, 2)
        return (repo, sessions)
    }

    // MARK: - Pin

    func test_userMetadata_absentByDefault_returnsEmpty() async throws {
        let repo = try makeRepo()
        let sid = try SessionID(string: "11111111-1111-1111-1111-111111111111")
        let meta = try await repo.userMetadata(for: sid)
        XCTAssertFalse(meta.isPinned)
        XCTAssertFalse(meta.isArchived)
        XCTAssertNil(meta.customTitle)
        XCTAssertNil(meta.note)
    }

    func test_setPinned_persistsAndRoundTrips() async throws {
        let (repo, sessions) = try await bootstrappedRepo()
        let sid = sessions[0].sessionID
        try await repo.setPinned(true, for: sid)
        let meta = try await repo.userMetadata(for: sid)
        XCTAssertTrue(meta.isPinned)
    }

    func test_setPinned_togglesOffCleanly() async throws {
        let (repo, sessions) = try await bootstrappedRepo()
        let sid = sessions[0].sessionID
        try await repo.setPinned(true, for: sid)
        try await repo.setPinned(false, for: sid)
        let meta = try await repo.userMetadata(for: sid)
        XCTAssertFalse(meta.isPinned)
    }

    func test_pinnedSessions_returnsOnlyPinnedOrderedByUpdatedAtDesc() async throws {
        let (repo, sessions) = try await bootstrappedRepo()
        try await repo.setPinned(true, for: sessions[0].sessionID)
        // small sleep to force different updated_at seconds
        try await Task.sleep(nanoseconds: 1_100_000_000)
        try await repo.setPinned(true, for: sessions[1].sessionID)

        let pinned = try await repo.pinnedSessions(limit: 50)
        XCTAssertEqual(pinned.count, 2)
        // Most recently pinned comes first.
        XCTAssertEqual(pinned.first?.session.sessionID, sessions[1].sessionID)
    }

    // MARK: - Archive

    func test_setArchived_hidesRowFromWorkspaceList() async throws {
        let (repo, sessions) = try await bootstrappedRepo()
        let target = sessions[0]
        let before = try await repo.sessions(inWorkspaceID: target.workspaceID)
        XCTAssertTrue(before.contains { $0.sessionID == target.sessionID })

        try await repo.setArchived(true, for: target.sessionID)
        let after = try await repo.sessions(inWorkspaceID: target.workspaceID)
        XCTAssertFalse(after.contains { $0.sessionID == target.sessionID },
                       "archived session should not appear in workspace list")
    }

    func test_archivedSessions_returnsArchivedOnly() async throws {
        let (repo, sessions) = try await bootstrappedRepo()
        try await repo.setArchived(true, for: sessions[0].sessionID)
        let archived = try await repo.archivedSessions(limit: 50)
        XCTAssertEqual(archived.count, 1)
        XCTAssertEqual(archived.first?.session.sessionID, sessions[0].sessionID)
    }

    func test_unarchive_restoresToWorkspaceList() async throws {
        let (repo, sessions) = try await bootstrappedRepo()
        let target = sessions[0]
        try await repo.setArchived(true, for: target.sessionID)
        try await repo.setArchived(false, for: target.sessionID)
        let list = try await repo.sessions(inWorkspaceID: target.workspaceID)
        XCTAssertTrue(list.contains { $0.sessionID == target.sessionID })
    }

    func test_archivedCount_reflectsFlagChanges() async throws {
        let (repo, sessions) = try await bootstrappedRepo()
        var c = try await repo.archivedCount(); XCTAssertEqual(c, 0)
        try await repo.setArchived(true, for: sessions[0].sessionID)
        c = try await repo.archivedCount(); XCTAssertEqual(c, 1)
        try await repo.setArchived(true, for: sessions[1].sessionID)
        c = try await repo.archivedCount(); XCTAssertEqual(c, 2)
        try await repo.setArchived(false, for: sessions[0].sessionID)
        c = try await repo.archivedCount(); XCTAssertEqual(c, 1)
    }

    // MARK: - Custom title

    func test_setCustomTitle_coalescesInWorkspaceQuery() async throws {
        let (repo, sessions) = try await bootstrappedRepo()
        let target = sessions[0]
        try await repo.setCustomTitle("My renamed session", for: target.sessionID)
        let list = try await repo.sessions(inWorkspaceID: target.workspaceID)
        let renamed = list.first { $0.sessionID == target.sessionID }
        XCTAssertEqual(renamed?.title, "My renamed session")
    }

    func test_setCustomTitle_empty_resetsToRaw() async throws {
        let (repo, sessions) = try await bootstrappedRepo()
        let target = sessions[0]
        let original = target.title
        try await repo.setCustomTitle("Something", for: target.sessionID)
        try await repo.setCustomTitle("", for: target.sessionID)
        let list = try await repo.sessions(inWorkspaceID: target.workspaceID)
        let back = list.first { $0.sessionID == target.sessionID }
        XCTAssertEqual(back?.title, original)
    }

    func test_setCustomTitle_nil_resetsToRaw() async throws {
        let (repo, sessions) = try await bootstrappedRepo()
        let target = sessions[0]
        let original = target.title
        try await repo.setCustomTitle("Different", for: target.sessionID)
        try await repo.setCustomTitle(nil, for: target.sessionID)
        let list = try await repo.sessions(inWorkspaceID: target.workspaceID)
        XCTAssertEqual(list.first { $0.sessionID == target.sessionID }?.title, original)
    }

    // MARK: - Notes

    func test_setNote_persistsAndRoundTrips() async throws {
        let (repo, sessions) = try await bootstrappedRepo()
        try await repo.setNote("Remember to verify webhooks", for: sessions[0].sessionID)
        let meta = try await repo.userMetadata(for: sessions[0].sessionID)
        XCTAssertEqual(meta.note, "Remember to verify webhooks")
    }

    func test_setNote_emptyClearsIt() async throws {
        let (repo, sessions) = try await bootstrappedRepo()
        try await repo.setNote("something", for: sessions[0].sessionID)
        try await repo.setNote("", for: sessions[0].sessionID)
        let meta = try await repo.userMetadata(for: sessions[0].sessionID)
        XCTAssertNil(meta.note)
    }

    // MARK: - Soft delete + purge

    func test_softDelete_hidesFromWorkspaceListAndMarksDeletedAt() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let wsFolder = tmp.appendingPathComponent("-Users-test-flutter-app", isDirectory: true)
        try FileManager.default.createDirectory(at: wsFolder, withIntermediateDirectories: true)
        // Copy one real fixture file into our tmp projects root so softDelete
        // can actually move it to Trash.
        let fixtures = fixturesRoot().appendingPathComponent("-Users-test-flutter-app", isDirectory: true)
        let jsonls = try FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }
        for file in jsonls {
            let dest = wsFolder.appendingPathComponent(file.lastPathComponent)
            try FileManager.default.copyItem(at: file, to: dest)
        }
        // Also copy rust fixture so bootstrap sees 2 workspaces.
        let rustSrc = fixturesRoot().appendingPathComponent("-Users-test-rust-app", isDirectory: true)
        let rustDst = tmp.appendingPathComponent("-Users-test-rust-app", isDirectory: true)
        try FileManager.default.createDirectory(at: rustDst, withIntermediateDirectories: true)
        for file in try FileManager.default.contentsOfDirectory(at: rustSrc, includingPropertiesForKeys: nil).filter({ $0.pathExtension == "jsonl" }) {
            try FileManager.default.copyItem(at: file, to: rustDst.appendingPathComponent(file.lastPathComponent))
        }

        let repo = try makeRepo(withProjectsRoot: tmp)
        try await repo.bootstrap(rootURL: tmp)

        let all = try await repo.allSessions(limit: 50)
        let target = all.first { $0.workspaceID == "-Users-test-flutter-app" }!

        try await repo.softDelete(target.sessionID, workspaceID: target.workspaceID)

        // File must no longer be in the live projects dir.
        let original = wsFolder.appendingPathComponent("\(target.sessionID.description).jsonl")
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path),
                       "softDelete should remove the file from the projects root")

        // Session disappears from queries.
        let wsList = try await repo.sessions(inWorkspaceID: target.workspaceID)
        XCTAssertFalse(wsList.contains { $0.sessionID == target.sessionID })

        // user_metadata flags set.
        let meta = try await repo.userMetadata(for: target.sessionID)
        XCTAssertTrue(meta.isDeleted)
        XCTAssertNotNil(meta.deletedAt)
    }

    func test_softDelete_missingFile_stillFlipsDBFlag() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let repo = try makeRepo(withProjectsRoot: tmp)
        let sid = try SessionID(string: "22222222-2222-2222-2222-222222222222")
        try await repo.softDelete(sid, workspaceID: "-missing")

        let meta = try await repo.userMetadata(for: sid)
        XCTAssertTrue(meta.isDeleted)
    }

    func test_undelete_clearsFlagAndTimestamp() async throws {
        let (repo, sessions) = try await bootstrappedRepo()
        try await repo.softDelete(sessions[0].sessionID, workspaceID: sessions[0].workspaceID)
        try await repo.undelete(sessions[0].sessionID)
        let meta = try await repo.userMetadata(for: sessions[0].sessionID)
        XCTAssertFalse(meta.isDeleted)
        XCTAssertNil(meta.deletedAt)
    }

    func test_hardPurgeExpiredDeletes_removesOnlyExpiredRows() async throws {
        let repo = try makeRepo()
        let dbq = try DatabaseQueue()
        try Migrations.all(dbq)
        // Direct insert avoids needing filesystem state. We'll build a new repo
        // that shares this dbq.
        let sharedRepo = SessionsRepository(database: dbq,
                                            parser: JsonlParser(),
                                            decoder: WorkspacePathDecoder())
        // Two user_metadata rows: one deleted 40 days ago, one deleted today.
        let oldSid = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let newSid = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        let oldEpoch = Int64(Date().addingTimeInterval(-40 * 86400).timeIntervalSince1970)
        let newEpoch = Int64(Date().timeIntervalSince1970)
        try await dbq.write { db in
            try db.execute(sql: """
                INSERT INTO workspaces (id, decoded_path, "group", display_name, indexed_at)
                VALUES ('w', '/w', 'g', 'w', ?)
                """, arguments: [Date()])
            try db.execute(sql: """
                INSERT INTO sessions_index (session_id, workspace_id, title, created_at, last_modified_at,
                                            message_count, token_count, file_size_bytes, file_mtime)
                VALUES (?, 'w', 't', ?, ?, 0, 0, 0, ?)
                """, arguments: [oldSid, Date(), Date(), Date()])
            try db.execute(sql: """
                INSERT INTO sessions_index (session_id, workspace_id, title, created_at, last_modified_at,
                                            message_count, token_count, file_size_bytes, file_mtime)
                VALUES (?, 'w', 't', ?, ?, 0, 0, 0, ?)
                """, arguments: [newSid, Date(), Date(), Date()])
            try db.execute(sql: """
                INSERT INTO user_metadata (session_id, is_pinned, is_archived, is_deleted, deleted_at, custom_title, note, updated_at)
                VALUES (?, 0, 0, 1, ?, NULL, NULL, ?)
                """, arguments: [oldSid, oldEpoch, oldEpoch])
            try db.execute(sql: """
                INSERT INTO user_metadata (session_id, is_pinned, is_archived, is_deleted, deleted_at, custom_title, note, updated_at)
                VALUES (?, 0, 0, 1, ?, NULL, NULL, ?)
                """, arguments: [newSid, newEpoch, newEpoch])
        }

        try await sharedRepo.hardPurgeExpiredDeletes(olderThan: 30)

        let (oldCount, newCount) = try await dbq.read { db -> (Int, Int) in
            let o = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM user_metadata WHERE session_id = ?",
                                     arguments: [oldSid]) ?? -1
            let n = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM user_metadata WHERE session_id = ?",
                                     arguments: [newSid]) ?? -1
            return (o, n)
        }
        XCTAssertEqual(oldCount, 0, "40-day-old row should be purged")
        XCTAssertEqual(newCount, 1, "today's row should survive")
        _ = repo
    }

    // MARK: - Tags CRUD

    func test_createTag_insertsRowAndReturnsWithID() async throws {
        let repo = try makeRepo()
        let t = try await repo.createTag(name: "client", colorHue: 250)
        XCTAssertGreaterThan(t.id, 0)
        XCTAssertEqual(t.name, "client")
        XCTAssertEqual(t.colorHue, 250)
    }

    func test_createTag_duplicateName_throws() async throws {
        let repo = try makeRepo()
        _ = try await repo.createTag(name: "dup", colorHue: 30)
        do {
            _ = try await repo.createTag(name: "DUP", colorHue: 30)
            XCTFail("expected alreadyExists")
        } catch SessionsRepository.TagError.alreadyExists {
            // expected
        }
    }

    func test_renameTag_persistsNewName() async throws {
        let repo = try makeRepo()
        let t = try await repo.createTag(name: "foo", colorHue: 30)
        try await repo.renameTag(t.id, to: "bar")
        let all = try await repo.allTags()
        XCTAssertEqual(all.first?.name, "bar")
    }

    func test_deleteTag_cascadesSessionTagJoins() async throws {
        let (repo, sessions) = try await bootstrappedRepo()
        let t = try await repo.createTag(name: "ephemeral", colorHue: 145)
        try await repo.setTags([t.id], for: sessions[0].sessionID)
        let before = try await repo.tags(for: sessions[0].sessionID)
        XCTAssertEqual(before.count, 1)
        try await repo.deleteTag(t.id)
        let after = try await repo.tags(for: sessions[0].sessionID)
        XCTAssertEqual(after.count, 0)
    }

    func test_setTags_replacesExistingTags() async throws {
        let (repo, sessions) = try await bootstrappedRepo()
        let t1 = try await repo.createTag(name: "one", colorHue: 30)
        let t2 = try await repo.createTag(name: "two", colorHue: 75)
        let t3 = try await repo.createTag(name: "three", colorHue: 200)

        try await repo.setTags([t1.id, t2.id], for: sessions[0].sessionID)
        let first = try await repo.tags(for: sessions[0].sessionID).map(\.id).sorted()
        XCTAssertEqual(first, [t1.id, t2.id].sorted())

        // Replace with a different set entirely.
        try await repo.setTags([t3.id], for: sessions[0].sessionID)
        let second = try await repo.tags(for: sessions[0].sessionID).map(\.id)
        XCTAssertEqual(second, [t3.id])
    }

    func test_sessionsForTag_returnsTaggedSessionsOnly() async throws {
        let (repo, sessions) = try await bootstrappedRepo()
        let tag = try await repo.createTag(name: "stripe", colorHue: 30)
        try await repo.setTags([tag.id], for: sessions[0].sessionID)

        let tagged = try await repo.sessionsForTag(tag, limit: 50)
        XCTAssertEqual(tagged.count, 1)
        XCTAssertEqual(tagged.first?.session.sessionID, sessions[0].sessionID)
    }

    func test_tagCounts_reflectsAssignments() async throws {
        let (repo, sessions) = try await bootstrappedRepo()
        let tag = try await repo.createTag(name: "counted", colorHue: 30)
        try await repo.setTags([tag.id], for: sessions[0].sessionID)
        try await repo.setTags([tag.id], for: sessions[1].sessionID)
        let counts = try await repo.tagCounts()
        XCTAssertEqual(counts[tag.id], 2)
    }

    // MARK: - Search excludes deleted/archived

    func test_search_excludesDeletedByDefault() async throws {
        let (repo, sessions) = try await bootstrappedRepo()
        let target = sessions.first { $0.title.lowercased().contains("stripe") }!
        var q = SearchQuery()
        q.titleText = "stripe"
        var results = try await repo.search(query: q)
        XCTAssertFalse(results.isEmpty)
        try await repo.softDelete(target.sessionID, workspaceID: target.workspaceID)
        results = try await repo.search(query: q)
        XCTAssertFalse(results.contains { $0.sessionID == target.sessionID })
    }

    func test_search_excludesArchivedByDefault() async throws {
        let (repo, sessions) = try await bootstrappedRepo()
        let target = sessions.first { $0.title.lowercased().contains("stripe") }!
        var q = SearchQuery()
        q.titleText = "stripe"
        try await repo.setArchived(true, for: target.sessionID)
        let results = try await repo.search(query: q)
        XCTAssertFalse(results.contains { $0.sessionID == target.sessionID })
    }

    func test_search_matchesCustomTitle() async throws {
        let (repo, sessions) = try await bootstrappedRepo()
        let target = sessions[0]
        try await repo.setCustomTitle("Gemini tuning passes", for: target.sessionID)
        var q = SearchQuery()
        q.titleText = "gemini"
        let results = try await repo.search(query: q)
        XCTAssertTrue(results.contains { $0.sessionID == target.sessionID })
    }
}
