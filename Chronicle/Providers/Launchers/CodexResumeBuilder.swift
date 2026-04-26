import Foundation

/// Resume-command builder for Codex CLI. The non-interactive resume
/// invocation is `codex resume <uuid>` — it's a subcommand, not a flag,
/// and it expects only the UUID (no `--id=` prefix).
///
/// Mirrors `ClaudeResumeBuilder` but emits the Codex tail; everything
/// else (per-terminal AppleScript / open-flag plumbing) is shared with
/// `ClaudeResumeBuilder.commandFor(...)`.
public struct CodexResumeBuilder: Sendable {
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
        let shellCmd = #"cd "\#(escaped)" && codex resume \#(sessionID)"#
        return ClaudeResumeBuilder.commandFor(
            terminal: terminal,
            cwd: cwd,
            shellCmd: shellCmd,
            loginShell: loginShell
        )
    }
}
