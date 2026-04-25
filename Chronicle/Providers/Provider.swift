import Foundation

/// Identifies a CLI session source (Claude Code, Codex, Gemini).
/// String-backed so it round-trips trivially through SQLite, JSON,
/// and UserDefaults without bespoke encoders.
public enum ProviderID: String, CaseIterable, Sendable, Codable, Hashable {
    case claude
    case codex
    case gemini

    /// Human-facing label used by the segmented control and menubar
    /// tile grid. Kept on the enum so neither view has to repeat the
    /// switch (and so a future renaming lands in one place).
    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        case .gemini: return "Gemini"
        }
    }

    /// SF Symbol name used as a monochrome glyph on tiles. Picked so
    /// each provider reads as a distinct shape at small sizes:
    ///
    /// - **Claude** → `sparkle` — Anthropic's mark is a stylised
    ///   four-pointed sparkle.
    /// - **Codex** → `hexagon` — OpenAI's primary container shape.
    /// - **Gemini** → `diamond` — Google's spark glyph reads as a
    ///   four-pointed diamond at icon sizes.
    ///
    /// The shapes are intentionally generic monochrome SF Symbols
    /// rather than vendored brand assets — the latter often have
    /// trademark restrictions on third-party redistribution. SF
    /// Symbols ship with macOS and tint via `.foregroundStyle()`
    /// without any asset-catalog setup.
    public var iconSymbol: String {
        switch self {
        case .claude: return "sparkle"
        case .codex:  return "hexagon"
        case .gemini: return "diamond"
        }
    }
}

/// Adapter for one CLI's session storage. Each conformer knows how to:
///  - detect whether the CLI is installed / has data on disk,
///  - point the watcher at the right roots,
///  - parse the source format into the canonical `SessionMetadata` shape,
///  - build a resume command the existing `SessionLauncher` can dispatch.
///
/// The protocol is intentionally small: anything fancier (token math,
/// per-message metadata) lives downstream of `parse(url:workspaceID:)`
/// returning a uniform `SessionMetadata` regardless of provider.
public protocol Provider: Sendable {
    /// Compile-time provider identity. Used as the `provider` column value
    /// in every metadata table and as the registry key.
    static var id: ProviderID { get }

    /// Human-facing label for the segmented control / tile grid.
    var displayName: String { get }

    /// Asset name (without extension) under
    /// `Chronicle/Resources/ProviderIcons/`. Vendored monochrome SVG.
    var iconAssetName: String { get }

    /// True when the CLI looks usable on this machine — typically when
    /// its session storage dir exists with at least one session in it.
    /// Tiles for unavailable providers are not rendered.
    func isAvailable() -> Bool

    /// One or more roots for the watcher to observe. Multiple for Gemini
    /// (one per project_hash); single-element for Claude / Codex.
    func watchRoots() -> [URL]

    /// Returns the parser bound to this provider's on-disk format.
    func makeParser() -> any SessionParser

    /// Build a resume command. The existing `SessionLauncher` dispatches
    /// the returned `LaunchCommand`; only the per-provider command tail
    /// (`claude --resume <id>` vs `codex resume <id>` vs
    /// `gemini --resume <id>`) varies.
    func resumeCommand(
        sessionID: String,
        cwd: String,
        terminal: Terminal,
        loginShell: String
    ) -> LaunchCommand
}

public extension Provider {
    /// Convenience: instance-side access to the static id, useful when
    /// holding `any Provider` and you don't have the concrete type to hand.
    var id: ProviderID { type(of: self).id }
}

/// Parses one session file into the canonical `SessionMetadata` shape
/// plus any `session_flags` derived during parse. Each provider implements
/// against its own on-disk format (JSONL / single-JSON / etc).
public protocol SessionParser: Sendable {
    /// Read a session file and produce metadata + flags. The `workspaceID`
    /// is whatever the indexer is using to bucket sessions for this
    /// provider — for Claude, the `<encoded-cwd>` string; for Codex /
    /// Gemini, the provider-derived workspace key.
    func parse(url: URL, workspaceID: String) throws -> (SessionMetadata, Set<String>)
}
