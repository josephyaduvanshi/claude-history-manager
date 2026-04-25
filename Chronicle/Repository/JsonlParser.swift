import Foundation

public struct JsonlParser {
    public enum ParseError: Error {
        case emptyFile
        case noSessionIDInFilename(URL)
    }

    /// Well-known flag names that `parseWithFlags(...)` can emit. Exposed as
    /// constants so sidebar/repo code can reference them without magic strings.
    public enum Flag {
        public static let gitPush = "git_push"
        public static let errored = "errored"
    }

    public init() {}

    /// Authoritative workspace metadata extracted from a session jsonl. The
    /// dash-encoded folder name under `~/.claude/projects/` is lossy because
    /// Claude Code replaces `/`, ` `, `_`, `-`, and `.` all with `-`. The real
    /// cwd, however, is recorded inside virtually every user/assistant line as
    /// a `cwd` field. We sample only the first ~30 lines for cheapness.
    public struct WorkspaceMetadata: Equatable, Sendable {
        public let cwd: String?
        public let gitBranch: String?
        public let version: String?
    }

    /// Reads up to `lineCap` lines (default 30) from the jsonl and pulls the
    /// first non-empty `cwd`, `gitBranch`, and `version` it sees. Returns nil
    /// when the file can't be read at all. Each field independently; a line
    /// may have `cwd` but no `gitBranch`, and the next may fill the gap.
    ///
    /// Performance: streams only the first 32 KB of the file via FileHandle
    /// rather than slurping the entire (potentially many-MB) jsonl into a
    /// String. 32 KB comfortably covers ~30 lines of real-world jsonl. If
    /// the file is smaller than the read budget, FileHandle returns the
    /// whole file naturally. We drop the trailing partial line to avoid
    /// feeding a truncated JSON object to JSONSerialization.
    public func extractWorkspaceMetadata(
        url: URL,
        lineCap: Int = 30
    ) -> WorkspaceMetadata? {
        // Bounded read: 32 KB is enough for ~30 lines of jsonl in any
        // realistic case, and is dramatically cheaper than reading the full
        // file (which can be tens or hundreds of MB).
        let readBudget = 32_768
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }

        let data: Data
        do {
            data = try handle.read(upToCount: readBudget) ?? Data()
        } catch {
            return nil
        }
        guard !data.isEmpty,
              let raw = String(data: data, encoding: .utf8) else {
            return nil
        }

        // Drop the trailing partial line if our 32 KB window cut a line
        // mid-object. If the file fit entirely within the window the read
        // returns < readBudget bytes and we keep every line (including the
        // last one, even if it lacks a trailing newline; but the safest
        // correct-by-default behavior is to drop the last fragment whenever
        // we hit the cap).
        let allLines = raw.split(whereSeparator: \.isNewline)
        let lines: ArraySlice<Substring>
        if data.count >= readBudget {
            lines = allLines.dropLast()
        } else {
            lines = allLines[...]
        }

        var cwd: String?
        var branch: String?
        var version: String?
        var seen = 0
        for line in lines {
            if seen >= lineCap { break }
            seen += 1
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            if cwd == nil, let v = obj["cwd"] as? String, !v.isEmpty {
                cwd = v
            }
            if branch == nil, let v = obj["gitBranch"] as? String, !v.isEmpty {
                branch = v
            }
            if version == nil, let v = obj["version"] as? String, !v.isEmpty {
                version = v
            }
            if cwd != nil && branch != nil && version != nil { break }
        }
        if cwd == nil && branch == nil && version == nil { return nil }
        return WorkspaceMetadata(cwd: cwd, gitBranch: branch, version: version)
    }

    public func parse(url: URL, workspaceID: String) throws -> SessionMetadata {
        try parseWithFlags(url: url, workspaceID: workspaceID).0
    }

    /// Like `parse(url:workspaceID:)` but additionally returns the set of
    /// session flags derived from the jsonl contents (for `session_flags`).
    public func parseWithFlags(url: URL, workspaceID: String) throws -> (SessionMetadata, Set<String>) {
        let stem = url.deletingPathExtension().lastPathComponent
        let sessionID = try SessionID(string: stem)

        let raw = try String(contentsOf: url, encoding: .utf8)
        let lines = raw.split(whereSeparator: \.isNewline)
        guard !lines.isEmpty else { throw ParseError.emptyFile }

        var firstUserMessage: String?
        var firstTimestamp: Date?
        var lastTimestamp: Date?
        var messageCount = 0
        var tokenCount = 0
        var inputTokens = 0
        var outputTokens = 0
        var lastModel: String?
        var flags: Set<String> = []

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()
        isoNoFrac.formatOptions = [.withInternetDateTime]

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            guard let type = obj["type"] as? String else { continue }

            let ts = (obj["timestamp"] as? String).flatMap {
                iso.date(from: $0) ?? isoNoFrac.date(from: $0)
            }
            if firstTimestamp == nil, let ts { firstTimestamp = ts }
            if let ts { lastTimestamp = ts }

            switch type {
            // ── Known non-message event types; skip explicitly ──────────────
            case "permission-mode",
                 "attachment",
                 "file-history-snapshot",
                 "summary",
                 "queue-operation",
                 "system":
                break

            case "tool_use":
                // Scan shell invocations for `git push` so we can answer the
                // "Used `git push`" smart folder without reparsing.
                if Self.toolUseMentionsGitPush(obj) {
                    flags.insert(Flag.gitPush)
                }
                break

            case "tool_result":
                if Self.toolResultLooksErrored(obj) {
                    flags.insert(Flag.errored)
                }
                break

            case "user":
                // tool_result carrier turns (embedded inside message.content as
                // a tool_result block) may also carry error signals.
                if isToolResultCarrier(obj) {
                    if Self.userMessageCarriesErroredToolResult(obj) {
                        flags.insert(Flag.errored)
                    }
                    break
                }
                messageCount += 1
                if firstUserMessage == nil,
                   let extracted = extractTextContent(from: obj),
                   !Self.isHarnessJunk(extracted) {
                    firstUserMessage = String(extracted.prefix(200))
                }

            case "assistant":
                messageCount += 1
                // usage may be nested under "message" (real format) OR top-level (legacy fixture format)
                if let msg = obj["message"] as? [String: Any],
                   let usage = msg["usage"] as? [String: Any] {
                    let i = usage["input_tokens"] as? Int ?? 0
                    let o = usage["output_tokens"] as? Int ?? 0
                    tokenCount += i + o
                    inputTokens += i
                    outputTokens += o
                    if let m = msg["model"] as? String, !m.isEmpty { lastModel = m }
                    if Self.assistantContentMentionsGitPush(msg) {
                        flags.insert(Flag.gitPush)
                    }
                } else if let usage = obj["usage"] as? [String: Any] {
                    let i = usage["input_tokens"] as? Int ?? 0
                    let o = usage["output_tokens"] as? Int ?? 0
                    tokenCount += i + o
                    inputTokens += i
                    outputTokens += o
                    if let m = obj["model"] as? String, !m.isEmpty { lastModel = m }
                }

            default:
                // Unknown type; silently skip.
                break
            }
        }

        // If no user message in this session, use a fallback title; never drop the session
        let title = firstUserMessage ?? "(no user message)"
        let created = firstTimestamp ?? Date()
        let modified = lastTimestamp ?? created

        let metadata = SessionMetadata(
            sessionID: sessionID,
            workspaceID: workspaceID,
            title: title,
            createdAt: created,
            lastModifiedAt: modified,
            messageCount: messageCount,
            tokenCount: tokenCount,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            model: lastModel,
            isLive: false
        )
        return (metadata, flags)
    }

    // MARK: - Helpers

    /// Harness-injected prefixes that mean "this looks like a user message but was added by the
    /// Claude Code CLI itself". These should never be used as a session title.
    private static let junkPrefixes: [String] = [
        "<local-command-caveat>",
        "<local-command-stdout>",
        "<local-command-stderr>",
        "<system-reminder>",
        "<command-name>",
        "<command-message>",
        "<command-args>",
        "<user-prompt-submit-hook>",
        "<bash-input>",
        "<bash-stdout>",
        "<bash-stderr>",
        "<ide-selection>",
        "<ide-opened-files>",
    ]

    /// Tight regex: content is just angle-bracket markup with optional whitespace (no real prose).
    /// e.g. `"<command-name>/clear</command-name>"` or `"<a></a><b></b>"`.
    ///
    /// Built lazily so a pathological regex-compile failure logs rather than
    /// force-crashing on the main target. The pattern is a literal constant , 
    /// if the fallback is ever used, it returns no matches (treats all text
    /// as real prose, which is the safe default for a title filter).
    private static let markupOnlyPattern: NSRegularExpression =
        compileOrEmpty(pattern: #"^\s*(?:<[^>]+>[^<]*)+\s*$"#, label: "markupOnlyPattern")

    /// Returns true when the extracted user text is Claude-Code-harness noise rather than real prose.
    static func isHarnessJunk(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        for prefix in junkPrefixes where trimmed.hasPrefix(prefix) {
            return true
        }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        if markupOnlyPattern.firstMatch(in: trimmed, range: range) != nil {
            return true
        }
        return false
    }

    /// Returns true when a "user" event is a tool_result carrier (internal turn, not a real user message).
    /// Shape: message.content is an array whose first block has type:"tool_result".
    private func isToolResultCarrier(_ obj: [String: Any]) -> Bool {
        guard let msg = obj["message"] as? [String: Any],
              let blocks = msg["content"] as? [[String: Any]],
              let firstBlock = blocks.first,
              let blockType = firstBlock["type"] as? String else {
            return false
        }
        return blockType == "tool_result"
    }

    // MARK: - Flag detection

    /// Pattern matcher: does the string contain `git push` (whitespace-tolerant)?
    /// Case-insensitive; matches `git push`, `git  push`, `git\tpush`.
    static func mentionsGitPush(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        let lower = s.lowercased()
        // Fast path; if `git ` substring isn't present, neither is `git push`.
        guard lower.contains("git") else { return false }
        return Self.gitPushRegex.firstMatch(
            in: lower,
            range: NSRange(lower.startIndex..<lower.endIndex, in: lower)
        ) != nil
    }

    private static let gitPushRegex: NSRegularExpression =
        compileOrEmpty(pattern: #"(^|[^a-z0-9])git\s+push($|[^a-z0-9])"#, label: "gitPushRegex")

    /// Pattern matcher: error signals typical of a failed shell tool_result:
    /// `error:`, `Error:`, `exit code: 1..9`, `non-zero exit`, `command failed`.
    static func containsErrorSignal(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        let lower = s.lowercased()
        if lower.contains("error:") { return true }
        if lower.contains("command failed") { return true }
        if lower.contains("non-zero exit") { return true }
        let range = NSRange(lower.startIndex..<lower.endIndex, in: lower)
        if Self.exitCodeRegex.firstMatch(in: lower, range: range) != nil { return true }
        return false
    }

    private static let exitCodeRegex: NSRegularExpression =
        compileOrEmpty(pattern: #"exit code:?\s*[1-9]"#, label: "exitCodeRegex")

    /// Compile-once regex helper. Returns a benign "match nothing" regex if
    /// the literal pattern ever fails to compile; guaranteed not to crash
    /// the main target. We log the failure to the unified log so the first
    /// developer to see the degradation knows what went wrong.
    fileprivate static func compileOrEmpty(pattern: String, label: String) -> NSRegularExpression {
        if let r = try? NSRegularExpression(pattern: pattern, options: []) {
            return r
        }
        AppLogger.parser.error("Failed to compile regex '\(label)': \(pattern)")
        // Return a regex that will never match anything.
        // `(?!)` is a negative lookahead that is always false; every NSRegularExpression
        // implementation supports this ICU-regex escape hatch.
        return (try? NSRegularExpression(pattern: "(?!)", options: [])) ?? NSRegularExpression()
    }

    /// Inspects a `tool_use` event for `input.command` containing `git push`.
    /// Matches both top-level and nested `message.content` shapes.
    fileprivate static func toolUseMentionsGitPush(_ obj: [String: Any]) -> Bool {
        if let input = obj["input"] as? [String: Any],
           let cmd = input["command"] as? String,
           mentionsGitPush(cmd) {
            return true
        }
        // Nested via message.content blocks (`type: tool_use` with `input.command`).
        if let msg = obj["message"] as? [String: Any],
           let blocks = msg["content"] as? [[String: Any]] {
            for b in blocks {
                if (b["type"] as? String) == "tool_use",
                   let input = b["input"] as? [String: Any],
                   let cmd = input["command"] as? String,
                   mentionsGitPush(cmd) {
                    return true
                }
            }
        }
        return false
    }

    /// Inspects an assistant message's `content` array for inline `tool_use`
    /// blocks that call shell commands containing `git push`.
    fileprivate static func assistantContentMentionsGitPush(_ msg: [String: Any]) -> Bool {
        guard let blocks = msg["content"] as? [[String: Any]] else { return false }
        for b in blocks {
            if (b["type"] as? String) == "tool_use",
               let input = b["input"] as? [String: Any],
               let cmd = input["command"] as? String,
               mentionsGitPush(cmd) {
                return true
            }
        }
        return false
    }

    /// Inspects a `tool_result` event for error signals in its content text.
    fileprivate static func toolResultLooksErrored(_ obj: [String: Any]) -> Bool {
        if let c = obj["content"] as? String, containsErrorSignal(c) { return true }
        if let blocks = obj["content"] as? [[String: Any]] {
            for b in blocks {
                if let t = b["text"] as? String, containsErrorSignal(t) { return true }
                if let t = b["content"] as? String, containsErrorSignal(t) { return true }
            }
        }
        if let msg = obj["message"] as? [String: Any] {
            if let blocks = msg["content"] as? [[String: Any]] {
                for b in blocks {
                    if (b["type"] as? String) == "tool_result" {
                        if let t = b["content"] as? String, containsErrorSignal(t) { return true }
                        if let arr = b["content"] as? [[String: Any]] {
                            for sub in arr {
                                if let tt = sub["text"] as? String, containsErrorSignal(tt) {
                                    return true
                                }
                            }
                        }
                    }
                }
            }
        }
        return false
    }

    /// When a "user" event is a tool_result carrier, inspect its embedded
    /// tool_result block(s) for error signals.
    fileprivate static func userMessageCarriesErroredToolResult(_ obj: [String: Any]) -> Bool {
        guard let msg = obj["message"] as? [String: Any],
              let blocks = msg["content"] as? [[String: Any]] else { return false }
        for b in blocks where (b["type"] as? String) == "tool_result" {
            if let t = b["content"] as? String, containsErrorSignal(t) { return true }
            if let arr = b["content"] as? [[String: Any]] {
                for sub in arr {
                    if let tt = sub["text"] as? String, containsErrorSignal(tt) {
                        return true
                    }
                }
            }
            // is_error: true signal (common in tool_result blocks)
            if let flag = b["is_error"] as? Bool, flag { return true }
        }
        return false
    }

    /// Returns the concatenated plaintext of every user + assistant text block in a
    /// jsonl session, joined by newlines. Skips tool_use, tool_result, thinking, and
    /// image blocks; skips harness-injected pseudo-user messages. Intended for the
    /// FTS5 `body` column. NOT for display. May throw on file read errors.
    public func extractPlaintext(url: URL) throws -> String {
        let raw = try String(contentsOf: url, encoding: .utf8)
        let lines = raw.split(whereSeparator: \.isNewline)
        var pieces: [String] = []
        pieces.reserveCapacity(64)

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            guard let type = obj["type"] as? String else { continue }

            switch type {
            case "user":
                if isToolResultCarrier(obj) { continue }
                if let text = extractAllText(from: obj),
                   !Self.isHarnessJunk(text) {
                    pieces.append(text)
                }
            case "assistant":
                if let text = extractAllText(from: obj) {
                    pieces.append(text)
                }
            default:
                continue
            }
        }
        return pieces.joined(separator: "\n")
    }

    /// Like `extractTextContent` but concatenates ALL text blocks in a message
    /// (newline-separated) rather than returning only the first. Used for FTS
    /// indexing where we want the full body.
    private func extractAllText(from obj: [String: Any]) -> String? {
        // Flat shape (legacy fixture): {"type":"user","content":"..."}
        if let s = obj["content"] as? String, !s.isEmpty {
            return s
        }
        guard let msg = obj["message"] as? [String: Any] else { return nil }
        if let s = msg["content"] as? String, !s.isEmpty {
            return s
        }
        if let blocks = msg["content"] as? [[String: Any]] {
            var texts: [String] = []
            for block in blocks {
                guard let blockType = block["type"] as? String else { continue }
                if blockType == "text", let t = block["text"] as? String, !t.isEmpty {
                    texts.append(t)
                }
            }
            if !texts.isEmpty { return texts.joined(separator: "\n") }
        }
        return nil
    }

    /// Extracts the first non-empty text block from a user/assistant event.
    /// Handles flat-string `content` and nested `message.content` (string OR array of blocks).
    /// Skips tool_use, tool_result, thinking, and image blocks.
    private func extractTextContent(from obj: [String: Any]) -> String? {
        // Flat shape (legacy fixture): {"type":"user","content":"..."}
        if let s = obj["content"] as? String, !s.isEmpty {
            return s
        }
        // Nested shape (real Claude Code): {"type":"user","message":{"content":"..."}}
        guard let msg = obj["message"] as? [String: Any] else { return nil }
        // String content
        if let s = msg["content"] as? String, !s.isEmpty {
            return s
        }
        // Array of content blocks: find the first text block with non-empty text,
        // skipping tool_use, tool_result, thinking, image, etc.
        if let blocks = msg["content"] as? [[String: Any]] {
            for block in blocks {
                guard let blockType = block["type"] as? String else { continue }
                switch blockType {
                case "text":
                    if let text = block["text"] as? String, !text.isEmpty {
                        return text
                    }
                case "tool_use", "tool_result", "thinking", "image":
                    continue
                default:
                    continue
                }
            }
        }
        return nil
    }
}
