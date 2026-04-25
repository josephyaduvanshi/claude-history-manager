import Foundation

enum CommandList {
    /// One row per workspace: folder name, decoded path, session count,
    /// most recent activity. Cheap: just stats jsonl files in each
    /// workspace, doesn't read their contents.
    static func run(projects: ProjectsRoot) throws {
        let workspaces = try projects.workspaces()
        if workspaces.isEmpty {
            print("(no workspaces under \(projects.url.path))")
            return
        }

        struct Row {
            let folder: String
            let path: String
            let sessions: Int
            let lastActive: Date?
        }

        var rows: [Row] = []
        rows.reserveCapacity(workspaces.count)
        for ws in workspaces {
            let files = (try? ws.sessionFiles()) ?? []
            let lastActive: Date? = files.compactMap {
                (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
            }.max()
            rows.append(Row(
                folder: ws.folderName,
                path: ws.canonicalCwd() ?? ws.decodedNameAsPath,
                sessions: files.count,
                lastActive: lastActive
            ))
        }
        rows.sort { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }

        let pathW = max(4, rows.map { $0.path.count }.max() ?? 4)
        let countW = max(8, rows.map { String($0.sessions).count }.max() ?? 8)

        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime]

        print(pad("PATH", pathW) + "  " + pad("SESSIONS", countW) + "  LAST ACTIVE")
        print(String(repeating: "─", count: pathW) + "  "
              + String(repeating: "─", count: countW) + "  "
              + String(repeating: "─", count: 20))
        for row in rows {
            let ts = row.lastActive.map { df.string(from: $0) } ?? "—"
            print(pad(row.path, pathW) + "  " + pad(String(row.sessions), countW) + "  " + ts)
        }
    }
}

func pad(_ s: String, _ w: Int) -> String {
    if s.count >= w { return s }
    return s + String(repeating: " ", count: w - s.count)
}
