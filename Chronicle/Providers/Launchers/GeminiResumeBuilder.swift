import Foundation

/// Resume-command builder for Gemini CLI. Non-interactive resume is
/// `gemini --resume <uuid>`. Stick to the UUID form: the numeric
/// `--resume <index>` form Gemini also supports renumbers as new
/// sessions land, so a stored Chronicle URL would silently jump to a
/// different session over time.
///
/// Reuses `ClaudeResumeBuilder.commandFor(...)` for per-terminal
/// plumbing; only the shell command tail is provider-specific.
public struct GeminiResumeBuilder: Sendable {
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
        let shellCmd = #"cd "\#(escaped)" && gemini --resume \#(sessionID)"#
        return ClaudeResumeBuilder.commandFor(
            terminal: terminal,
            cwd: cwd,
            shellCmd: shellCmd,
            loginShell: loginShell
        )
    }
}
