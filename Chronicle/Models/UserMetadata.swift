import Foundation
import SwiftUI

/// Per-session organisation state: pin / archive / soft-delete flags,
/// a user-chosen custom title that overrides the parsed first-message
/// title, and a freeform note string. Persisted in the `user_metadata`
/// SQLite table added in migration v4.
///
/// A session row may exist in `sessions_index` without a matching
/// `user_metadata` row; in that case the UI should substitute
/// `UserMetadata.empty(for:)` rather than treating absence as an error.
public struct UserMetadata: Equatable, Sendable, Identifiable {
    public let sessionID: SessionID
    public var isPinned: Bool
    public var isArchived: Bool
    public var isDeleted: Bool
    public var deletedAt: Date?
    public var customTitle: String?
    public var note: String?
    public var updatedAt: Date

    public var id: String { sessionID.description }

    public init(
        sessionID: SessionID,
        isPinned: Bool = false,
        isArchived: Bool = false,
        isDeleted: Bool = false,
        deletedAt: Date? = nil,
        customTitle: String? = nil,
        note: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.sessionID = sessionID
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.isDeleted = isDeleted
        self.deletedAt = deletedAt
        self.customTitle = customTitle
        self.note = note
        self.updatedAt = updatedAt
    }

    /// Default, never-written metadata for a session that has no
    /// `user_metadata` row yet. All booleans are false, no custom title, no note.
    public static func empty(for id: SessionID) -> UserMetadata {
        UserMetadata(sessionID: id, updatedAt: Date(timeIntervalSince1970: 0))
    }
}

// MARK: - Tag

/// A user-defined colour-tagged label applied to one or more sessions.
/// Persisted in the `tags` catalogue table; `session_tags` joins tags to sessions.
public struct Tag: Equatable, Hashable, Sendable, Identifiable, Codable {
    public let id: Int64
    public let name: String
    /// OKLCH hue angle, 0..360. Rendered at OKLCH(70% 0.16 hue) in UI.
    public let colorHue: Int

    public init(id: Int64, name: String, colorHue: Int) {
        self.id = id
        self.name = name
        self.colorHue = Self.clampHue(colorHue)
    }

    /// The approximate SwiftUI.Color corresponding to OKLCH(70% 0.16 hue).
    /// We precompute 8 canonical swatches for the common tag-picker palette
    /// (hues 250/145/300/75/200/30/180/100) and fall back to a hue-based
    /// HSB approximation for arbitrary values.
    public var swiftUIColor: Color {
        Self.oklchLike(hue: colorHue)
    }

    /// Canonical palette mirrored from the mockup + sidebar dot palette.
    public static let palette: [Int] = [250, 145, 300, 75, 200, 30, 180, 100]

    /// Normalise arbitrary int to [0, 360).
    internal static func clampHue(_ hue: Int) -> Int {
        let mod = hue % 360
        return mod >= 0 ? mod : mod + 360
    }

    /// Close-enough approximation of `oklch(70% 0.16 hue)` using HSB. Not
    /// color-space-accurate but consistent between the sidebar and tag pills.
    internal static func oklchLike(hue: Int) -> Color {
        let normalized = Double(clampHue(hue)) / 360.0
        // Saturation + brightness picked to roughly hit OKLCH L*=70% C=0.16.
        return Color(hue: normalized, saturation: 0.55, brightness: 0.82)
    }
}

// MARK: - SessionWithMetadata (view model)

/// Composite model combining a `SessionMetadata` DB row with its
/// user-metadata overlay and the tags applied to it. Returned from the
/// repository's organisation-aware queries (pinned / archived / by-tag) so
/// UI code can render `displayTitle`, star glyphs, and tag pills without a
/// second database round-trip per row.
public struct SessionWithMetadata: Equatable, Sendable, Identifiable {
    public let session: SessionMetadata
    public let userMetadata: UserMetadata
    public let tags: [Tag]

    public var id: String { session.sessionID.description }

    /// Prefer the user-chosen title if one exists. Falls back to whatever
    /// JsonlParser extracted from the session jsonl on bootstrap.
    public var displayTitle: String {
        if let custom = userMetadata.customTitle, !custom.isEmpty {
            return custom
        }
        return session.title
    }

    public var isPinned: Bool { userMetadata.isPinned }
    public var isArchived: Bool { userMetadata.isArchived }

    public init(session: SessionMetadata,
                userMetadata: UserMetadata,
                tags: [Tag]) {
        self.session = session
        self.userMetadata = userMetadata
        self.tags = tags
    }
}
