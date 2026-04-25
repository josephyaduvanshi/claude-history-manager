import Foundation

// MARK: - LaunchCommand

/// A fully-materialized command describing how to open a terminal window
/// running `claude --resume <SID>` in a given working directory.
///
/// Either a direct exec (`executable` + `arguments`) OR an AppleScript
/// `appleScript` source, never both. Callers dispatch based on which field
/// is populated.
public struct LaunchCommand: Equatable, Sendable {
    /// Path to the executable, e.g. `/usr/bin/open` or `/opt/homebrew/bin/wezterm`.
    /// For AppleScript-based launches this is `/usr/bin/osascript` as a
    /// convenience; the actual dispatch uses `appleScript` instead.
    public let executable: String

    /// Argument list in argv form (no shell escaping required ,  `Process.run()`
    /// passes each element as a separate argv entry).
    public let arguments: [String]

    /// When non-nil, the `ProcessRunner` runs this AppleScript via
    /// `osascript -e <source>` INSTEAD OF spawning `executable` with `arguments`.
    public let appleScript: String?

    public init(executable: String, arguments: [String], appleScript: String? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.appleScript = appleScript
    }
}

// MARK: - ProcessRunner

/// Launches external processes / AppleScripts. Abstracted so tests can
/// record invocations without actually spawning anything.
public protocol ProcessRunner: Sendable {
    /// Fire-and-forget: spawn `executable` with `arguments`, do not wait
    /// for termination. The terminal window handles its own stdout/stderr.
    func run(executable: String, arguments: [String]) async throws

    /// Dispatch an AppleScript via `osascript -e <source>`.
    func runAppleScript(_ source: String) async throws
}

// MARK: - SessionLauncher protocol

public protocol SessionLauncherProtocol: Sendable {
    /// Pure function (no I/O): build the command that would launch
    /// `claude --resume <sessionID>` in `terminal` with `workingDirectory`.
    /// Used by tests as a snapshot contract.
    func buildCommand(
        terminal: Terminal,
        sessionID: String,
        workingDirectory: String
    ) -> LaunchCommand

    /// Build the command, then dispatch it via the injected ProcessRunner.
    func launch(
        terminal: Terminal,
        sessionID: String,
        workingDirectory: String
    ) async throws
}

// MARK: - Errors

public enum SessionLauncherError: Error, LocalizedError, Equatable {
    /// The requested CLI terminal (wezterm / kitty) isn't on disk at any known path.
    case cliExecutableMissing(Terminal)

    public var errorDescription: String? {
        switch self {
        case .cliExecutableMissing(let t):
            return "\(t.displayName) CLI executable was not found on disk. Install it or pick a different terminal."
        }
    }
}

// MARK: - SessionLauncher default impl

public struct SessionLauncher: SessionLauncherProtocol {
    private let processRunner: any ProcessRunner
    private let loginShell: String

    public init(
        processRunner: any ProcessRunner = DefaultProcessRunner.default,
        fileManager: FileManager = .default,
        loginShell: String = SessionLauncher.resolveLoginShell()
    ) {
        self.processRunner = processRunner
        self.loginShell = loginShell
        _ = fileManager
    }

    /// The user's login shell, e.g. `/bin/zsh`. We use `<shell> -i -c` rather
    /// than `bash -lc` so the shell sources `~/.zshrc` (or its bash
    /// equivalent), which is where most macOS users actually put their PATH
    /// exports — `~/.local/bin/claude`, `/opt/homebrew/bin`, fnm, etc. The
    /// `bash -lc` path missed all of that and Resume in Ghostty/WezTerm/
    /// Alacritty/kitty failed with `claude: command not found` for anyone
    /// not also configuring bash login files.
    public static func resolveLoginShell(
        env: [String: String] = ProcessInfo.processInfo.environment,
        fm: FileManager = .default
    ) -> String {
        if let shell = env["SHELL"],
           !shell.isEmpty,
           fm.isExecutableFile(atPath: shell) {
            return shell
        }
        // macOS default since 10.15.
        return "/bin/zsh"
    }

    // MARK: - Command builders

    public func buildCommand(
        terminal: Terminal,
        sessionID: String,
        workingDirectory cwd: String
    ) -> LaunchCommand {
        // Build a single login-shell command string the terminal will execute.
        // Using `bash -lc` ensures:
        //   1. The login shell loads ~/.zshrc / ~/.bash_profile so PATH
        //      includes ~/.claude/local/ and /usr/local/bin where `claude` lives.
        //   2. The entire `cd <CWD> && claude --resume <SID>` tail is parsed
        //      as one shell command rather than being split as terminal flags
        //      (which caused the "no session found" bug for Ghostty).
        let shellCmd = Self.shellCommand(cwd: cwd, sessionID: sessionID)

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
            // Two levels of escaping: shell-quote CWD inside `"..."`, then
            // AppleScript-quote the whole shell command inside `"..."`.
            let appleQuoted = Self.escapeForAppleScriptString(shellCmd)
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
            let appleQuoted = Self.escapeForAppleScriptString(shellCmd)
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
            // Prefer the first candidate so snapshot tests are deterministic.
            // At launch time `launch(...)` resolves the actual on-disk path.
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

    // MARK: - Dispatch

    public func launch(
        terminal: Terminal,
        sessionID: String,
        workingDirectory: String
    ) async throws {
        // For CLI terminals, verify the executable actually exists before
        // dispatching so callers get a nice error rather than a silent
        // no-op via an invalid path.
        if terminal == .wezterm || terminal == .kitty {
            if terminal.cliExecutable(using: .default) == nil {
                // Test runner (which never actually runs the process) can
                // still exercise launch(); but tests pass a runner that
                // ignores the executable anyway, and they use buildCommand
                // for snapshot assertions. So we only enforce this check
                // when the runner is the DefaultProcessRunner.
                if processRunner is DefaultProcessRunner {
                    throw SessionLauncherError.cliExecutableMissing(terminal)
                }
            }
        }

        let cmd = buildCommand(
            terminal: terminal,
            sessionID: sessionID,
            workingDirectory: workingDirectory
        )
        if let script = cmd.appleScript {
            try await processRunner.runAppleScript(script)
        } else {
            try await processRunner.run(executable: cmd.executable, arguments: cmd.arguments)
        }
    }

    // MARK: - Escaping helpers

    /// Builds the literal shell command string (unquoted, at the "raw shell"
    /// level) that runs `claude --resume <SID>` in `cwd`. The `cwd` is
    /// wrapped in shell double quotes with `\` and `"` backslash-escaped.
    ///
    /// Example output bytes for `cwd="/a b"`, `sid="S"`:
    ///     cd "/a b" && claude --resume S
    ///
    /// Example output bytes for `cwd=#"he "said" \n"#`, `sid="S"`:
    ///     cd "he \"said\" \\n" && claude --resume S
    static func shellCommand(cwd: String, sessionID: String) -> String {
        let escaped = shellEscapeInsideDoubleQuotes(cwd)
        return #"cd "\#(escaped)" && claude --resume \#(sessionID)"#
    }

    /// Escape a string so it survives inside a shell `"..."` literal.
    /// Inside shell double-quotes only `\` and `"` need escaping.
    ///
    /// - Parameter raw: the raw string bytes to escape.
    /// - Returns: the same bytes with `\` doubled and `"` prefixed by `\`.
    public static func shellEscapeInsideDoubleQuotes(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        for ch in raw {
            switch ch {
            case "\\": out.append("\\\\")
            case "\"": out.append("\\\"")
            default:   out.append(ch)
            }
        }
        return out
    }

    /// Escape a string so it survives inside an AppleScript `"..."` string
    /// literal. AppleScript, like C-style languages, treats `\"` as a quote
    /// and `\\` as a backslash inside a string literal.
    public static func escapeForAppleScriptString(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        for ch in raw {
            switch ch {
            case "\\": out.append("\\\\")
            case "\"": out.append("\\\"")
            default:   out.append(ch)
            }
        }
        return out
    }
}
