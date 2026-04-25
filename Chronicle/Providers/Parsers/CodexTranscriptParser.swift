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
///   - `toolUseCounts` keyed on the tool name extracted from `function_call`
///     events. Codex's primary tool is `exec_command`; some sessions also
///     show `apply_patch`, `write_stdin`, etc.
///   - `filesTouched` extracted heuristically from:
///       1. `apply_patch` invocations — the `cmd` field embeds a heredoc
///          with `*** Update File: <path>` / `*** Add File: <path>` /
///          `*** Delete File: <path>` headers
///       2. `exec_command` invocations whose `cmd` contains common
///          editor / cat-style writes (best-effort, intentionally not
///          comprehensive — partial coverage beats blank "—" cells)
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
    static func extractFilePaths(toolName: String, args: [String: Any]) -> [String] {
        switch toolName {
        case "apply_patch":
            // Newer Codex: the patch body sits under a top-level `input` key
            // (string), or in `args.changes[*].path`. Older versions stuffed
            // the whole patch into a shell `cmd`. Try both.
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
            // apply_patch is occasionally invoked via exec_command with the
            // patch body in `cmd`; honour the same header extraction.
            if cmd.contains("apply_patch") || cmd.contains("*** Begin Patch") {
                return parseApplyPatchHeaders(cmd)
            }
            return []

        default:
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
