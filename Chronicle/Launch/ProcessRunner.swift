import Foundation

/// Foundation-based ProcessRunner that spawns real child processes.
/// Fire-and-forget; does NOT await termination because the terminal
/// window runs asynchronously from Chronicle's main process.
public struct DefaultProcessRunner: ProcessRunner {
    public static let `default` = DefaultProcessRunner()

    public init() {}

    public func run(executable: String, arguments: [String]) async throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        // Don't capture stdout/stderr; the spawned terminal handles its own IO.
        // Don't call waitUntilExit(); we want the terminal to open asynchronously.
        try p.run()
    }

    public func runAppleScript(_ source: String) async throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        try p.run()
    }
}
