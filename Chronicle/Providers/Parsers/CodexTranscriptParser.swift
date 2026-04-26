import Foundation

/// Light-weight transcript parser for Codex CLI rollout files. Produces
/// the same `Transcript` shape Claude's `TranscriptParser` does so the
/// preview pane and the (eventual) transcript drawer don't have to
/// branch on provider.
///
/// We deliberately do not produce ordered messages here — the preview
/// pane only consumes `Transcript.Stats` (Files Touched, Tools Used,
/// token split, message split), and a full message walker for Codex's
/// nested `response_item` shape would be substantially more code than
/// the preview is worth. If a future feature wants the full
/// transcript drawer for Codex we'll grow this then.
///
/// Inputs:
///   - the rollout JSONL file at `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`
///
/// Outputs (Stats only; messages stays empty):
///   - `userTurns` / `assistantTurns` from `response_item` `message` events
///     scoped to user / assistant roles
///   - `tokensInput` / `tokensOutput` from the latest `event_msg` / `token_count`
///     event (Codex emits cumulative totals, last writer wins)
///   - `toolUseCounts` keyed on the tool name extracted from BOTH:
///       1. `function_call` events — `exec_command`, `write_stdin`,
///          `view_image`, etc. Arguments are a JSON-encoded **string**
///          on `payload.arguments` and we second-stage decode it.
///       2. `custom_tool_call` events — `apply_patch` lives here as of
///          Codex CLI ~0.120; the patch body is on `payload.input`
///          directly (already a string, no inner JSON).
///   - `filesTouched` extracted heuristically from:
///       1. `apply_patch` invocations (custom_tool_call) — the `input`
///          field is the patch body with `*** Update File: <path>` /
///          `*** Add File: <path>` / `*** Delete File: <path>` /
///          `*** Move File: <old> -> <new>` headers
///       2. legacy `apply_patch` `function_call` shapes whose
///          `arguments.input` or `arguments.changes[*].path` carries
///          the same info
///       3. `exec_command` invocations whose `cmd` embeds a patch
///          heredoc (rare, but seen)
public struct CodexTranscriptParser {
    public init() {}

    public enum ParseError: Error {
        case noSessionIDInFilename(URL)
        case unreadable(URL)
    }

    /// Parse a Codex rollout into a `Transcript` carrying populated
    /// `Stats`. Empty messages array — see type-level note. Returns an
    /// empty transcript (not an error) for an empty file so the preview
    /// pane can still render a frame.
    public func parse(url: URL, sessionID: SessionID, workspaceID: String) throws -> Transcript {
        let raw: String
        do {
            raw = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ParseError.unreadable(url)
        }
        let now = Date()
        if raw.isEmpty {
            return Transcript.empty(sessionID: sessionID, workspaceID: workspaceID, now: now)
        }

        var firstTimestamp: Date?
        var lastTimestamp: Date?
        var userTurns = 0
        var assistantTurns = 0
        var tokensInput = 0
        var tokensOutput = 0
        var toolUseCounts: [String: Int] = [:]
        var filesTouched: [String: Int] = [:]
        var lastModel: String?

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()
        isoNoFrac.formatOptions = [.withInternetDateTime]

        for line in raw.split(whereSeparator: \.isNewline) {
            try Task.checkCancellation()
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if let ts = obj["timestamp"] as? String,
               let date = iso.date(from: ts) ?? isoNoFrac.date(from: ts) {
                if firstTimestamp == nil { firstTimestamp = date }
                lastTimestamp = date
            }

            guard let type = obj["type"] as? String else { continue }
            let payload = obj["payload"] as? [String: Any]

            switch type {
            case "session_meta":
                if let mp = payload?["model_provider"] as? String { lastModel = mp }

            case "response_item":
                guard let p = payload else { continue }
                let pType = p["type"] as? String

                if pType == "message", let role = p["role"] as? String {
                    switch role {
                    case "user":      userTurns += 1
                    case "assistant": assistantTurns += 1
                    default: break
                    }
                } else if pType == "function_call",
                          let name = p["name"] as? String, !name.isEmpty {
                    toolUseCounts[name, default: 0] += 1
                    // Pull file paths out of the arguments payload. Codex
                    // serializes `arguments` as a JSON-encoded STRING (not a
                    // nested object) so we have to second-stage decode it.
                    if let argsString = p["arguments"] as? String,
                       let argsData = argsString.data(using: .utf8),
                       let argsObj = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
                        Self.extractFilePaths(toolName: name, args: argsObj).forEach { path in
                            filesTouched[path, default: 0] += 1
                        }
                    }
                } else if pType == "custom_tool_call",
                          let name = p["name"] as? String, !name.isEmpty {
                    // Codex CLI ~0.120 lifted apply_patch out of the
                    // function_call schema into custom_tool_call: the
                    // patch body is on `payload.input` directly (a
                    // string, not a JSON-encoded args bag).
                    toolUseCounts[name, default: 0] += 1
                    if let input = p["input"] as? String, !input.isEmpty {
                        Self.extractFilePathsFromCustomToolCall(toolName: name, input: input)
                            .forEach { filesTouched[$0, default: 0] += 1 }
                    }
                }

            case "event_msg":
                guard let p = payload, let evType = p["type"] as? String else { continue }
                if evType == "token_count",
                   let info = p["info"] as? [String: Any],
                   let total = info["total_token_usage"] as? [String: Any] {
                    // Cumulative — last writer wins.
                    tokensInput = total["input_tokens"] as? Int ?? tokensInput
                    tokensOutput = total["output_tokens"] as? Int ?? tokensOutput
                }

            default:
                break
            }
        }

        let created = firstTimestamp ?? now
        let modified = lastTimestamp ?? created

        let touches = filesTouched
            .map { Transcript.FileTouch(path: $0.key, edits: $0.value) }
            .sorted { $0.edits > $1.edits }

        let stats = Transcript.Stats(
            createdAt: created,
            lastModifiedAt: modified,
            userTurns: userTurns,
            assistantTurns: assistantTurns,
            tokensInput: tokensInput,
            tokensOutput: tokensOutput,
            toolUseCounts: toolUseCounts,
            filesTouched: touches,
            model: lastModel
        )
        return Transcript(
            sessionID: sessionID,
            workspaceID: workspaceID,
            messages: [],
            stats: stats
        )
    }

    // MARK: - File-path extraction

    /// Return file paths plausibly touched by a single tool call. Best
    /// effort — the goal is signal-over-blank, not perfection. We
    /// recognise:
    ///   - `apply_patch` invocations whose `cmd` embeds a heredoc with
    ///     `*** Update File: <path>` / `*** Add File: <path>` /
    ///     `*** Delete File: <path>` headers
    ///   - `exec_command` invocations whose `cmd` starts with a
    ///     write-shaped command and references an obvious path
    ///     argument

    /// Decide whether a shell argument token is plausibly a file path.
    /// Conservative — prefers false negatives over false positives so we
    /// don't surface flag values, glob patterns, or quoted regexes as
    /// touched files. Strips a single layer of single/double quotes
    /// before evaluating.
    public static func isPathLikeToken(_ raw: String) -> Bool {
        var t = raw
        if let first = t.first, (first == "'" || first == "\""),
           let last = t.last, first == last, t.count >= 2 {
            t = String(t.dropFirst().dropLast())
        }
        guard !t.isEmpty else { return false }
        if t.hasPrefix("-") { return false }
        if t.contains("*") || t.first == "!" { return false }
        if t.contains("/") || t.hasPrefix("./") || t.hasPrefix("../") || t.hasPrefix("~/") {
            return true
        }
        let extensions: Set<String> = [
            "swift", "ts", "tsx", "js", "jsx", "mjs", "cjs",
            "py", "go", "rs", "rb", "java", "kt", "scala",
            "c", "cpp", "cc", "cxx", "h", "hh", "hpp", "m", "mm",
            "md", "txt", "json", "yaml", "yml", "toml", "xml",
            "html", "css", "scss", "sass", "sql", "sh", "zsh", "bash",
            "lock", "plist", "resolved"
        ]
        if let dotIdx = t.lastIndex(of: ".") {
            let ext = String(t[t.index(after: dotIdx)...]).lowercased()
            if extensions.contains(ext) { return true }
        }
        return false
    }

    /// Minimal shell tokenizer. Splits on unquoted whitespace; preserves
    /// single- and double-quoted strings (with the quotes intact so the
    /// caller can decide whether to strip). Handles backslash-escape for
    /// the next character. Good enough for the shell shapes codex emits;
    /// a real shell parser would be overkill.
    public static func tokenizeShell(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var quote: Character? = nil
        var iter = s.makeIterator()
        while let ch = iter.next() {
            if let q = quote {
                cur.append(ch)
                if ch == q { quote = nil }
                continue
            }
            if ch == "'" || ch == "\"" {
                cur.append(ch)
                quote = ch
                continue
            }
            if ch == "\\" {
                if let next = iter.next() { cur.append(next) }
                continue
            }
            if ch.isWhitespace {
                if !cur.isEmpty { out.append(cur); cur = "" }
                continue
            }
            cur.append(ch)
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    static func extractFilePaths(toolName: String, args: [String: Any]) -> [String] {
        switch toolName {
        case "apply_patch":
            var paths: [String] = []
            if let input = args["input"] as? String, !input.isEmpty {
                paths.append(contentsOf: parseApplyPatchHeaders(input))
            }
            if let changes = args["changes"] as? [[String: Any]] {
                for c in changes {
                    if let p = c["path"] as? String, !p.isEmpty { paths.append(p) }
                }
            }
            return paths

        case "exec_command", "shell":
            guard let cmd = args["cmd"] as? String, !cmd.isEmpty else { return [] }
            if cmd.contains("apply_patch") || cmd.contains("*** Begin Patch") {
                return parseApplyPatchHeaders(cmd)
            }
            return extractPathsFromShellCommand(cmd)

        default:
            return []
        }
    }

    /// Heuristic file-path extraction from a shell `cmd` string. Only
    /// inspects the FIRST pipe-segment — subsequent segments operate on
    /// stdin, not files, so their argv is misleading. Returns paths in
    /// argv order, deduped, with surrounding quotes stripped.
    static func extractPathsFromShellCommand(_ cmd: String) -> [String] {
        let firstSegment = cmd.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? cmd
        let tokens = tokenizeShell(firstSegment)
        guard let rawHead = tokens.first else { return [] }
        let head = stripOuterQuotes(rawHead)

        let skipHeads: Set<String> = [
            "swift", "git", "gh", "ls", "pwd", "which", "cd", "echo",
            "mkdir", "rmdir", "chmod", "chown", "rm", "mv", "cp",
            "npm", "pnpm", "yarn", "cargo", "make", "brew",
            "python", "python3", "node", "ruby", "go",
            "kill", "pkill", "ps", "top", "htop"
        ]
        let patternConsumers: Set<String> = ["grep", "rg", "ag", "sed", "awk"]

        var paths: [String] = []
        var seen = Set<String>()
        func append(_ raw: String) {
            let cleaned = stripOuterQuotes(raw)
            guard !cleaned.isEmpty, !seen.contains(cleaned) else { return }
            seen.insert(cleaned)
            paths.append(cleaned)
        }

        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            if t == ">" || t == ">>" || t == "2>" || t == "&>" {
                if i + 1 < tokens.count, isPathLikeToken(tokens[i+1]) {
                    append(tokens[i+1])
                }
                i += 2
                continue
            }
            i += 1
        }

        if skipHeads.contains(head) { return paths }

        var argIdx = 1
        if patternConsumers.contains(head) {
            var foundPattern = false
            let consumesNext: Set<String> = ["-e", "-f", "-g", "--regexp", "--file", "--glob"]
            while argIdx < tokens.count {
                let tok = tokens[argIdx]
                if tok.hasPrefix("-") {
                    if consumesNext.contains(tok) { argIdx += 2 } else { argIdx += 1 }
                    continue
                }
                argIdx += 1
                foundPattern = true
                break
            }
            if !foundPattern { return paths }
        }

        while argIdx < tokens.count {
            let tok = tokens[argIdx]
            if tok.hasPrefix("-") || tok == "|" || tok == ";" || tok == "&&" {
                argIdx += 1
                continue
            }
            if isPathLikeToken(tok) { append(tok) }
            argIdx += 1
        }

        return paths
    }

    private static func stripOuterQuotes(_ s: String) -> String {
        guard s.count >= 2,
              let first = s.first, let last = s.last,
              first == last, (first == "'" || first == "\"") else { return s }
        return String(s.dropFirst().dropLast())
    }

    /// Return file paths plausibly touched by a `custom_tool_call`
    /// payload. As of Codex CLI ~0.120, `apply_patch` is delivered this
    /// way and `payload.input` carries the raw patch body — not a
    /// JSON-encoded args dictionary.
    static func extractFilePathsFromCustomToolCall(toolName: String, input: String) -> [String] {
        switch toolName {
        case "apply_patch":
            return parseApplyPatchHeaders(input)
        case "exec_command", "shell":
            if input.contains("apply_patch") || input.contains("*** Begin Patch") {
                return parseApplyPatchHeaders(input)
            }
            return extractPathsFromShellCommand(input)
        default:
            if input.contains("*** Begin Patch") || input.contains("*** End Patch") {
                return parseApplyPatchHeaders(input)
            }
            return []
        }
    }

    /// Extract every file path mentioned in apply_patch's standard
    /// `*** Update File:` / `*** Add File:` / `*** Delete File:` /
    /// `*** Move File:` line prefixes. Tolerant of arbitrary leading
    /// whitespace and embedded line continuations.
    static func parseApplyPatchHeaders(_ body: String) -> [String] {
        var out: [String] = []
        for rawLine in body.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            for marker in ["*** Update File:", "*** Add File:", "*** Delete File:", "*** Move File:"] {
                if line.hasPrefix(marker) {
                    var path = String(line.dropFirst(marker.count))
                        .trimmingCharacters(in: .whitespaces)
                    // Move File rewrites as `<old> -> <new>`; record the
                    // destination so the user sees where the file landed.
                    if let arrow = path.range(of: "->") {
                        path = String(path[arrow.upperBound...])
                            .trimmingCharacters(in: .whitespaces)
                    }
                    if !path.isEmpty { out.append(path) }
                    break
                }
            }
        }
        return out
    }
}
