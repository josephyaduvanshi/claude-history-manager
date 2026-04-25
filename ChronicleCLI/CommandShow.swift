import Foundation

enum CommandShow {
    /// Print a session transcript. Looks the session-id up across every
    /// workspace; reports the workspace + first line of metadata, then
    /// streams the messages.
    ///
    /// Formats:
    ///   text  — human-readable user/assistant turns (default)
    ///   raw   — pass-through of the original JSONL
    static func run(projects: ProjectsRoot, sessionID: String, format: String) throws {
        guard let file = try locate(sessionID: sessionID, in: projects) else {
            throw CLIError.notFound("session \(sessionID)")
        }

        if format == "raw" {
            // Just stream bytes to stdout.
            guard let h = try? FileHandle(forReadingFrom: file) else {
                throw CLIError(message: "cannot open \(file.path)", exitCode: 2)
            }
            defer { try? h.close() }
            while let chunk = try h.read(upToCount: 256 * 1024), !chunk.isEmpty {
                FileHandle.standardOutput.write(chunk)
            }
            return
        }

        guard format == "text" else {
            throw CLIError(message: "unknown --format \(format) (expected text or raw)", exitCode: 64)
        }

        let summary = SessionLoader.summarize(file: file)
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime]

        print("session   \(summary.id)")
        if let cwd = summary.cwd { print("cwd       \(cwd)") }
        if let b = summary.gitBranch { print("git       \(b)") }
        if let v = summary.version { print("claude    \(v)") }
        print("modified  \(df.string(from: summary.modified))")
        print("messages  \(summary.messageCount)")
        print(String(repeating: "─", count: 60))

        guard let h = try? FileHandle(forReadingFrom: file) else {
            throw CLIError(message: "cannot open \(file.path)", exitCode: 2)
        }
        defer { try? h.close() }

        var carry = Data()
        var turn = 0
        while true {
            guard let chunk = try? h.read(upToCount: 256 * 1024), !chunk.isEmpty else { break }
            var combined = carry
            combined.append(chunk)
            let lines = combined.split(separator: 0x0A, omittingEmptySubsequences: false)
            if let tail = lines.last { carry = Data(tail) } else { carry = Data() }
            for slice in lines.dropLast() where !slice.isEmpty {
                printLine(Data(slice), turn: &turn)
            }
        }
        if !carry.isEmpty {
            printLine(carry, turn: &turn)
        }
    }

    private static func printLine(_ data: Data, turn: inout Int) {
        guard let parsed = ParsedLine(data) else { return }
        switch parsed.type {
        case "user":
            if let text = JsonlLine.userText(from: parsed.dict) {
                turn += 1
                print("")
                print("[\(turn)] USER")
                print(indent(text))
            }
        case "assistant":
            if let text = JsonlLine.assistantText(from: parsed.dict) {
                turn += 1
                print("")
                print("[\(turn)] ASSISTANT")
                print(indent(text))
            }
        default:
            break
        }
    }

    private static func indent(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "  \($0)" }
            .joined(separator: "\n")
    }

    /// Walk every workspace and find the file whose name == "<sid>.jsonl".
    private static func locate(sessionID: String, in projects: ProjectsRoot) throws -> URL? {
        for ws in try projects.workspaces() {
            let candidate = ws.url.appendingPathComponent("\(sessionID).jsonl")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}
