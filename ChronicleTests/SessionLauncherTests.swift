import XCTest
@testable import Chronicle

// MARK: - Test doubles

/// Records every invocation. Used in place of DefaultProcessRunner in tests.
final class TestProcessRunner: ProcessRunner, @unchecked Sendable {
    struct Invocation: Equatable {
        let executable: String
        let arguments: [String]
        let appleScript: String?
    }

    private let lock = NSLock()
    private var _invocations: [Invocation] = []

    var invocations: [Invocation] {
        lock.lock(); defer { lock.unlock() }
        return _invocations
    }

    func run(executable: String, arguments: [String]) async throws {
        lock.lock(); defer { lock.unlock() }
        _invocations.append(Invocation(executable: executable, arguments: arguments, appleScript: nil))
    }

    func runAppleScript(_ source: String) async throws {
        lock.lock(); defer { lock.unlock() }
        _invocations.append(Invocation(executable: "/usr/bin/osascript", arguments: ["-e", source], appleScript: source))
    }
}

// MARK: - Snapshot tests for every terminal

final class SessionLauncherTests: XCTestCase {

    private let sessionID = "11111111-1111-1111-1111-111111111111"
    private let cwd = "/Users/dev/project name/aayo"
    /// Fixed shell for snapshot determinism. Production code resolves
    /// `$SHELL` at runtime via `SessionLauncher.resolveLoginShell()`.
    private let testShell = "/bin/zsh"

    private func makeLauncher(runner: TestProcessRunner = TestProcessRunner()) -> SessionLauncher {
        SessionLauncher(processRunner: runner, loginShell: testShell)
    }

    // MARK: Ghostty

    func test_buildCommand_ghostty_snapshot() {
        let launcher = makeLauncher()
        let cmd = launcher.buildCommand(terminal: .ghostty, sessionID: sessionID, workingDirectory: cwd)

        XCTAssertEqual(cmd.executable, "/usr/bin/open")
        XCTAssertEqual(cmd.arguments, [
            "-na", "Ghostty",
            "--args",
            "--working-directory=/Users/dev/project name/aayo",
            "-e", testShell, "-i", "-c",
            #"cd "/Users/dev/project name/aayo" && claude --resume 11111111-1111-1111-1111-111111111111"#,
        ])
        XCTAssertNil(cmd.appleScript)
    }

    // MARK: Alacritty

    func test_buildCommand_alacritty_snapshot() {
        let launcher = makeLauncher()
        let cmd = launcher.buildCommand(terminal: .alacritty, sessionID: sessionID, workingDirectory: cwd)

        XCTAssertEqual(cmd.executable, "/usr/bin/open")
        XCTAssertEqual(cmd.arguments, [
            "-na", "Alacritty",
            "--args",
            "--working-directory", "/Users/dev/project name/aayo",
            "-e", testShell, "-i", "-c",
            #"cd "/Users/dev/project name/aayo" && claude --resume 11111111-1111-1111-1111-111111111111"#,
        ])
        XCTAssertNil(cmd.appleScript)
    }

    // MARK: iTerm

    func test_buildCommand_iterm_snapshot() {
        let launcher = makeLauncher()
        let cmd = launcher.buildCommand(terminal: .iterm, sessionID: sessionID, workingDirectory: cwd)

        XCTAssertEqual(cmd.executable, "/usr/bin/osascript")

        let expected = #"""
        tell application "iTerm"
            activate
            create window with default profile
            tell current session of current window
                write text "cd \"/Users/dev/project name/aayo\" && claude --resume 11111111-1111-1111-1111-111111111111"
            end tell
        end tell
        """#
        XCTAssertEqual(cmd.appleScript, expected)
        XCTAssertEqual(cmd.arguments, ["-e", expected])
    }

    // MARK: Terminal.app

    func test_buildCommand_terminal_snapshot() {
        let launcher = makeLauncher()
        let cmd = launcher.buildCommand(terminal: .terminal, sessionID: sessionID, workingDirectory: cwd)

        XCTAssertEqual(cmd.executable, "/usr/bin/osascript")

        let expected = #"""
        tell application "Terminal"
            activate
            do script "cd \"/Users/dev/project name/aayo\" && claude --resume 11111111-1111-1111-1111-111111111111"
        end tell
        """#
        XCTAssertEqual(cmd.appleScript, expected)
        XCTAssertEqual(cmd.arguments, ["-e", expected])
    }

    // MARK: WezTerm

    func test_buildCommand_wezterm_snapshot() {
        let launcher = makeLauncher()
        let cmd = launcher.buildCommand(terminal: .wezterm, sessionID: sessionID, workingDirectory: cwd)

        // Exec path depends on what's installed; assert it's one of the known
        // candidates OR the raw "wezterm" fallback.
        let validExecs = Set(Terminal.wezterm.cliExecutableCandidates + ["wezterm"])
        XCTAssertTrue(validExecs.contains(cmd.executable),
                      "unexpected wezterm exec: \(cmd.executable)")

        XCTAssertEqual(cmd.arguments, [
            "start",
            "--cwd", "/Users/dev/project name/aayo",
            "--",
            testShell, "-i", "-c",
            #"cd "/Users/dev/project name/aayo" && claude --resume 11111111-1111-1111-1111-111111111111"#,
        ])
        XCTAssertNil(cmd.appleScript)
    }

    // MARK: kitty

    func test_buildCommand_kitty_snapshot() {
        let launcher = makeLauncher()
        let cmd = launcher.buildCommand(terminal: .kitty, sessionID: sessionID, workingDirectory: cwd)

        let validExecs = Set(Terminal.kitty.cliExecutableCandidates + ["kitty"])
        XCTAssertTrue(validExecs.contains(cmd.executable),
                      "unexpected kitty exec: \(cmd.executable)")

        XCTAssertEqual(cmd.arguments, [
            "--directory", "/Users/dev/project name/aayo",
            testShell, "-i", "-c",
            #"cd "/Users/dev/project name/aayo" && claude --resume 11111111-1111-1111-1111-111111111111"#,
        ])
        XCTAssertNil(cmd.appleScript)
    }

    // MARK: - login-shell wrapping

    /// Verifies that non-AppleScript terminals route their command through
    /// the user's login shell with `-i -c` so the shell sources `~/.zshrc`
    /// (or its bash equivalent), which is where most macOS users put their
    /// PATH exports. v0.1.4 used `bash -lc` and Resume-in-Ghostty failed
    /// with `claude: command not found` for anyone who only configured
    /// PATH in zsh rc files.
    func test_buildCommand_wrapsInLoginShell_forShellTerminals() {
        let launcher = makeLauncher()
        let terminals: [Terminal] = [.ghostty, .alacritty, .wezterm, .kitty]

        for terminal in terminals {
            let cmd = launcher.buildCommand(
                terminal: terminal,
                sessionID: sessionID,
                workingDirectory: cwd
            )
            XCTAssertTrue(cmd.arguments.contains(testShell),
                "\(terminal) argv should include the login shell `\(testShell)`: \(cmd.arguments)")
            XCTAssertTrue(cmd.arguments.contains("-i"),
                "\(terminal) argv should include `-i` (interactive — sources ~/.zshrc): \(cmd.arguments)")
            XCTAssertTrue(cmd.arguments.contains("-c"),
                "\(terminal) argv should include `-c <cmd>`: \(cmd.arguments)")
            let shellCmd = cmd.arguments.last ?? ""
            XCTAssertTrue(shellCmd.contains("claude --resume \(sessionID)"),
                "\(terminal) shell command should resume the right session: \(shellCmd)")
            XCTAssertTrue(shellCmd.contains("cd "),
                "\(terminal) shell command should `cd` into cwd first: \(shellCmd)")
        }
    }

    // MARK: - Escaping

    func test_shellEscape_passesThroughSimplePaths() {
        XCTAssertEqual(
            SessionLauncher.shellEscapeInsideDoubleQuotes("/Users/dev/project"),
            "/Users/dev/project"
        )
    }

    func test_shellEscape_preservesSpacesUnchanged() {
        XCTAssertEqual(
            SessionLauncher.shellEscapeInsideDoubleQuotes("/Users/dev/project name"),
            "/Users/dev/project name"
        )
    }

    func test_shellEscape_escapesDoubleQuotes() {
        XCTAssertEqual(
            SessionLauncher.shellEscapeInsideDoubleQuotes(#"foo"bar"#),
            #"foo\"bar"#
        )
    }

    func test_shellEscape_escapesBackslashes() {
        XCTAssertEqual(
            SessionLauncher.shellEscapeInsideDoubleQuotes(#"foo\bar"#),
            #"foo\\bar"#
        )
    }

    func test_shellEscape_escapesBothQuotesAndBackslashes() {
        // `foo"bar\baz` must become `foo\"bar\\baz` so that AppleScript
        // parses it into `foo"bar\baz` and shell re-parses to the original.
        XCTAssertEqual(
            SessionLauncher.shellEscapeInsideDoubleQuotes(#"foo"bar\baz"#),
            #"foo\"bar\\baz"#
        )
    }

    func test_itermScript_escapesPathologicalCwd() {
        let launcher = makeLauncher()
        let nastyCwd = #"/Users/dev/he said "hi" and \n folder"#
        let cmd = launcher.buildCommand(
            terminal: .iterm,
            sessionID: sessionID,
            workingDirectory: nastyCwd
        )
        // Two escape passes: shell-quote inside `"..."` turns `"` → `\"` and
        // `\` → `\\`. Then AppleScript-quote applies the same pair: `"` → `\"`
        // and `\` → `\\`. So a raw `"` ends up as `\\\"` (four chars) and a
        // raw `\` ends up as `\\\\` (four chars) in the AppleScript source.
        XCTAssertTrue(cmd.appleScript!.contains(
            #"cd \"/Users/dev/he said \\\"hi\\\" and \\\\n folder\""#
        ), "AppleScript should double-escape quotes + backslashes in CWD")
    }

    // MARK: - launch() routes through ProcessRunner

    func test_launch_ghostty_recordsProcessRun() async throws {
        let runner = TestProcessRunner()
        let launcher = makeLauncher(runner: runner)
        try await launcher.launch(terminal: .ghostty, sessionID: sessionID, workingDirectory: cwd)

        XCTAssertEqual(runner.invocations.count, 1)
        let inv = runner.invocations[0]
        XCTAssertEqual(inv.executable, "/usr/bin/open")
        XCTAssertEqual(inv.arguments.first, "-na")
        XCTAssertTrue(inv.arguments.contains("Ghostty"))
        XCTAssertNil(inv.appleScript, "non-AppleScript launch shouldn't record a script")
    }

    func test_launch_iterm_routesThroughAppleScript() async throws {
        let runner = TestProcessRunner()
        let launcher = makeLauncher(runner: runner)
        try await launcher.launch(terminal: .iterm, sessionID: sessionID, workingDirectory: cwd)

        XCTAssertEqual(runner.invocations.count, 1)
        let inv = runner.invocations[0]
        XCTAssertEqual(inv.executable, "/usr/bin/osascript")
        XCTAssertNotNil(inv.appleScript)
        XCTAssertTrue(inv.appleScript!.contains("tell application \"iTerm\""))
        XCTAssertTrue(inv.appleScript!.contains("claude --resume \(sessionID)"))
    }

    func test_launch_terminalApp_routesThroughAppleScript() async throws {
        let runner = TestProcessRunner()
        let launcher = makeLauncher(runner: runner)
        try await launcher.launch(terminal: .terminal, sessionID: sessionID, workingDirectory: cwd)

        XCTAssertEqual(runner.invocations.count, 1)
        let inv = runner.invocations[0]
        XCTAssertEqual(inv.executable, "/usr/bin/osascript")
        XCTAssertTrue(inv.appleScript!.contains("tell application \"Terminal\""))
        XCTAssertTrue(inv.appleScript!.contains("do script"))
    }

    func test_launch_wezterm_usesCliExec() async throws {
        let runner = TestProcessRunner()
        let launcher = makeLauncher(runner: runner)
        try await launcher.launch(terminal: .wezterm, sessionID: sessionID, workingDirectory: cwd)

        XCTAssertEqual(runner.invocations.count, 1)
        let inv = runner.invocations[0]
        let expectedShell = #"cd "\#(cwd)" && claude --resume \#(sessionID)"#
        XCTAssertEqual(inv.arguments, ["start", "--cwd", cwd, "--", testShell, "-i", "-c", expectedShell],
                      "wezterm argv should be `start --cwd <cwd> -- <shell> -i -c '...'`")
    }

    func test_launch_kitty_usesCliExec() async throws {
        let runner = TestProcessRunner()
        let launcher = makeLauncher(runner: runner)
        try await launcher.launch(terminal: .kitty, sessionID: sessionID, workingDirectory: cwd)

        XCTAssertEqual(runner.invocations.count, 1)
        let inv = runner.invocations[0]
        let expectedShell = #"cd "\#(cwd)" && claude --resume \#(sessionID)"#
        XCTAssertEqual(inv.arguments, ["--directory", cwd, testShell, "-i", "-c", expectedShell],
                      "kitty argv should be `--directory <cwd> <shell> -i -c '...'`")
    }

    // MARK: - resolveLoginShell

    func test_resolveLoginShell_usesShellEnv() {
        let shell = SessionLauncher.resolveLoginShell(env: ["SHELL": "/bin/zsh"])
        XCTAssertEqual(shell, "/bin/zsh")
    }

    func test_resolveLoginShell_fallsBackWhenShellEnvMissing() {
        let shell = SessionLauncher.resolveLoginShell(env: [:])
        XCTAssertEqual(shell, "/bin/zsh", "should fall back to macOS default")
    }

    func test_resolveLoginShell_fallsBackWhenShellEnvNotExecutable() {
        let shell = SessionLauncher.resolveLoginShell(env: ["SHELL": "/nope/does/not/exist"])
        XCTAssertEqual(shell, "/bin/zsh", "non-executable SHELL should fall back")
    }
}
