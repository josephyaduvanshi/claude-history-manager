import Foundation

/// Claude Code provider. Wraps the v0.1.x JSONL pipeline (`JsonlParser`,
/// the FSEvents watcher in `SessionsWatcher`, and `SessionLauncher`'s
/// resume command builder) so it slots into the multi-provider
/// architecture without rewiring existing code paths.
///
/// The actual file moves promised in the multi-provider design spec
/// (parser → `Parsers/ClaudeParser.swift`, watcher →
/// `Watchers/ClaudeWatcher.swift`, launcher →
/// `Launchers/ClaudeResumeBuilder.swift`) are left for follow-up phases
/// — for v0.2 P1, having `ClaudeProvider` expose the existing types
/// through the `Provider` protocol is sufficient and keeps the diff
/// scoped.
public struct ClaudeProvider: Provider {
    public static let id: ProviderID = .claude
    public let displayName = "Claude Code"
    public let iconAssetName = "claude"

    public init() {}

    public func isAvailable() -> Bool {
        Self.projectsRoot().map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? false
    }

    public func watchRoots() -> [URL] {
        Self.projectsRoot().map { [$0] } ?? []
    }

    public func makeParser() -> any SessionParser {
        ClaudeParserAdapter()
    }

    public func resumeCommand(
        sessionID: String,
        cwd: String,
        terminal: Terminal,
        loginShell: String
    ) -> LaunchCommand {
        ClaudeResumeBuilder(loginShell: loginShell).build(
            terminal: terminal,
            sessionID: sessionID,
            cwd: cwd
        )
    }

    /// `~/.claude/projects/`. Returns `nil` if the home directory can't
    /// be resolved (effectively unreachable on macOS, but FSCS-aware
    /// rather than force-unwrapping).
    public static func projectsRoot() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude/projects", isDirectory: true)
    }
}

/// Bridges the existing `JsonlParser` to the new `SessionParser` protocol
/// without moving the parser source file. Keeps Phase 1 surgery to a
/// minimum; Phase 2/3 can collapse this if a real `ClaudeParser` file
/// gets carved out.
private struct ClaudeParserAdapter: SessionParser {
    private let inner = JsonlParser()
    func parse(url: URL, workspaceID: String) throws -> (SessionMetadata, Set<String>) {
        try inner.parseWithFlags(url: url, workspaceID: workspaceID)
    }
}

/// Resume-command builder for Claude Code. Mirrors the per-terminal
/// recipes from `SessionLauncher.buildCommand(...)` so the launcher
/// can delegate to a per-provider builder once the multi-provider
/// switch is wired up. The actual launcher still owns dispatch
/// (AppleScript vs `Process.run`) and wezterm/kitty CLI resolution.
public struct ClaudeResumeBuilder: Sendable {
    private let loginShell: String

    public init(loginShell: String = SessionLauncher.resolveLoginShell()) {
        self.loginShell = loginShell
    }

    public func build(
        terminal: Terminal,
        sessionID: String,
        cwd: String
    ) -> LaunchCommand {
        let escaped = SessionLauncher.shellEscapeInsideDoubleQuotes(cwd)
        let shellCmd = #"cd "\#(escaped)" && claude --resume \#(sessionID)"#
        return Self.commandFor(
            terminal: terminal,
            cwd: cwd,
            shellCmd: shellCmd,
            loginShell: loginShell
        )
    }

    /// Per-terminal command recipe. Pulled out as a static so Codex /
    /// Gemini builders can reuse it by passing their own `shellCmd` tail.
    public static func commandFor(
        terminal: Terminal,
        cwd: String,
        shellCmd: String,
        loginShell: String
    ) -> LaunchCommand {
        switch terminal {
        case .ghostty:
            return LaunchCommand(
                executable: "/usr/bin/open",
                arguments: [
                    "-na", "Ghostty",
                    "--args",
                    "--working-directory=\(cwd)",
                    "-e", loginShell, "-i", "-c", shellCmd,
                ]
            )

        case .alacritty:
            return LaunchCommand(
                executable: "/usr/bin/open",
                arguments: [
                    "-na", "Alacritty",
                    "--args",
                    "--working-directory", cwd,
                    "-e", loginShell, "-i", "-c", shellCmd,
                ]
            )

        case .iterm:
            let appleQuoted = SessionLauncher.escapeForAppleScriptString(shellCmd)
            let script = """
            tell application "iTerm"
                activate
                create window with default profile
                tell current session of current window
                    write text "\(appleQuoted)"
                end tell
            end tell
            """
            return LaunchCommand(
                executable: "/usr/bin/osascript",
                arguments: ["-e", script],
                appleScript: script
            )

        case .terminal:
            let appleQuoted = SessionLauncher.escapeForAppleScriptString(shellCmd)
            let script = """
            tell application "Terminal"
                activate
                do script "\(appleQuoted)"
            end tell
            """
            return LaunchCommand(
                executable: "/usr/bin/osascript",
                arguments: ["-e", script],
                appleScript: script
            )

        case .wezterm:
            let exec = terminal.cliExecutable(using: .default)
                ?? terminal.cliExecutableCandidates.first
                ?? "wezterm"
            return LaunchCommand(
                executable: exec,
                arguments: [
                    "start",
                    "--cwd", cwd,
                    "--",
                    loginShell, "-i", "-c", shellCmd,
                ]
            )

        case .kitty:
            let exec = terminal.cliExecutable(using: .default)
                ?? terminal.cliExecutableCandidates.first
                ?? "kitty"
            return LaunchCommand(
                executable: exec,
                arguments: [
                    "--directory", cwd,
                    loginShell, "-i", "-c", shellCmd,
                ]
            )
        }
    }
}
