import Foundation

/// One session inside a workspace, summarized.
struct SessionSummary {
    let file: URL
    let id: String
    let title: String         // first user prompt, trimmed; "(no prompt)" if absent
    let cwd: String?
    let gitBranch: String?
    let version: String?
    let messageCount: Int
    let modified: Date
}

enum SessionLoader {
    /// Walk the file once and return a SessionSummary. Stops scanning user
    /// messages after the first non-trivial one; counts every line whose
    /// type is `user` or `assistant` for messageCount.
    static func summarize(file: URL) -> SessionSummary {
        let id = file.deletingPathExtension().lastPathComponent
        let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date.distantPast

        var title: String?
        var cwd: String?
        var branch: String?
        var version: String?
        var count = 0

        guard let h = try? FileHandle(forReadingFrom: file) else {
            return SessionSummary(file: file, id: id, title: "(unreadable)",
                                  cwd: nil, gitBranch: nil, version: nil,
                                  messageCount: 0, modified: mtime)
        }
        defer { try? h.close() }

        // Stream the file in chunks; split on newline; parse each line.
        var carry = Data()
        while true {
            guard let chunk = try? h.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
            var combined = carry
            combined.append(chunk)
            let lines = combined.split(separator: 0x0A, omittingEmptySubsequences: false)
            // Last element might be a partial line; carry it to the next chunk.
            if let tail = lines.last {
                carry = Data(tail)
            } else {
                carry = Data()
            }
            for line in lines.dropLast() where !line.isEmpty {
                let data = Data(line)
                guard let parsed = ParsedLine(data) else { continue }
                if cwd == nil, let c = parsed.cwd { cwd = c }
                if branch == nil, let b = parsed.gitBranch { branch = b }
                if version == nil, let v = parsed.version { version = v }
                if parsed.type == "user" || parsed.type == "assistant" {
                    count += 1
                    if title == nil, parsed.type == "user",
                       let text = JsonlLine.userText(from: parsed.dict),
                       !text.hasPrefix("<local-command-") {
                        title = oneLine(text)
                    }
                }
            }
        }
        // Don't forget the last (possibly newline-less) line.
        if !carry.isEmpty, let parsed = ParsedLine(carry) {
            if cwd == nil, let c = parsed.cwd { cwd = c }
            if branch == nil, let b = parsed.gitBranch { branch = b }
            if version == nil, let v = parsed.version { version = v }
            if parsed.type == "user" || parsed.type == "assistant" {
                count += 1
                if title == nil, parsed.type == "user",
                   let text = JsonlLine.userText(from: parsed.dict),
                   !text.hasPrefix("<local-command-") {
                    title = oneLine(text)
                }
            }
        }

        return SessionSummary(
            file: file, id: id,
            title: title ?? "(no prompt)",
            cwd: cwd, gitBranch: branch, version: version,
            messageCount: count, modified: mtime
        )
    }

    private static func oneLine(_ s: String) -> String {
        let collapsed = s
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = 100
        if collapsed.count > limit {
            return String(collapsed.prefix(limit)) + "…"
        }
        return collapsed
    }
}
