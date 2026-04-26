import Foundation

/// Light-weight transcript parser for Gemini CLI session JSON files.
/// Produces the same `Transcript` shape Claude / Codex use so the
/// preview pane can display Files Touched / Tools Used / token split
/// without branching on provider.
///
/// Inputs:
///   - the session JSON file at
///     `~/.gemini/tmp/<project_dir>/chats/session-*.json`
///
/// Outputs (Stats only; messages stays empty — matching CodexTranscriptParser):
///   - `userTurns` / `assistantTurns` from messages whose `type` is
///     `"user"` / `"gemini"`
///   - `tokensInput` / `tokensOutput` summed across every assistant
///     turn's `tokens` block
///   - `toolUseCounts` keyed on the `name` field of:
///       1. each entry in the assistant turn's top-level
///          `toolCalls: [{ id, name, args, result, ... }]` array — this
///          is the real on-disk shape Gemini CLI writes
///       2. legacy `content[].functionCall` blocks (older Gemini
///          versions / some test fixtures) — kept for back-compat
///   - `filesTouched` extracted heuristically from common Gemini tool
///     argument shapes:
///         * `file_path` (read_file, write_file, replace)
///         * `path` (older shape)
///         * `dir_path` (list_directory)
///         * `target_file`, `absolute_path`
///         * `edits[].path` arrays
public struct GeminiTranscriptParser {
    public init() {}

    public enum ParseError: Error {
        case unreadable(URL)
        case malformed(URL)
    }

    /// Parse a Gemini session file into a `Transcript`. Empty messages
    /// array — only `Stats` is populated. Returns an empty transcript
    /// (not an error) for empty / malformed files so the preview pane
    /// can still render a frame.
    public func parse(url: URL, sessionID: SessionID, workspaceID: String) throws -> Transcript {
        let now = Date()
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ParseError.unreadable(url)
        }
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Transcript.empty(sessionID: sessionID, workspaceID: workspaceID, now: now)
        }

        var userTurns = 0
        var assistantTurns = 0
        var tokensInput = 0
        var tokensOutput = 0
        var toolUseCounts: [String: Int] = [:]
        var filesTouched: [String: Int] = [:]
        var lastModel: String?
        var messageBuffer: [TranscriptMessage] = []

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()
        isoNoFrac.formatOptions = [.withInternetDateTime]

        // Parse session-level timestamps up front so per-message
        // fallback can land on `startTime` instead of `Date()` (the
        // simplest correct behavior when a message lacks its own
        // timestamp string).
        let startTime = (raw["startTime"] as? String).flatMap {
            iso.date(from: $0) ?? isoNoFrac.date(from: $0)
        } ?? now
        let lastUpdated = (raw["lastUpdated"] as? String).flatMap {
            iso.date(from: $0) ?? isoNoFrac.date(from: $0)
        } ?? startTime

        let messages = (raw["messages"] as? [[String: Any]]) ?? []
        for msg in messages {
            try Task.checkCancellation()
            let type = msg["type"] as? String ?? ""
            switch type {
            case "user":
                userTurns += 1
                let text = Self.extractMessageText(from: msg)
                let ts = Self.parseMessageTimestamp(msg["timestamp"], iso: iso, isoNoFrac: isoNoFrac) ?? startTime
                let msgID = "\(sessionID.description)-\(messageBuffer.count)"
                messageBuffer.append(.user(UserTurn(id: msgID, timestamp: ts, markdown: text)))

            case "gemini":
                assistantTurns += 1
                if let m = msg["model"] as? String, !m.isEmpty { lastModel = m }
                let perInput = (msg["tokens"] as? [String: Any])?["input"] as? Int ?? 0
                let perOutput = (msg["tokens"] as? [String: Any])?["output"] as? Int ?? 0
                tokensInput += perInput
                tokensOutput += perOutput
                let text = Self.extractMessageText(from: msg)
                let ts = Self.parseMessageTimestamp(msg["timestamp"], iso: iso, isoNoFrac: isoNoFrac) ?? startTime
                let msgID = "\(sessionID.description)-\(messageBuffer.count)"
                messageBuffer.append(.assistant(AssistantTurn(
                    id: msgID,
                    timestamp: ts,
                    markdown: text,
                    tokensInput: perInput,
                    tokensOutput: perOutput,
                    model: lastModel
                )))

                // Real on-disk shape: assistant messages carry a
                // top-level `toolCalls: [{ name, args, result, ... }]`
                // array. This is where every real Gemini session
                // records its tool calls — `read_file`, `write_file`,
                // `list_directory`, `run_shell_command`, `grep_search`
                // and friends.
                if let toolCalls = msg["toolCalls"] as? [[String: Any]] {
                    for tc in toolCalls {
                        guard let name = tc["name"] as? String, !name.isEmpty else { continue }
                        toolUseCounts[name, default: 0] += 1
                        let argsObj = (tc["args"] as? [String: Any])
                            ?? (tc["arguments"] as? [String: Any])
                            ?? [:]
                        for path in Self.extractFilePaths(toolName: name, args: argsObj) {
                            filesTouched[path, default: 0] += 1
                        }
                        // Emit a ToolCall message so the transcript
                        // view shows the call inline AFTER the
                        // assistant turn that triggered it (matching
                        // Claude's shape).
                        var argsJSON: [String: JSONValue] = [:]
                        for (k, v) in argsObj { argsJSON[k] = JSONValue.from(v) }
                        let resultText: String? = {
                            if let s = tc["result"] as? String { return s }
                            if let any = tc["result"] {
                                return JSONValue.from(any).prettyJSONString()
                            }
                            return nil
                        }()
                        let tcID = "\(sessionID.description)-tc-\(messageBuffer.count)"
                        messageBuffer.append(.toolCall(ToolCall(
                            id: tcID,
                            timestamp: ts,
                            name: name,
                            args: argsJSON,
                            resultText: resultText,
                            durationMs: nil
                        )))
                    }
                }

                // Back-compat: older Gemini versions and some test
                // fixtures embed tool calls as `content[].functionCall`
                // blocks (Claude-shaped). Keep this path so existing
                // fixtures continue to work; the union with toolCalls
                // is fine because real sessions only emit one or the
                // other.
                if let blocks = msg["content"] as? [[String: Any]] {
                    for block in blocks {
                        if let fc = block["functionCall"] as? [String: Any],
                           let name = fc["name"] as? String, !name.isEmpty {
                            toolUseCounts[name, default: 0] += 1
                            let argsObj = (fc["args"] as? [String: Any])
                                ?? (fc["arguments"] as? [String: Any])
                                ?? [:]
                            for path in Self.extractFilePaths(toolName: name, args: argsObj) {
                                filesTouched[path, default: 0] += 1
                            }
                            // Emit a ToolCall message — back-compat
                            // shape carries no result, so resultText
                            // stays nil.
                            var argsJSON: [String: JSONValue] = [:]
                            for (k, v) in argsObj { argsJSON[k] = JSONValue.from(v) }
                            let tcID = "\(sessionID.description)-tc-\(messageBuffer.count)"
                            messageBuffer.append(.toolCall(ToolCall(
                                id: tcID,
                                timestamp: ts,
                                name: name,
                                args: argsJSON,
                                resultText: nil,
                                durationMs: nil
                            )))
                        }
                    }
                }

            default:
                break
            }
        }

        let touches = filesTouched
            .map { Transcript.FileTouch(path: $0.key, edits: $0.value) }
            .sorted { $0.edits > $1.edits }

        let stats = Transcript.Stats(
            createdAt: startTime,
            lastModifiedAt: lastUpdated,
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
            messages: messageBuffer,
            stats: stats
        )
    }

    // MARK: - Message text / timestamp helpers

    /// Pull plain-text content out of a Gemini message dictionary.
    /// Gemini writes `content` as either a String (most user messages
    /// + many assistant messages) or a list of `{text: ...}` blocks
    /// (occasional Claude-shaped fixtures, and some assistant turns).
    /// Both shapes appear in real `~/.gemini/tmp/**` data, so we have
    /// to handle each.
    private static func extractMessageText(from msg: [String: Any]) -> String {
        if let s = msg["content"] as? String { return s }
        if let blocks = msg["content"] as? [[String: Any]] {
            var parts: [String] = []
            for block in blocks {
                if let t = block["text"] as? String, !t.isEmpty {
                    parts.append(t)
                }
            }
            return parts.joined(separator: "\n")
        }
        return ""
    }

    /// Parse a per-message ISO-8601 timestamp string. Returns `nil`
    /// when the field is missing or unparseable; the caller falls
    /// back to `startTime` so the message ordering stays sensible.
    private static func parseMessageTimestamp(_ raw: Any?,
                                              iso: ISO8601DateFormatter,
                                              isoNoFrac: ISO8601DateFormatter) -> Date? {
        guard let s = raw as? String else { return nil }
        return iso.date(from: s) ?? isoNoFrac.date(from: s)
    }

    // MARK: - File-path extraction

    /// Best-effort extraction of file paths from Gemini tool args. We
    /// recognise the shapes that show up in real `~/.gemini/tmp/**`
    /// sessions:
    ///   - `file_path` — `read_file`, `write_file`, `replace`
    ///   - `dir_path` — `list_directory`
    ///   - `path` — older / generic
    ///   - `target_file`, `absolute_path` — occasional variants
    ///   - arrays of any of the above
    ///   - `edits[].path` — replace_string_in_file shape
    /// Arbitrary tools we can't inspect get nothing; the preview pane
    /// just shows fewer rows.
    static func extractFilePaths(toolName: String, args: [String: Any]) -> [String] {
        var out: [String] = []
        let pathKeys = ["file_path", "dir_path", "path", "target_file", "absolute_path"]
        for key in pathKeys {
            if let s = args[key] as? String, !s.isEmpty {
                out.append(s)
            } else if let arr = args[key] as? [String] {
                out.append(contentsOf: arr.filter { !$0.isEmpty })
            }
        }
        // `edits` array (replace_string_in_file shape): each entry holds
        // its own path.
        if let edits = args["edits"] as? [[String: Any]] {
            for e in edits {
                if let p = e["path"] as? String, !p.isEmpty { out.append(p) }
            }
        }
        return out
    }
}
