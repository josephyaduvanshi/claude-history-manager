import Foundation

// MARK: - Payload

/// Serialised user metadata exchanged via iCloud Drive. Version is bumped if
/// we ever change the on-disk shape in a backwards-incompatible way.
public struct ICloudSyncPayload: Codable, Equatable, Sendable {
    public static let currentVersion: Int = 1

    public struct UserMetadataEnvelope: Codable, Equatable, Sendable {
        public var sessionID: String
        public var isPinned: Bool
        public var isArchived: Bool
        public var isDeleted: Bool
        public var deletedAt: Int64?
        public var customTitle: String?
        public var note: String?
        public var updatedAt: Int64
        /// Provider whose namespace this record belongs to. Optional in
        /// the wire format so v0.1.6 records — which never wrote this
        /// field — decode as `.claude`. v0.2+ writers always populate it.
        public var provider: String?

        public init(sessionID: String,
                    isPinned: Bool,
                    isArchived: Bool,
                    isDeleted: Bool,
                    deletedAt: Int64?,
                    customTitle: String?,
                    note: String?,
                    updatedAt: Int64,
                    provider: String? = nil) {
            self.sessionID = sessionID
            self.isPinned = isPinned
            self.isArchived = isArchived
            self.isDeleted = isDeleted
            self.deletedAt = deletedAt
            self.customTitle = customTitle
            self.note = note
            self.updatedAt = updatedAt
            self.provider = provider
        }

        public init(from local: UserMetadata, provider: ProviderID) {
            self.sessionID = local.sessionID.description
            self.isPinned = local.isPinned
            self.isArchived = local.isArchived
            self.isDeleted = local.isDeleted
            self.deletedAt = local.deletedAt.map { Int64($0.timeIntervalSince1970.rounded()) }
            self.customTitle = local.customTitle
            self.note = local.note
            self.updatedAt = Int64(local.updatedAt.timeIntervalSince1970.rounded())
            self.provider = provider.rawValue
        }

        /// Provider parsed from the wire field, defaulting to `.claude`
        /// for legacy records or unknown values. Read by the merger to
        /// decide which provider's metadata table the record lands in.
        public var resolvedProvider: ProviderID {
            ProviderID(rawValue: provider ?? "claude") ?? .claude
        }

        /// Hydrate to a `UserMetadata`, returns nil if the `sessionID`
        /// string can't be parsed as a UUID.
        public func toUserMetadata() -> UserMetadata? {
            guard let sid = try? SessionID(string: sessionID) else { return nil }
            return UserMetadata(
                sessionID: sid,
                isPinned: isPinned,
                isArchived: isArchived,
                isDeleted: isDeleted,
                deletedAt: deletedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                customTitle: customTitle,
                note: note,
                updatedAt: Date(timeIntervalSince1970: TimeInterval(updatedAt))
            )
        }
    }

    public struct TagEnvelope: Codable, Equatable, Sendable {
        public var name: String
        public var colorHue: Int
        public var provider: String?

        public init(name: String, colorHue: Int, provider: String? = nil) {
            self.name = name
            self.colorHue = colorHue
            self.provider = provider
        }

        public var resolvedProvider: ProviderID {
            ProviderID(rawValue: provider ?? "claude") ?? .claude
        }
    }

    public struct SessionTagEnvelope: Codable, Equatable, Sendable {
        public var sessionID: String
        public var tagName: String
        public var provider: String?

        public init(sessionID: String, tagName: String, provider: String? = nil) {
            self.sessionID = sessionID
            self.tagName = tagName
            self.provider = provider
        }

        public var resolvedProvider: ProviderID {
            ProviderID(rawValue: provider ?? "claude") ?? .claude
        }
    }

    public struct SmartFolderEnvelope: Codable, Equatable, Sendable {
        public var name: String
        public var query: SmartFolderQuery
        public var sortOrder: Int
        public var provider: String?

        public init(name: String, query: SmartFolderQuery, sortOrder: Int, provider: String? = nil) {
            self.name = name
            self.query = query
            self.sortOrder = sortOrder
            self.provider = provider
        }

        public var resolvedProvider: ProviderID {
            ProviderID(rawValue: provider ?? "claude") ?? .claude
        }
    }

    public var version: Int
    public var exportedAt: String
    public var userMetadata: [UserMetadataEnvelope]
    public var tags: [TagEnvelope]
    public var sessionTags: [SessionTagEnvelope]
    public var smartFolders: [SmartFolderEnvelope]

    public init(version: Int = ICloudSyncPayload.currentVersion,
                exportedAt: String,
                userMetadata: [UserMetadataEnvelope],
                tags: [TagEnvelope],
                sessionTags: [SessionTagEnvelope],
                smartFolders: [SmartFolderEnvelope]) {
        self.version = version
        self.exportedAt = exportedAt
        self.userMetadata = userMetadata
        self.tags = tags
        self.sessionTags = sessionTags
        self.smartFolders = smartFolders
    }

    enum CodingKeys: String, CodingKey {
        case version
        case exportedAt = "exported_at"
        case userMetadata = "user_metadata"
        case tags
        case sessionTags = "session_tags"
        case smartFolders = "smart_folders"
    }
}

// MARK: - Availability

/// Cosmetic flag for UI. `ICloudSync` never throws for a missing directory;
/// callers can use this to disable the Settings row pre-emptively.
public enum ICloudSyncAvailability: Sendable, Equatable {
    case unavailable(reason: String)
    case available

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

// MARK: - ICloudSync

/// Reads and writes `chronicle-sync.json` inside the user's iCloud Drive
/// Chronicle folder. Metadata only; transcripts never leave local disk.
///
/// Why iCloud Drive files instead of CloudKit records? CloudKit requires the
/// app to be signed with a paid Apple Developer ID and carry a CloudKit
/// entitlement. Chronicle ships ad-hoc signed (no $99/year DevID), so we
/// fall back to a JSON file inside the user's Mobile Documents container.
/// The OS handles cross-device replication for us.
public actor ICloudSync {
    public let containerURL: URL
    public let fileName: String
    private let repository: SessionsSyncRepositoryProtocol
    private let fm: FileManager
    private let now: @Sendable () -> Date

    public init(repository: SessionsSyncRepositoryProtocol,
                containerURL: URL,
                fileName: String = "chronicle-sync.json",
                fileManager: FileManager = .default,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.repository = repository
        self.containerURL = containerURL
        self.fileName = fileName
        self.fm = fileManager
        self.now = now
    }

    /// The resolved URL of the JSON file. Kept as a computed property so
    /// tests can pass a per-test temp directory at init time.
    public var fileURL: URL {
        containerURL.appendingPathComponent(fileName, isDirectory: false)
    }

    /// Whether the container directory is writable. Returns `.unavailable`
    /// with a human-readable reason when the container can't be reached.
    public func availability() -> ICloudSyncAvailability {
        // Create the container if it's missing but reachable.
        do {
            if !fm.fileExists(atPath: containerURL.path) {
                try fm.createDirectory(at: containerURL,
                                       withIntermediateDirectories: true)
            }
            // Writability probe; try to open the container and check attrs.
            let attrs = try fm.attributesOfItem(atPath: containerURL.path)
            _ = attrs
            return .available
        } catch {
            return .unavailable(reason: error.localizedDescription)
        }
    }

    // MARK: - Push (local -> file)

    public func push() async throws {
        let userMeta = try await repository.allUserMetadataForSync()
        let tags     = try await repository.allTagsForSync()
        let pairs    = try await repository.allSessionTagPairsForSync()
        let folders  = try await repository.allSmartFoldersForSync()

        let payload = ICloudSyncPayload(
            exportedAt: Self.iso8601.string(from: now()),
            userMetadata: userMeta.map { (m, provider) in
                ICloudSyncPayload.UserMetadataEnvelope(from: m, provider: provider)
            },
            tags: tags.map { (t, provider) in
                ICloudSyncPayload.TagEnvelope(name: t.name, colorHue: t.colorHue, provider: provider.rawValue)
            },
            sessionTags: pairs.map { (sid, name, provider) in
                ICloudSyncPayload.SessionTagEnvelope(sessionID: sid, tagName: name, provider: provider.rawValue)
            },
            smartFolders: folders.compactMap { (f, provider) in
                // Built-ins are re-seeded per-provider on bootstrap; no point syncing them.
                guard !f.isBuiltIn else { return nil }
                return ICloudSyncPayload.SmartFolderEnvelope(
                    name: f.name,
                    query: f.query,
                    sortOrder: f.sortOrder,
                    provider: provider.rawValue
                )
            }
        )

        try writeAtomically(payload: payload)
        AppLogger.sync.info(
            "push: wrote \(payload.userMetadata.count) metadata, "
            + "\(payload.tags.count) tags, \(payload.smartFolders.count) smart folders"
        )
    }

    private func writeAtomically(payload: ICloudSyncPayload) throws {
        try ensureContainerDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        try data.write(to: fileURL, options: [.atomic])
    }

    // MARK: - Pull (file -> local)

    /// Read the remote file and merge into local state. No-ops gracefully if
    /// the file doesn't exist yet (first-ever launch on a second machine).
    public func pull() async throws {
        guard fm.fileExists(atPath: fileURL.path) else {
            AppLogger.sync.info("pull: \(fileURL.lastPathComponent) missing, skipping")
            return
        }
        let data = try Data(contentsOf: fileURL)
        let payload: ICloudSyncPayload
        do {
            payload = try JSONDecoder().decode(ICloudSyncPayload.self, from: data)
        } catch {
            AppLogger.sync.warn("pull: payload decode failed: \(error.localizedDescription)")
            throw error
        }

        // 1. User metadata; newer-wins via updatedAt, scoped per provider.
        //    Records lacking a provider field decode as `.claude` so a v0.1.6
        //    payload imports cleanly under the Claude namespace.
        for envelope in payload.userMetadata {
            guard let remote = envelope.toUserMetadata() else { continue }
            try await repository.mergeUserMetadata(remote, provider: envelope.resolvedProvider)
        }

        // 2. Tags. UNION per-provider. Ensure every tag in the payload
        //    exists locally under its own provider's namespace.
        for tag in payload.tags {
            _ = try? await repository.ensureTagForSync(
                name: tag.name,
                colorHue: tag.colorHue,
                provider: tag.resolvedProvider
            )
        }

        // 3. Session<->tag pairs. UNION per-provider.
        for pair in payload.sessionTags {
            try? await repository.attachTagForSync(
                sessionID: pair.sessionID,
                tagName: pair.tagName,
                provider: pair.resolvedProvider
            )
        }

        // 4. Smart folders; dedupe by name within each provider; built-ins
        //    are re-seeded per-provider on bootstrap.
        for folder in payload.smartFolders {
            try? await repository.ensureSmartFolderForSync(
                name: folder.name,
                query: folder.query,
                sortOrder: folder.sortOrder,
                provider: folder.resolvedProvider
            )
        }

        AppLogger.sync.info(
            "pull: merged \(payload.userMetadata.count) metadata rows, "
            + "\(payload.tags.count) tags, \(payload.smartFolders.count) smart folders"
        )
    }

    /// Pull (merge remote into local) and immediately push (so the remote
    /// also gains any newly-local rows). Use at app bootstrap.
    public func reconcileOnBootstrap() async throws {
        switch availability() {
        case .unavailable(let reason):
            AppLogger.sync.warn("sync disabled: \(reason)")
            return
        case .available:
            break
        }
        try await pull()
        try await push()
    }

    // MARK: - Helpers

    private func ensureContainerDirectory() throws {
        if !fm.fileExists(atPath: containerURL.path) {
            try fm.createDirectory(at: containerURL,
                                   withIntermediateDirectories: true)
        }
    }

    /// iCloud Drive's default Chronicle directory:
    /// `~/Library/Mobile Documents/com~apple~CloudDocs/Chronicle/`
    public static func defaultContainerURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Chronicle",
                                    isDirectory: true)
    }

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
