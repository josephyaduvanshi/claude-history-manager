import Foundation

let toolVersion = "0.2.0"

let stderr = FileHandle.standardError
func eprint(_ s: String) {
    if let d = (s + "\n").data(using: .utf8) { stderr.write(d) }
}

func usage() -> String {
    """
    chronicle \(toolVersion) — browse Claude Code session history

    USAGE
      chronicle list
          Show every workspace under ~/.claude/projects with its session count
          and most recent activity.

      chronicle sessions [-w <path-or-name>] [-n <count>]
          List sessions in a workspace, newest first. -w accepts either the
          on-disk folder name (-Users-foo-bar) or the decoded path
          (/Users/foo/bar). Defaults to the workspace matching $PWD.

      chronicle search <query> [--limit <n>]
          Substring search across every session transcript. Prints
          session-id:line-no:preview for each match.

      chronicle show <session-id> [--format text|raw]
          Print a session transcript. text (default) renders user/assistant
          turns; raw streams the original JSONL untouched.

    GLOBAL FLAGS
      --root <path>     Override ~/.claude/projects.
      --version         Print version and exit.
      --help, -h        Print this help and exit.

    EXAMPLES
      chronicle list
      chronicle sessions -w /Users/me/code/my-app -n 10
      chronicle search "EXC_BAD_ACCESS"
      chronicle show 01886499-a9e2-4a70-8e73-9075cda0c74c
    """
}

// Pull `--root <path>` out of argv before subcommand dispatch so subcommands
// don't have to thread it through.
func popRoot(_ args: inout [String]) -> URL {
    if let i = args.firstIndex(of: "--root"), i + 1 < args.count {
        let path = args[i + 1]
        args.removeSubrange(i...(i + 1))
        return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    }
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent(".claude/projects", isDirectory: true)
}

func popValue(_ args: inout [String], flags: [String]) -> String? {
    for f in flags {
        if let i = args.firstIndex(of: f), i + 1 < args.count {
            let v = args[i + 1]
            args.removeSubrange(i...(i + 1))
            return v
        }
    }
    return nil
}

let rawArgs = CommandLine.arguments
guard rawArgs.count > 1 else {
    print(usage())
    exit(0)
}

var argv = Array(rawArgs.dropFirst())

if argv.contains("--help") || argv.contains("-h") {
    print(usage())
    exit(0)
}
if argv.contains("--version") {
    print("chronicle \(toolVersion)")
    exit(0)
}

let root = popRoot(&argv)
let cmd = argv.removeFirst()

do {
    let projects = try ProjectsRoot(url: root)
    switch cmd {
    case "list":
        try CommandList.run(projects: projects)
    case "sessions":
        let workspace = popValue(&argv, flags: ["-w", "--workspace"])
        let limitStr = popValue(&argv, flags: ["-n", "--limit"])
        let limit = limitStr.flatMap(Int.init) ?? 25
        try CommandSessions.run(projects: projects, workspace: workspace, limit: limit)
    case "search":
        guard !argv.isEmpty else {
            eprint("error: search requires a query")
            exit(64)
        }
        let limitStr = popValue(&argv, flags: ["--limit", "-n"])
        let limit = limitStr.flatMap(Int.init) ?? 50
        let query = argv.joined(separator: " ")
        try CommandSearch.run(projects: projects, query: query, limit: limit)
    case "show":
        guard let sid = argv.first else {
            eprint("error: show requires a session id")
            exit(64)
        }
        let format = popValue(&argv, flags: ["--format"]) ?? "text"
        try CommandShow.run(projects: projects, sessionID: sid, format: format)
    default:
        eprint("unknown command: \(cmd)")
        eprint(usage())
        exit(64)
    }
} catch let err as CLIError {
    eprint("error: \(err.message)")
    exit(err.exitCode)
} catch {
    eprint("error: \(error.localizedDescription)")
    exit(1)
}
