import Foundation

/// Walks a Claude Code session jsonl file into an ordered list of user +
/// assistant + tool-call messages, along with aggregate stats. Separate
/// from `JsonlParser` (which only extracts metadata for the SQLite index)
/// so the transcript path stays lazy; only invoked when the user opens
/// the transcript view.
public struct TranscriptParser {
    public enum ParseError: Error {
        case noSessionIDInFilename(URL)
    }

    public init() {}

    /// Maximum size of any single tool_result carried into the transcript.
    /// Matches the spec; anything past 10 KB gets truncated with a marker
    /// so we don't ruin layout on a multi-megabyte grep dump.
    public static let maxToolResultLength = 10 * 1024

    // MARK: - Public API

    /// Parse the session jsonl at `url` under `workspaceID`. Returns an
    /// empty transcript (not an error) for empty files so the view can
    /// still render a frame. Throws only on real IO failures or if the
    /// filename doesn't contain a UUID.
    public func parse(url: URL, workspaceID: String) throws -> Transcript {
        let stem = url.deletingPathExtension().lastPathComponent
        let sessionID = try SessionID(string: stem)

        let now = Date()
        let raw: String
        do {
            raw = try String(contentsOf: url, encoding: .utf8)
        } catch {
            // File doesn't exist or is unreadable; bubble the error up
            // so callers can show a TCC / "file gone" hint. Empty-string
            // fallback would be confusing.
            throw error
        }
        if raw.isEmpty {
            return Transcript.empty(sessionID: sessionID, workspaceID: workspaceID, now: now)
        }

        var walker = Walker(sessionID: sessionID, workspaceID: workspaceID, now: now)
        for line in raw.split(whereSeparator: \.isNewline) {
            try Task.checkCancellation()
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            walker.ingest(obj)
        }
        return walker.finalize()
    }
}

// MARK: - Walker

/// Internal state machine that threads tool_use events from assistant
/// messages into the final ordered list, then matches tool_result carriers
/// back to the tool_call they belong to.
private struct Walker {
    // Configuration
    let sessionID: SessionID
    let workspaceID: String
    let now: Date

    // Ordered output
    private var messages: [TranscriptMessage] = []

    // Aggregates
    private var createdAt: Date?
    private var lastModifiedAt: Date?
    private var userTurns = 0
    private var assistantTurns = 0
    private var tokensInput = 0
    private var tokensOutput = 0
    private var toolUseCounts: [String: Int] = [:]
    private var filesTouched: [String: Int] = [:]
    private var filesOrder: [String] = []
    private var model: String?

    /// Index maps tool_use_id -> index into `messages`. Updated as tool
    /// calls are appended so tool_result blocks can patch in the result
    /// text without an O(N) scan.
    private var toolCallIndex: [String: Int] = [:]
    /// Timestamp of each tool_use by id, for duration computation when we
    /// see the matching tool_result.
    private var toolCallStartedAt: [String: Date] = [:]

    // Date parsers; construct once per walker rather than per event.
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let isoNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    init(sessionID: SessionID, workspaceID: String, now: Date) {
        self.sessionID = sessionID
        self.workspaceID = workspaceID
        self.now = now
    }

    // MARK: - Event dispatch

    mutating func ingest(_ obj: [String: Any]) {
        guard let type = obj["type"] as? String else { return }

        let ts = (obj["timestamp"] as? String).flatMap {
            iso.date(from: $0) ?? isoNoFrac.date(from: $0)
        }
        if createdAt == nil, let ts { createdAt = ts }
        if let ts { lastModifiedAt = ts }

        switch type {
        case "user":
            ingestUser(obj, ts: ts)
        case "assistant":
            ingestAssistant(obj, ts: ts)
        default:
            // Unknown top-level types (summary, system, attachment, ...).
            // We don't surface them in the transcript.
            break
        }
    }

    // MARK: - user

    private mutating func ingestUser(_ obj: [String: Any], ts: Date?) {
        // tool_result carrier? Thread the result text back to the matching
        // tool_call and do NOT emit a user turn.
        if let blocks = userContentBlocks(obj) {
            let toolResults = blocks.filter { ($0["type"] as? String) == "tool_result" }
            if !toolResults.isEmpty {
                for block in toolResults {
                    attachToolResult(block: block, ts: ts)
                }
                return
            }
        }

        // Normal user turn; concat all text blocks, filter harness junk.
        let text = concatUserText(obj)
        guard let text, !JsonlParser.isHarnessJunk(text) else { return }

        userTurns += 1
        let id = (obj["uuid"] as? String)
            ?? (obj["message"] as? [String: Any]).flatMap { $0["id"] as? String }
            ?? "u-\(messages.count)-\(Int(ts?.timeIntervalSince1970 ?? 0))"

        messages.append(.user(UserTurn(
            id: id,
            timestamp: ts ?? now,
            markdown: text
        )))
    }

    /// Returns the content-block array for a user event if there is one,
    /// or nil if content is a flat string / missing.
    private func userContentBlocks(_ obj: [String: Any]) -> [[String: Any]]? {
        if let msg = obj["message"] as? [String: Any],
           let blocks = msg["content"] as? [[String: Any]] {
            return blocks
        }
        return nil
    }

    private func concatUserText(_ obj: [String: Any]) -> String? {
        // Flat shape (legacy fixture): {"type":"user","content":"..."}
        if let s = obj["content"] as? String, !s.isEmpty {
            return s
        }
        guard let msg = obj["message"] as? [String: Any] else { return nil }
        if let s = msg["content"] as? String, !s.isEmpty {
            return s
        }
        if let blocks = msg["content"] as? [[String: Any]] {
            var parts: [String] = []
            for block in blocks {
                if (block["type"] as? String) == "text",
                   let t = block["text"] as? String, !t.isEmpty {
                    parts.append(t)
                }
            }
            if !parts.isEmpty { return parts.joined(separator: "\n\n") }
        }
        return nil
    }

    // MARK: - assistant

    private mutating func ingestAssistant(_ obj: [String: Any], ts: Date?) {
        assistantTurns += 1

        let ts = ts ?? now
        let baseID = (obj["uuid"] as? String)
            ?? (obj["message"] as? [String: Any]).flatMap { $0["id"] as? String }
            ?? "a-\(messages.count)-\(Int(ts.timeIntervalSince1970))"

        // Pull usage from message.usage or top-level usage.
        var inTokens = 0
        var outTokens = 0
        if let msg = obj["message"] as? [String: Any],
           let usage = msg["usage"] as? [String: Any] {
            inTokens = usage["input_tokens"] as? Int ?? 0
            outTokens = usage["output_tokens"] as? Int ?? 0
        } else if let usage = obj["usage"] as? [String: Any] {
            inTokens = usage["input_tokens"] as? Int ?? 0
            outTokens = usage["output_tokens"] as? Int ?? 0
        }
        tokensInput += inTokens
        tokensOutput += outTokens

        // Track most-recent model for Stats.model.
        if let msg = obj["message"] as? [String: Any],
           let m = msg["model"] as? String, !m.isEmpty {
            model = m
        } else if let m = obj["model"] as? String, !m.isEmpty {
            model = m
        }

        // Concatenate text blocks into the assistant markdown body.
        var textParts: [String] = []
        var toolUses: [[String: Any]] = []

        // Flat shape (legacy fixture): {"type":"assistant","content":"..."}
        if let s = obj["content"] as? String, !s.isEmpty {
            textParts.append(s)
        } else if let msg = obj["message"] as? [String: Any] {
            if let s = msg["content"] as? String, !s.isEmpty {
                textParts.append(s)
            } else if let blocks = msg["content"] as? [[String: Any]] {
                for block in blocks {
                    switch block["type"] as? String {
                    case "text":
                        if let t = block["text"] as? String, !t.isEmpty {
                            textParts.append(t)
                        }
                    case "tool_use":
                        toolUses.append(block)
                    default:
                        break
                    }
                }
            }
        }

        let markdown = textParts.joined(separator: "\n\n")
        // Emit the assistant turn FIRST (even with empty markdown) so its
        // number slot in the TOC reflects the event order. Skip only when
        // there is literally nothing to render; no text, no tool calls.
        if !markdown.isEmpty || !toolUses.isEmpty {
            messages.append(.assistant(AssistantTurn(
                id: baseID,
                timestamp: ts,
                markdown: markdown,
                tokensInput: inTokens,
                tokensOutput: outTokens,
                model: model
            )))
        }

        // Then emit each tool_use in order as its own message.
        for (i, use) in toolUses.enumerated() {
            appendToolUse(use, parentID: baseID, index: i, ts: ts)
        }
    }

    // MARK: - tool_use

    private mutating func appendToolUse(
        _ block: [String: Any],
        parentID: String,
        index: Int,
        ts: Date
    ) {
        let name = (block["name"] as? String) ?? "tool"
        let id = (block["id"] as? String) ?? "\(parentID)-use-\(index)"

        let rawInput = block["input"]
        let argsValue = JSONValue.from(rawInput)
        let argsDict: [String: JSONValue]
        if case .object(let d) = argsValue {
            argsDict = d
        } else {
            argsDict = [:]
        }

        toolUseCounts[name, default: 0] += 1
        collectFilesTouched(from: argsDict)

        let call = ToolCall(
            id: id,
            timestamp: ts,
            name: name,
            args: argsDict,
            resultText: nil,
            durationMs: nil
        )
        toolCallIndex[id] = messages.count
        toolCallStartedAt[id] = ts
        messages.append(.toolCall(call))
    }

    // MARK: - tool_result

    private mutating func attachToolResult(block: [String: Any], ts: Date?) {
        guard let useID = block["tool_use_id"] as? String,
              let msgIndex = toolCallIndex[useID],
              case .toolCall(let existing) = messages[msgIndex] else {
            return
        }

        let resultText = extractResultText(block)
        let duration: Int?
        if let startedAt = toolCallStartedAt[useID], let ts {
            let ms = Int((ts.timeIntervalSince(startedAt) * 1000.0).rounded())
            duration = ms >= 0 ? ms : nil
        } else {
            duration = existing.durationMs
        }

        let updated = ToolCall(
            id: existing.id,
            timestamp: existing.timestamp,
            name: existing.name,
            args: existing.args,
            resultText: resultText ?? existing.resultText,
            durationMs: duration
        )
        messages[msgIndex] = .toolCall(updated)
    }

    private func extractResultText(_ block: [String: Any]) -> String? {
        if let s = block["content"] as? String {
            return truncate(s)
        }
        if let blocks = block["content"] as? [[String: Any]] {
            var parts: [String] = []
            for b in blocks {
                if (b["type"] as? String) == "text",
                   let t = b["text"] as? String {
                    parts.append(t)
                }
            }
            if !parts.isEmpty {
                return truncate(parts.joined(separator: "\n"))
            }
        }
        return nil
    }

    private func truncate(_ s: String) -> String {
        guard s.count > TranscriptParser.maxToolResultLength else { return s }
        let keep = s.prefix(TranscriptParser.maxToolResultLength)
        return String(keep) + "\n…[truncated \(s.count - TranscriptParser.maxToolResultLength) bytes]"
    }

    // MARK: - files touched

    private mutating func collectFilesTouched(from args: [String: JSONValue]) {
        // Keys that almost always hold a file path in Claude Code's tool arg
        // schema. We record a path once per tool_use, de-duped by path with
        // an edit-count tally.
        let keys = ["file_path", "path", "filePath", "notebook_path"]
        for key in keys {
            if case .string(let p) = args[key], !p.isEmpty {
                record(path: p)
                return
            }
        }
    }

    private mutating func record(path: String) {
        if let _ = filesTouched[path] {
            filesTouched[path, default: 0] += 1
        } else {
            filesTouched[path] = 1
            filesOrder.append(path)
        }
    }

    // MARK: - Finalize

    mutating func finalize() -> Transcript {
        let created = createdAt ?? now
        let modified = lastModifiedAt ?? created

        let touches = filesOrder.map { Transcript.FileTouch(path: $0, edits: filesTouched[$0] ?? 1) }

        let stats = Transcript.Stats(
            createdAt: created,
            lastModifiedAt: modified,
            userTurns: userTurns,
            assistantTurns: assistantTurns,
            tokensInput: tokensInput,
            tokensOutput: tokensOutput,
            toolUseCounts: toolUseCounts,
            filesTouched: touches,
            model: model
        )

        return Transcript(
            sessionID: sessionID,
            workspaceID: workspaceID,
            messages: messages,
            stats: stats
        )
    }
}
