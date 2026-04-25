import XCTest
@testable import Chronicle

final class EditorLauncherTests: XCTestCase {

    func test_buildCommand_prefers_openApp_when_bundle_installed() {
        let launcher = EditorLauncher(
            isAppInstalled: { _ in true },
            cliPath: { _ in "/fail/should/not/be/used" }
        )
        let cmd = launcher.buildCommand(editor: .cursor, path: "/tmp/project")
        XCTAssertTrue(cmd.useOpenApp)
        XCTAssertEqual(cmd.executable, "/usr/bin/open")
        XCTAssertEqual(cmd.arguments, ["-a", "Cursor", "/tmp/project"])
    }

    func test_buildCommand_falls_back_to_cli_when_bundle_missing() {
        let launcher = EditorLauncher(
            isAppInstalled: { _ in false },
            cliPath: { e in e == .vscode ? "/opt/homebrew/bin/code" : nil }
        )
        let cmd = launcher.buildCommand(editor: .vscode, path: "/Users/me/repo")
        XCTAssertFalse(cmd.useOpenApp)
        XCTAssertEqual(cmd.executable, "/opt/homebrew/bin/code")
        XCTAssertEqual(cmd.arguments, ["/Users/me/repo"])
    }

    func test_buildCommand_emits_placeholder_when_nothing_resolves() {
        let launcher = EditorLauncher(
            isAppInstalled: { _ in false },
            cliPath: { _ in nil }
        )
        let cmd = launcher.buildCommand(editor: .zed, path: "/p")
        XCTAssertFalse(cmd.useOpenApp)
        XCTAssertEqual(cmd.executable, "zed")
    }

    func test_open_dispatches_via_runner_with_openApp_args() async throws {
        let runner = RecordingRunner()
        let launcher = EditorLauncher(
            processRunner: runner,
            isAppInstalled: { _ in true },
            cliPath: { _ in nil }
        )
        try await launcher.open(editor: .cursor, path: "/tmp/proj")
        let invocations = await runner.invocations
        XCTAssertEqual(invocations.count, 1)
        XCTAssertEqual(invocations.first?.exec, "/usr/bin/open")
        XCTAssertEqual(invocations.first?.args, ["-a", "Cursor", "/tmp/proj"])
    }

    func test_open_dispatches_cli_shim_when_no_app_found() async throws {
        let runner = RecordingRunner()
        let launcher = EditorLauncher(
            processRunner: runner,
            isAppInstalled: { _ in false },
            cliPath: { _ in "/usr/local/bin/zed" }
        )
        try await launcher.open(editor: .zed, path: "/p")
        let invocations = await runner.invocations
        XCTAssertEqual(invocations.first?.exec, "/usr/local/bin/zed")
        XCTAssertEqual(invocations.first?.args, ["/p"])
    }

    func test_open_throws_when_neither_app_nor_cli_available() async {
        let runner = RecordingRunner()
        let launcher = EditorLauncher(
            processRunner: runner,
            isAppInstalled: { _ in false },
            cliPath: { _ in nil }
        )
        do {
            try await launcher.open(editor: .cursor, path: "/p")
            XCTFail("expected notInstalled to throw")
        } catch EditorLauncherError.notInstalled(let e) {
            XCTAssertEqual(e, .cursor)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func test_editorPreference_roundTrips() {
        let key = "chronicle.test.editor.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: key)!
        defer {
            UserDefaults().removePersistentDomain(forName: key)
        }
        XCTAssertNil(EditorPreference.load(from: defaults))
        EditorPreference.save(.zed, to: defaults)
        XCTAssertEqual(EditorPreference.load(from: defaults), .zed)
        EditorPreference.save(nil, to: defaults)
        XCTAssertNil(EditorPreference.load(from: defaults))
    }
}

// MARK: - Recording runner

actor RecordingRunner: ProcessRunner {
    struct Invocation: Equatable {
        let exec: String
        let args: [String]
    }
    var invocations: [Invocation] = []

    func run(executable: String, arguments: [String]) async throws {
        invocations.append(Invocation(exec: executable, args: arguments))
    }

    func runAppleScript(_ source: String) async throws {
        invocations.append(Invocation(exec: "osascript", args: ["-e", source]))
    }
}
