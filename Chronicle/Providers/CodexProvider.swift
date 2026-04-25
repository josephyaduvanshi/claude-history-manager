import Foundation

/// Codex CLI provider. Wires the `CodexParser`, `CodexWatcher`, and
/// `CodexResumeBuilder` into the multi-provider protocol.
///
/// Availability check: `~/.codex/sessions/` exists with at least one
/// rollout file. We check sessions first (vs the binary on PATH)
/// because a user with the Codex CLI installed but no recorded sessions
/// has nothing for Chronicle to surface — the tile would render empty.
public struct CodexProvider: Provider {
    public static let id: ProviderID = .codex
    public let displayName = "Codex"
    public let iconAssetName = "codex"

    public init() {}

    public func isAvailable() -> Bool {
        let root = Self.sessionsRoot()
        guard FileManager.default.fileExists(atPath: root.path) else { return false }
        // Stop as soon as we find one rollout file. Walking the entire
        // tree on every launch would be wasteful — we only care that at
        // least one session was recorded by the CLI.
        return Self.hasAnyRolloutFile(under: root)
    }

    public func watchRoots() -> [URL] { [Self.sessionsRoot()] }

    public func makeParser() -> any SessionParser { CodexParser() }

    public func resumeCommand(
        sessionID: String,
        cwd: String,
        terminal: Terminal,
        loginShell: String
    ) -> LaunchCommand {
        CodexResumeBuilder(loginShell: loginShell)
            .build(terminal: terminal, sessionID: sessionID, cwd: cwd)
    }

    public static func sessionsRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    public static func indexFile() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/session_index.jsonl", isDirectory: false)
    }

    /// Walks the date-bucketed `sessions/` tree and returns true on the
    /// first `rollout-*.jsonl` it sees. Bounded by depth (year/month/day)
    /// so it can't run away on a corrupted Codex install.
    private static func hasAnyRolloutFile(under root: URL) -> Bool {
        let fm = FileManager.default
        guard let years = try? fm.contentsOfDirectory(at: root,
                                                      includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles])
        else { return false }
        for year in years {
            guard let months = try? fm.contentsOfDirectory(at: year,
                                                           includingPropertiesForKeys: nil,
                                                           options: [.skipsHiddenFiles])
            else { continue }
            for month in months {
                guard let days = try? fm.contentsOfDirectory(at: month,
                                                             includingPropertiesForKeys: nil,
                                                             options: [.skipsHiddenFiles])
                else { continue }
                for day in days {
                    guard let files = try? fm.contentsOfDirectory(at: day,
                                                                  includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])
                    else { continue }
                    if files.contains(where: { $0.lastPathComponent.hasPrefix("rollout-")
                                                && $0.pathExtension == "jsonl" }) {
                        return true
                    }
                }
            }
        }
        return false
    }
}
