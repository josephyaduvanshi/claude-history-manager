import Foundation

enum CommandSearch {
    /// Substring search across every session file. Case-insensitive. Prints
    /// `<workspace>/<session-id>:<line>:<preview>` per match. Stops when
    /// `limit` matches have been emitted (default 50).
    static func run(projects: ProjectsRoot, query: String, limit: Int) throws {
        let needle = query.lowercased()
        let workspaces = try projects.workspaces()

        var emitted = 0
        outer: for ws in workspaces {
            let files = (try? ws.sessionFiles()) ?? []
            for file in files {
                let sessionID = file.deletingPathExtension().lastPathComponent
                guard let h = try? FileHandle(forReadingFrom: file) else { continue }
                defer { try? h.close() }

                var carry = Data()
                var lineNo = 0
                while true {
                    guard let chunk = try? h.read(upToCount: 256 * 1024), !chunk.isEmpty else { break }
                    var combined = carry
                    combined.append(chunk)
                    let lines = combined.split(separator: 0x0A, omittingEmptySubsequences: false)
                    if let tail = lines.last { carry = Data(tail) } else { carry = Data() }
                    for slice in lines.dropLast() {
                        lineNo += 1
                        if slice.isEmpty { continue }
                        let lineData = Data(slice)
                        if matches(lineData, needle: needle) {
                            let preview = previewFromJsonl(lineData)
                            print("\(ws.folderName)/\(sessionID):\(lineNo):\(preview)")
                            emitted += 1
                            if emitted >= limit { break outer }
                        }
                    }
                }
                // Tail line (no trailing newline).
                if !carry.isEmpty {
                    lineNo += 1
                    if matches(carry, needle: needle) {
                        let preview = previewFromJsonl(carry)
                        print("\(ws.folderName)/\(sessionID):\(lineNo):\(preview)")
                        emitted += 1
                        if emitted >= limit { break outer }
                    }
                }
            }
        }

        if emitted == 0 {
            FileHandle.standardError.write(Data("(no matches for \"\(query)\")\n".utf8))
        }
    }

    private static func matches(_ data: Data, needle: String) -> Bool {
        if let s = String(data: data, encoding: .utf8) {
            return s.range(of: needle, options: .caseInsensitive) != nil
        }
        return false
    }

    /// Pull a useful one-line preview out of a matched JSONL row: prefer
    /// user/assistant message text, fall back to a truncated raw line.
    private static func previewFromJsonl(_ data: Data) -> String {
        if let parsed = ParsedLine(data),
           let text = JsonlLine.userText(from: parsed.dict) {
            return collapse(text, max: 120)
        }
        if let s = String(data: data, encoding: .utf8) {
            return collapse(s, max: 120)
        }
        return "(binary line)"
    }

    private static func collapse(_ s: String, max limit: Int) -> String {
        let collapsed = s
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.count > limit {
            return String(collapsed.prefix(limit)) + "…"
        }
        return collapsed
    }
}
