import Foundation

// MARK: - JSONValue

/// A minimal sum type covering the JSON shapes that appear inside a Claude
/// Code tool_use `input` argument. Kept sendable + equatable so transcripts
/// can cross actor boundaries and participate in SwiftUI diffing.
public indirect enum JSONValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    /// Best-effort conversion from a Foundation JSON value (as produced by
    /// `JSONSerialization`). Returns `.null` for unknown / unhandled types.
    public static func from(_ any: Any?) -> JSONValue {
        guard let any = any else { return .null }
        if any is NSNull { return .null }
        if let b = any as? Bool,
           // NSNumber bridges booleans into `Bool`, but also into `Int`/`Double`.
           // CFGetTypeID check keeps real bools distinct from numeric zero/one.
           CFGetTypeID(any as CFTypeRef) == CFBooleanGetTypeID() {
            return .bool(b)
        }
        if let n = any as? NSNumber {
            return .number(n.doubleValue)
        }
        if let s = any as? String { return .string(s) }
        if let arr = any as? [Any] { return .array(arr.map(JSONValue.from)) }
        if let dict = any as? [String: Any] {
            var out: [String: JSONValue] = [:]
            out.reserveCapacity(dict.count)
            for (k, v) in dict { out[k] = JSONValue.from(v) }
            return .object(out)
        }
        return .null
    }

    /// Returns a pretty-printed, stable-key-ordered JSON string suitable for
    /// markdown export. Handles primitives by hand because
    /// `JSONSerialization.data(withJSONObject:)` raises an
    /// `NSInvalidArgumentException` on anything other than a top-level
    /// dictionary or array; and Obj-C exceptions are not catchable from
    /// Swift's `try/catch`, so an unguarded call crashes the app.
    public func prettyJSONString() -> String {
        switch self {
        case .null:
            return "null"
        case .bool(let b):
            return b ? "true" : "false"
        case .number(let n):
            // Drop trailing ".0" on whole numbers to match JSON.stringify.
            return n == n.rounded() && abs(n) < 1e15
                ? String(Int64(n))
                : "\(n)"
        case .string(let s):
            // Escape via JSONSerialization on a 1-element array, then strip
            // the brackets; gets us correct quoting + unicode escapes.
            if let data = try? JSONSerialization.data(withJSONObject: [s], options: []),
               let arr = String(data: data, encoding: .utf8),
               arr.hasPrefix("[") && arr.hasSuffix("]") {
                return String(arr.dropFirst().dropLast())
            }
            return "\"\(s)\""
        case .array, .object:
            let foundation = self.asFoundation()
            guard JSONSerialization.isValidJSONObject(foundation) else {
                return "\(foundation)"
            }
            do {
                let data = try JSONSerialization.data(
                    withJSONObject: foundation,
                    options: [.prettyPrinted, .sortedKeys]
                )
                return String(data: data, encoding: .utf8) ?? ""
            } catch {
                return "\(foundation)"
            }
        }
    }

    /// Short single-line summary for inline display: `"file_path": "x.swift"`
    /// for the first string key, or `—` if nothing usable. Used by the TOC
    /// and the collapsed tool-call header.
    public func shortInlineSummary() -> String {
        if case .object(let dict) = self {
            // Prefer a handful of "name-like" keys.
            for key in ["file_path", "path", "filePath", "command", "pattern", "query", "url"] {
                if case .string(let s) = dict[key] {
                    return "\"\(key)\": \"\(s)\""
                }
            }
            // Fallback to first string value.
            for (k, v) in dict {
                if case .string(let s) = v {
                    return "\"\(k)\": \"\(s)\""
                }
            }
            return "{ \(dict.count) field\(dict.count == 1 ? "" : "s") }"
        }
        if case .string(let s) = self { return s }
        return "—"
    }

    // MARK: - Internals

    private func asFoundation() -> Any {
        switch self {
        case .string(let s): return s
        case .number(let d):
            if d.rounded() == d, abs(d) < Double(Int.max) {
                return NSNumber(value: Int(d))
            }
            return NSNumber(value: d)
        case .bool(let b): return NSNumber(value: b)
        case .null: return NSNull()
        case .array(let arr): return arr.map { $0.asFoundation() }
        case .object(let dict):
            var out: [String: Any] = [:]
            out.reserveCapacity(dict.count)
            for (k, v) in dict { out[k] = v.asFoundation() }
            return out
        }
    }
}

// MARK: - Transcript

/// A fully-parsed view of a single session; user + assistant turns and the
/// tool calls Claude made, in chronological order, plus aggregated stats for
/// the right meta sidebar.
public struct Transcript: Equatable, Sendable {
    public let sessionID: SessionID
    public let workspaceID: String
    public let messages: [TranscriptMessage]
    public let stats: Stats

    public init(
        sessionID: SessionID,
        workspaceID: String,
        messages: [TranscriptMessage],
        stats: Stats
    ) {
        self.sessionID = sessionID
        self.workspaceID = workspaceID
        self.messages = messages
        self.stats = stats
    }

    public struct Stats: Equatable, Sendable {
        public var createdAt: Date
        public var lastModifiedAt: Date
        public var userTurns: Int
        public var assistantTurns: Int
        public var tokensInput: Int
        public var tokensOutput: Int
        public var toolUseCounts: [String: Int]
        public var filesTouched: [FileTouch]
        public var model: String?

        public init(
            createdAt: Date,
            lastModifiedAt: Date,
            userTurns: Int,
            assistantTurns: Int,
            tokensInput: Int,
            tokensOutput: Int,
            toolUseCounts: [String: Int],
            filesTouched: [FileTouch],
            model: String?
        ) {
            self.createdAt = createdAt
            self.lastModifiedAt = lastModifiedAt
            self.userTurns = userTurns
            self.assistantTurns = assistantTurns
            self.tokensInput = tokensInput
            self.tokensOutput = tokensOutput
            self.toolUseCounts = toolUseCounts
            self.filesTouched = filesTouched
            self.model = model
        }

        /// Zero-valued stats, used when a session file exists but is empty
        /// or unparseable. Timestamps collapse to the caller-provided `now`.
        public static func empty(now: Date = Date()) -> Stats {
            Stats(
                createdAt: now,
                lastModifiedAt: now,
                userTurns: 0,
                assistantTurns: 0,
                tokensInput: 0,
                tokensOutput: 0,
                toolUseCounts: [:],
                filesTouched: [],
                model: nil
            )
        }

        public var totalTokens: Int { tokensInput + tokensOutput }
    }

    public struct FileTouch: Equatable, Sendable {
        public let path: String
        public var edits: Int

        public init(path: String, edits: Int) {
            self.path = path
            self.edits = edits
        }
    }

    /// Empty transcript; fallback for empty / missing jsonl files so views
    /// can still render without error state.
    public static func empty(
        sessionID: SessionID,
        workspaceID: String,
        now: Date = Date()
    ) -> Transcript {
        Transcript(
            sessionID: sessionID,
            workspaceID: workspaceID,
            messages: [],
            stats: .empty(now: now)
        )
    }
}

// MARK: - TranscriptMessage

/// One renderable unit in the editorial center column. A single assistant
/// jsonl event may produce an `.assistant` message plus zero or more
/// `.toolCall` entries; the parser emits the tool calls immediately after
/// the assistant turn they live inside.
public enum TranscriptMessage: Equatable, Sendable, Identifiable {
    case user(UserTurn)
    case assistant(AssistantTurn)
    case toolCall(ToolCall)

    public var id: String {
        switch self {
        case .user(let t):      return "u-" + t.id
        case .assistant(let t): return "a-" + t.id
        case .toolCall(let t):  return "t-" + t.id
        }
    }

    public var timestamp: Date {
        switch self {
        case .user(let t):      return t.timestamp
        case .assistant(let t): return t.timestamp
        case .toolCall(let t):  return t.timestamp
        }
    }
}

// MARK: - Turns

public struct UserTurn: Equatable, Sendable {
    public let id: String
    public let timestamp: Date
    /// Concatenated text blocks (newline-separated) with harness-junk filtered.
    /// Already markdown; render directly via `MarkdownUI.Markdown`.
    public let markdown: String

    public init(id: String, timestamp: Date, markdown: String) {
        self.id = id
        self.timestamp = timestamp
        self.markdown = markdown
    }
}

public struct AssistantTurn: Equatable, Sendable {
    public let id: String
    public let timestamp: Date
    public let markdown: String
    public let tokensInput: Int
    public let tokensOutput: Int
    public let model: String?

    public init(
        id: String,
        timestamp: Date,
        markdown: String,
        tokensInput: Int,
        tokensOutput: Int,
        model: String?
    ) {
        self.id = id
        self.timestamp = timestamp
        self.markdown = markdown
        self.tokensInput = tokensInput
        self.tokensOutput = tokensOutput
        self.model = model
    }
}

public struct ToolCall: Equatable, Sendable {
    public let id: String
    public let timestamp: Date
    public let name: String
    public let args: [String: JSONValue]
    public let resultText: String?
    public let durationMs: Int?

    public init(
        id: String,
        timestamp: Date,
        name: String,
        args: [String: JSONValue],
        resultText: String?,
        durationMs: Int?
    ) {
        self.id = id
        self.timestamp = timestamp
        self.name = name
        self.args = args
        self.resultText = resultText
        self.durationMs = durationMs
    }

    /// Shown in the TOC + collapsed tool block header; e.g. the file path
    /// for an Edit, the command for a Bash. Falls back to the JSONValue
    /// summary helper when no obvious field is available.
    public var inlineSummary: String {
        JSONValue.object(args).shortInlineSummary()
    }
}
