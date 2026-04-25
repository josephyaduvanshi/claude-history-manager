import Foundation

struct CLIError: Error {
    let message: String
    let exitCode: Int32

    static func notFound(_ what: String) -> CLIError {
        CLIError(message: "not found: \(what)", exitCode: 2)
    }

    static func badRoot(_ path: String) -> CLIError {
        CLIError(
            message: """
                projects directory does not exist or is not readable: \(path)
                hint: pass --root <path> if your Claude Code state lives elsewhere.
                """,
            exitCode: 2
        )
    }
}
