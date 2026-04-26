import Foundation

/// Parses one Codex CLI rollout file into the canonical `SessionMetadata`
/// shape Chronicle uses for every provider. Codex stores sessions as JSONL
/// at `~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl`.
///
/// Each line is one event with a `type` discriminator. The shapes we care
/// about:
///
///   - `session_meta` (always the first line): carries `id`, `cwd`,
///     `git.branch`, `git.commit_hash`, `originator`, `cli_version`,
///     `model_provider`, `base_instructions`.
///   - `response_item` with `payload.type == "message"`: a user / assistant
///     / developer / system turn. We count `user` and `assistant` for
///     `messageCount`.
///   - `event_msg` with `payload.type == "token_count"`: cumulative usage
///     for the whole session in `info.total_token_usage`. Each event
///     supersedes the previous, so the last one we see wins.
///   - `event_msg` with `payload.type == "thread_name_updated"`: the
///     session title. Also mirrored in `~/.codex/session_index.jsonl`,
///     but reading it inline lets the parser stand alone.
public struct CodexParser: SessionParser {
    public init() {}

    public enum ParseError: Error {
        case emptyFile
        case missingSessionID(URL)
        case malformed(URL)
    }

    public func parse(url: URL, workspaceID: String) throws -> (SessionMetadata, Set<String>) {
        let raw = try String(contentsOf: url, encoding: .utf8)
        let lines = raw.split(whereSeparator: \.isNewline)
        guard !lines.isEmpty else { throw ParseError.emptyFile }

        var sessionID: String?
        var firstTimestamp: Date?
        var lastTimestamp: Date?
        var messageCount = 0
        var firstUserText: String?
        var threadName: String?
        var totalInputTokens = 0
        var totalOutputTokens = 0
        var totalTokens = 0
        var modelProvider: String?

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()
        isoNoFrac.formatOptions = [.withInternetDateTime]

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                // Codex writes are atomic per-line, but a Process being
                // killed mid-write could land a partial trailing line.
                // Skip silently — the SessionsWatcher will redrive on the
                // next FSEvents fire.
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
                if let pid = payload?["id"] as? String { sessionID = pid }
                if let mp = payload?["model_provider"] as? String { modelProvider = mp }

            case "turn_context":
                // Newer Codex (CLI ~0.120+) emits a turn_context event whose
                // top-level `model` field carries the real model name (e.g.,
                // "gpt-5.4"). Prefer this over session_meta.model_provider
                // (which is just the API host, "openai").
                if let m = obj["model"] as? String, !m.isEmpty {
                    modelProvider = m
                }

            case "response_item":
                if let p = payload,
                   (p["type"] as? String) == "message",
                   let role = p["role"] as? String {
                    if role == "user" || role == "assistant" {
                        messageCount += 1
                    }
                    if firstUserText == nil,
                       role == "user",
                       let text = Self.extractFirstText(p["content"] as? [[String: Any]]),
                       !Self.isEnvironmentContextStub(text) {
                        firstUserText = String(text.prefix(200))
                    }
                }

            case "event_msg":
                guard let p = payload, let evType = p["type"] as? String else { continue }
                switch evType {
                case "thread_name_updated":
                    if let n = p["thread_name"] as? String, !n.isEmpty {
                        threadName = n
                    }
                case "token_count":
                    // `info.total_token_usage` is cumulative — last writer wins.
                    if let info = p["info"] as? [String: Any],
                       let total = info["total_token_usage"] as? [String: Any] {
                        totalInputTokens = total["input_tokens"] as? Int ?? totalInputTokens
                        totalOutputTokens = total["output_tokens"] as? Int ?? totalOutputTokens
                        totalTokens = total["total_tokens"] as? Int ?? totalTokens
                    }
                default:
                    break
                }

            default:
                break
            }
        }

        // Session id falls back to the UUID embedded in the filename
        // (`rollout-<ts>-<uuid>.jsonl`) if `session_meta` was missing.
        let resolvedID: String
        if let sid = sessionID, !sid.isEmpty {
            resolvedID = sid
        } else if let extracted = Self.extractSessionUUIDFromFilename(url) {
            resolvedID = extracted
        } else {
            throw ParseError.missingSessionID(url)
        }

        let title: String = threadName
            ?? firstUserText
            ?? "(no title)"
        let created = firstTimestamp ?? Date()
        let modified = lastTimestamp ?? created

        let canonical = try SessionID(string: resolvedID)
        let metadata = SessionMetadata(
            sessionID: canonical,
            workspaceID: workspaceID,
            title: title,
            createdAt: created,
            lastModifiedAt: modified,
            messageCount: messageCount,
            tokenCount: totalTokens > 0 ? totalTokens : (totalInputTokens + totalOutputTokens),
            inputTokens: totalInputTokens,
            outputTokens: totalOutputTokens,
            // Codex sessions don't pin a single model name; the user may
            // switch mid-session. Surface the provider instead so Stats
            // can group by `openai`, `anthropic`, etc. when we ever
            // multi-host Codex.
            model: modelProvider,
            isLive: false
        )
        // Codex doesn't currently surface git_push / errored signals in a
        // form Chronicle can parse cheaply — leaving flags empty for now.
        return (metadata, [])
    }

    /// Convenience: extract just the cwd from the first `session_meta`
    /// line so the indexer can bucket sessions into workspaces without
    /// parsing the whole file. Reads only the first 32 KB.
    public func extractMetadata(url: URL) -> Metadata? {
        let budget = 32_768
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: budget), !data.isEmpty,
              let raw = String(data: data, encoding: .utf8) else { return nil }
        for line in raw.split(whereSeparator: \.isNewline).prefix(5) {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  (obj["type"] as? String) == "session_meta",
                  let payload = obj["payload"] as? [String: Any] else {
                continue
            }
            let cwd = payload["cwd"] as? String
            let git = payload["git"] as? [String: Any]
            return Metadata(
                cwd: cwd,
                gitBranch: git?["branch"] as? String,
                gitCommitHash: git?["commit_hash"] as? String,
                cliVersion: payload["cli_version"] as? String,
                originator: payload["originator"] as? String,
                modelProvider: payload["model_provider"] as? String
            )
        }
        return nil
    }

    public struct Metadata: Equatable, Sendable {
        public let cwd: String?
        public let gitBranch: String?
        public let gitCommitHash: String?
        public let cliVersion: String?
        public let originator: String?
        public let modelProvider: String?
    }

    // MARK: - Helpers

    /// Pulls the trailing UUID out of a Codex rollout filename:
    ///     rollout-2026-04-24T13-09-10-019dbf9b-c76b-7421-91aa-7a82b8705487.jsonl
    /// The UUID is always the last 5 dash-separated groups of the stem.
    static func extractSessionUUIDFromFilename(_ url: URL) -> String? {
        let stem = url.deletingPathExtension().lastPathComponent
        let parts = stem.split(separator: "-")
        guard parts.count >= 5 else { return nil }
        let candidate = parts.suffix(5).joined(separator: "-")
        return UUID(uuidString: candidate) != nil ? candidate : nil
    }

    /// First non-empty `text` block in a Codex response_item content
    /// array. Codex labels its inputs `input_text` and its assistant
    /// outputs `output_text`; we accept either.
    static func extractFirstText(_ blocks: [[String: Any]]?) -> String? {
        guard let blocks else { return nil }
        for block in blocks {
            guard let t = block["type"] as? String,
                  t == "input_text" || t == "output_text" || t == "text" else {
                continue
            }
            if let s = block["text"] as? String, !s.isEmpty {
                return s
            }
        }
        return nil
    }

    /// Codex prefixes every session with an `<environment_context>` block.
    /// Filter that out so it never surfaces as the title.
    static func isEnvironmentContextStub(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("<environment_context>")
            || trimmed.hasPrefix("<permissions instructions>")
            || trimmed.hasPrefix("<system-reminder>")
    }
}
