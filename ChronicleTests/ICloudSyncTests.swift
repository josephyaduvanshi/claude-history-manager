import XCTest
@testable import Chronicle

final class ICloudSyncTests: XCTestCase {

    // MARK: - Helpers

    private func tempDir(_ label: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chronicle-sync-\(label)-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        return dir
    }

    private func sessionID(_ byte: UInt8) -> SessionID {
        // Deterministic UUIDs for cross-repo identity.
        // UUID shape: 8-4-4-4-12 hex chars = 16 bytes.
        let h = String(format: "%02x", byte)
        let part8 = String(repeating: h, count: 4)       // 8 hex chars
        let part4 = String(repeating: h, count: 2)       // 4 hex chars
        let part12 = String(repeating: h, count: 6)      // 12 hex chars
        let uuidString = "\(part8)-\(part4)-\(part4)-\(part4)-\(part12)"
        guard let uuid = UUID(uuidString: uuidString) else {
            fatalError("bad test UUID: \(uuidString)")
        }
        return SessionID(rawValue: uuid)
    }

    // MARK: - Round-trip: push → clear → pull → state restored

    func test_push_then_pull_round_trips_user_metadata() async throws {
        let tmp = tempDir("rt")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let sid = sessionID(0x1a)
        let repo1 = FakeSyncRepository()
        await repo1.seed(metadata: [
            UserMetadata(sessionID: sid,
                         isPinned: true,
                         isArchived: false,
                         customTitle: "Chat about Stripe",
                         note: "follow up next week",
                         updatedAt: Date(timeIntervalSince1970: 1_000))
        ], tags: [
            Tag(id: 1, name: "client work", colorHue: 250)
        ], pairs: [
            (sid.description, "client work")
        ])

        let sync1 = ICloudSync(repository: repo1, containerURL: tmp)
        try await sync1.push()

        // New blank repository — pull should restore the remote state.
        let repo2 = FakeSyncRepository()
        let sync2 = ICloudSync(repository: repo2, containerURL: tmp)
        try await sync2.pull()

        let restored = try await repo2.allUserMetadata()
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.sessionID, sid)
        XCTAssertEqual(restored.first?.customTitle, "Chat about Stripe")
        XCTAssertTrue(restored.first?.isPinned == true)

        let restoredTags = try await repo2.allTagsForSync()
        XCTAssertTrue(restoredTags.contains { $0.tag.name == "client work" })

        let pairs = try await repo2.allSessionTagPairsForSync()
        XCTAssertTrue(pairs.contains { $0.sessionID == sid.description && $0.tagName == "client work" })
    }

    // MARK: - Merge: both sides survive

    func test_pull_merges_without_losing_local_tags_or_newer_metadata() async throws {
        let tmp = tempDir("merge")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let sid = sessionID(0x2b)

        // Remote state — pinned=true, stale updated_at.
        let remoteRepo = FakeSyncRepository()
        await remoteRepo.seed(metadata: [
            UserMetadata(sessionID: sid,
                         isPinned: true,
                         updatedAt: Date(timeIntervalSince1970: 100))
        ], tags: [
            Tag(id: 1, name: "remote-only-tag", colorHue: 30)
        ], pairs: [])

        let remoteSync = ICloudSync(repository: remoteRepo, containerURL: tmp)
        try await remoteSync.push()

        // Local repository — different tag, newer updated_at (pinned=false wins).
        let localRepo = FakeSyncRepository()
        await localRepo.seed(metadata: [
            UserMetadata(sessionID: sid,
                         isPinned: false,
                         note: "local-latest",
                         updatedAt: Date(timeIntervalSince1970: 200))
        ], tags: [
            Tag(id: 1, name: "local-only-tag", colorHue: 250)
        ], pairs: [
            (sid.description, "local-only-tag")
        ])

        let localSync = ICloudSync(repository: localRepo, containerURL: tmp)
        try await localSync.pull()

        // User metadata: local is newer, so local wins.
        let merged = try await localRepo.allUserMetadata()
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.note, "local-latest")
        XCTAssertEqual(merged.first?.isPinned, false)

        // Tags: both survive (union).
        let tagNames = Set(try await localRepo.allTagsForSync().map { $0.tag.name })
        XCTAssertTrue(tagNames.contains("remote-only-tag"))
        XCTAssertTrue(tagNames.contains("local-only-tag"))
    }

    // MARK: - Missing file — first pull on a fresh machine

    func test_pull_handles_missing_file_gracefully() async throws {
        let tmp = tempDir("missing")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let repo = FakeSyncRepository()
        let sync = ICloudSync(repository: repo, containerURL: tmp)

        // Should not throw — first-time pull on a fresh machine.
        try await sync.pull()

        let state = try await repo.allUserMetadata()
        XCTAssertTrue(state.isEmpty)
    }

    func test_availability_reports_unavailable_for_unreachable_path() async {
        // A path inside /dev/null-like territory — macOS can't create it.
        let unreachable = URL(fileURLWithPath: "/dev/null/chronicle-sync-impossible", isDirectory: true)
        let repo = FakeSyncRepository()
        let sync = ICloudSync(repository: repo, containerURL: unreachable)
        let availability = await sync.availability()
        if case .available = availability {
            XCTFail("expected unavailable for unreachable path")
        }
    }

    func test_reconcileOnBootstrap_pulls_then_pushes() async throws {
        let tmp = tempDir("recon")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let sid = sessionID(0x3c)
        let repo = FakeSyncRepository()
        await repo.seed(metadata: [
            UserMetadata(sessionID: sid,
                         isPinned: true,
                         updatedAt: Date(timeIntervalSince1970: 500))
        ], tags: [], pairs: [])
        let sync = ICloudSync(repository: repo, containerURL: tmp)

        try await sync.reconcileOnBootstrap()
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            tmp.appendingPathComponent("chronicle-sync.json").path))
    }

    func test_push_skips_builtin_smart_folders() async throws {
        let tmp = tempDir("builtins")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let repo = FakeSyncRepository()
        await repo.seed(
            metadata: [],
            tags: [],
            pairs: [],
            smartFolders: [
                SmartFolder(id: 1, name: "Today",       query: .today,       isBuiltIn: true),
                SmartFolder(id: 2, name: "My Stuff",    query: .thisWeek,    isBuiltIn: false),
            ]
        )

        let sync = ICloudSync(repository: repo, containerURL: tmp)
        try await sync.push()

        let data = try Data(contentsOf: tmp.appendingPathComponent("chronicle-sync.json"))
        let payload = try JSONDecoder().decode(ICloudSyncPayload.self, from: data)
        XCTAssertEqual(payload.smartFolders.count, 1)
        XCTAssertEqual(payload.smartFolders.first?.name, "My Stuff")
    }
}

// MARK: - In-memory double

/// Lightweight repo double that conforms to `SessionsSyncRepositoryProtocol`
/// without standing up a GRDB database. Supports seeding and the merge
/// semantics ICloudSync relies on.
actor FakeSyncRepository: SessionsSyncRepositoryProtocol {
    // Keys are now (provider, X) so two providers can hold a record for
    // the same session_id / tag name without colliding. Tests that
    // pre-date multi-provider seed everything as `.claude` and the
    // merge functions take `.claude` by default.
    private struct MetadataKey: Hashable { let provider: ProviderID; let sessionID: String }
    private struct TagKey: Hashable { let provider: ProviderID; let name: String }
    private struct FolderKey: Hashable { let provider: ProviderID; let name: String }

    private var metadata: [MetadataKey: UserMetadata] = [:]
    private var tagsByName: [TagKey: Tag] = [:]
    private var pairs: Set<String> = []  // "<provider>::<sid>::<tagname>"
    private var folders: [FolderKey: SmartFolder] = [:]

    func seed(metadata list: [UserMetadata],
              tags tagList: [Tag],
              pairs pairList: [(String, String)],
              smartFolders smartList: [SmartFolder] = []) {
        // Default to .claude for every seed so the existing v0.1.x tests
        // continue to exercise the same behaviour.
        for m in list {
            metadata[MetadataKey(provider: .claude, sessionID: m.sessionID.description)] = m
        }
        for t in tagList {
            tagsByName[TagKey(provider: .claude, name: t.name.lowercased())] = t
        }
        for (sid, name) in pairList {
            pairs.insert("claude::\(sid)::\(name.lowercased())")
        }
        for f in smartList {
            folders[FolderKey(provider: .claude, name: f.name.lowercased())] = f
        }
    }

    func allUserMetadataForSync() async throws -> [(metadata: UserMetadata, provider: ProviderID)] {
        metadata
            .map { ($0.value, $0.key.provider) }
            .sorted { $0.0.sessionID.description < $1.0.sessionID.description }
    }

    /// Test convenience: returns the metadata payload for the Claude
    /// namespace (the v0.1.x default), matching the shape pre-multi-
    /// provider tests expect.
    func allUserMetadata() async throws -> [UserMetadata] {
        metadata
            .filter { $0.key.provider == .claude }
            .map(\.value)
            .sorted { $0.sessionID.description < $1.sessionID.description }
    }

    func allTagsForSync() async throws -> [(tag: Tag, provider: ProviderID)] {
        tagsByName
            .map { ($0.value, $0.key.provider) }
            .sorted { $0.0.name.lowercased() < $1.0.name.lowercased() }
    }

    func allSessionTagPairsForSync() async throws -> [(sessionID: String, tagName: String, provider: ProviderID)] {
        pairs.map { entry -> (String, String, ProviderID) in
            let parts = entry.split(separator: "::", maxSplits: 2)
            let providerRaw = parts.indices.contains(0) ? String(parts[0]) : "claude"
            let sid = parts.indices.contains(1) ? String(parts[1]) : ""
            let name = parts.indices.contains(2) ? String(parts[2]) : ""
            let provider = ProviderID(rawValue: providerRaw) ?? .claude
            return (sid, name, provider)
        }.sorted { $0.0 < $1.0 }
    }

    func allSmartFoldersForSync() async throws -> [(folder: SmartFolder, provider: ProviderID)] {
        folders
            .map { ($0.value, $0.key.provider) }
            .sorted { $0.0.sortOrder < $1.0.sortOrder }
    }

    @discardableResult
    func mergeUserMetadata(_ remote: UserMetadata, provider: ProviderID = .claude) async throws -> Bool {
        let key = MetadataKey(provider: provider, sessionID: remote.sessionID.description)
        if let existing = metadata[key], existing.updatedAt >= remote.updatedAt {
            return false
        }
        metadata[key] = remote
        return true
    }

    @discardableResult
    func ensureTagForSync(name: String, colorHue: Int, provider: ProviderID = .claude) async throws -> Int64 {
        let key = TagKey(provider: provider, name: name.lowercased())
        if tagsByName[key] == nil {
            let nextID = Int64(tagsByName.count + 1)
            tagsByName[key] = Tag(id: nextID, name: name, colorHue: colorHue)
        }
        return tagsByName[key]?.id ?? 0
    }

    func attachTagForSync(sessionID: String, tagName: String, provider: ProviderID = .claude) async throws {
        pairs.insert("\(provider.rawValue)::\(sessionID)::\(tagName.lowercased())")
        _ = try await ensureTagForSync(name: tagName, colorHue: 30, provider: provider)
    }

    func ensureSmartFolderForSync(name: String,
                                   query: SmartFolderQuery,
                                   sortOrder: Int,
                                   provider: ProviderID = .claude) async throws {
        let key = FolderKey(provider: provider, name: name.lowercased())
        if folders[key] == nil {
            let nextID = Int64(folders.count + 1)
            folders[key] = SmartFolder(id: nextID,
                                       name: name,
                                       query: query,
                                       sortOrder: sortOrder,
                                       isBuiltIn: false)
        }
    }
}
