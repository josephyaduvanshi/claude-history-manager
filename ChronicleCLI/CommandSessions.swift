import Foundation

enum CommandSessions {
    static func run(projects: ProjectsRoot, workspace: String?, limit: Int) throws {
        let ws: Workspace
        if let id = workspace {
            ws = try projects.resolveWorkspace(id)
        } else if let match = try projects.workspaceMatchingCwd() {
            ws = match
        } else {
            throw CLIError(
                message: """
                    no workspace specified and $PWD does not match any workspace.
                    pick one explicitly with `chronicle sessions -w <path-or-name>`
                    or run `chronicle list` to see what's available.
                    """,
                exitCode: 64
            )
        }

        let files = try ws.sessionFiles()
        let summaries = files
            .map { SessionLoader.summarize(file: $0) }
            .sorted { $0.modified > $1.modified }
            .prefix(limit)

        if summaries.isEmpty {
            print("(no sessions in \(ws.folderName))")
            return
        }

        let cwd = ws.canonicalCwd() ?? ws.decodedNameAsPath
        print("workspace: \(cwd)")
        print("folder:    \(ws.folderName)")
        print("")

        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime]
        let idW = 36, countW = 5, dateW = 20

        print(pad("ID", idW) + "  " + pad("MSGS", countW) + "  " + pad("MODIFIED", dateW) + "  TITLE")
        print(String(repeating: "─", count: idW) + "  "
              + String(repeating: "─", count: countW) + "  "
              + String(repeating: "─", count: dateW) + "  "
              + String(repeating: "─", count: 40))
        for s in summaries {
            print(pad(s.id, idW) + "  "
                  + pad(String(s.messageCount), countW) + "  "
                  + pad(df.string(from: s.modified), dateW) + "  "
                  + s.title)
        }
    }
}
