import Foundation

/// Parses one Gemini CLI session file. Unlike Claude / Codex, Gemini
/// stores each session as a single JSON object (not JSONL) at
/// `~/.gemini/tmp/<project_dir>/chats/session-<ts>-<uuid-prefix>.json`.
///
/// The shape:
///
///   ```json
///   {
///     "sessionId": "<uuid>",
///     "projectHash": "<sha256 or project name>",
///     "startTime": "...",
///     "lastUpdated": "...",
///     "kind": "main" | "subagent",
///     "messages": [
///       { "type": "user",   "timestamp": "...", "content": "..." | [{"text": "..."}] },
///       { "type": "gemini", "timestamp": "...", "content": "...",
///         "tokens": {"input": N, "output": N, "cached": N, "thoughts": N, "total": N},
///         "model": "gemini-2.5-pro" }
///     ]
///   }
///   ```
///
/// Two notable holes vs Claude / Codex:
///   - **No cwd field.** The provider reverse-looks-up the project dir
///     name in `~/.gemini/projects.json` to recover one. When the dir
///     is hash-named (newer Gemini builds) the reverse lookup misses
///     and cwd is left nil; the UI shows "—" for those sessions.
///   - **No git branch.** Same UI handling.
///
/// Atomic-write hazard: Gemini uses `fs.appendFileSync` so a partial
/// JSON document can land on disk mid-update. The `parse(...)` entry
/// retries up to 3× with 100 ms backoff before giving up — by then
/// the writer has either finished or crashed, and the FSEvents
/// debounce will redrive the next time the file changes.
public struct GeminiParser: SessionParser {
    public let maxRetries: Int
    public let retryDelay: TimeInterval

    public init(maxRetries: Int = 3, retryDelay: TimeInterval = 0.1) {
        self.maxRetries = maxRetries
        self.retryDelay = retryDelay
    }

    public enum ParseError: Error {
        case decodeFailedAfterRetries(URL)
        case filtered(reason: String)   // subagent or no real messages
        case missingSessionID(URL)
    }

    public func parse(url: URL, workspaceID: String) throws -> (SessionMetadata, Set<String>) {
        var lastError: Error?
        for attempt in 0..<maxRetries {
            do {
                return try parseOnce(url: url, workspaceID: workspaceID)
            } catch let err as ParseError {
                // .filtered is permanent — no point retrying.
                if case .filtered = err { throw err }
                lastError = err
            } catch {
                lastError = error
            }
            if attempt + 1 < maxRetries {
                Thread.sleep(forTimeInterval: retryDelay)
            }
        }
        throw lastError ?? ParseError.decodeFailedAfterRetries(url)
    }

    // MARK: - Single-attempt parse

    private func parseOnce(url: URL, workspaceID: String) throws -> (SessionMetadata, Set<String>) {
        let data = try Data(contentsOf: url)
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.decodeFailedAfterRetries(url)
        }

        // Filter subagent sessions — they're tool-call internals, not
        // user-facing conversations.
        if let kind = raw["kind"] as? String, kind == "subagent" {
            throw ParseError.filtered(reason: "subagent")
        }

        guard let sessionIDString = raw["sessionId"] as? String else {
            throw ParseError.missingSessionID(url)
        }

        let messagesRaw = (raw["messages"] as? [[String: Any]]) ?? []

        var firstUserText: String?
        var lastModel: String?
        var messageCount = 0
        var inputTokens = 0
        var outputTokens = 0
        var totalTokens = 0
        var hasUserOrGeminiMessage = false

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()
        isoNoFrac.formatOptions = [.withInternetDateTime]

        for msg in messagesRaw {
            let type = msg["type"] as? String ?? ""
            switch type {
            case "user", "gemini":
                hasUserOrGeminiMessage = true
                messageCount += 1

                if type == "user", firstUserText == nil,
                   let text = Self.extractMessageText(msg["content"]),
                   !Self.isSlashCommand(text) {
                    firstUserText = String(text.prefix(200))
                }

                if type == "gemini" {
                    if let m = msg["model"] as? String, !m.isEmpty {
                        lastModel = m
                    }
                    if let tokens = msg["tokens"] as? [String: Any] {
                        inputTokens += tokens["input"] as? Int ?? 0
                        outputTokens += tokens["output"] as? Int ?? 0
                        totalTokens += tokens["total"] as? Int ?? 0
                    }
                }

            default:
                // info / error / warning — skipped, but doesn't disqualify
                // the session unless ALL messages were of these types.
                break
            }
        }

        // Filter empty sessions: nothing the user would recognize as a
        // real conversation. Common when Gemini logs an error before
        // any prompt was sent.
        guard hasUserOrGeminiMessage else {
            throw ParseError.filtered(reason: "no user/gemini messages")
        }

        let canonical = try SessionID(string: sessionIDString)

        let startTime = (raw["startTime"] as? String).flatMap {
            iso.date(from: $0) ?? isoNoFrac.date(from: $0)
        } ?? Date()
        let lastUpdated = (raw["lastUpdated"] as? String).flatMap {
            iso.date(from: $0) ?? isoNoFrac.date(from: $0)
        } ?? startTime

        let title: String = raw["summary"] as? String
            ?? firstUserText
            ?? "(no title)"

        let metadata = SessionMetadata(
            sessionID: canonical,
            workspaceID: workspaceID,
            title: title,
            createdAt: startTime,
            lastModifiedAt: lastUpdated,
            messageCount: messageCount,
            tokenCount: totalTokens > 0 ? totalTokens : (inputTokens + outputTokens),
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            model: lastModel,
            isLive: false
        )
        return (metadata, [])
    }

    // MARK: - Helpers

    /// Gemini's `content` is either a `String` (assistant turns) or an
    /// array of content blocks (`[{"text": "..."}]` for user turns).
    /// Returns the first non-empty text it finds.
    static func extractMessageText(_ content: Any?) -> String? {
        if let s = content as? String, !s.isEmpty { return s }
        if let blocks = content as? [[String: Any]] {
            for block in blocks {
                if let t = block["text"] as? String, !t.isEmpty {
                    return t
                }
            }
        }
        return nil
    }

    /// Gemini users sometimes start sessions with `/help`, `/clear`,
    /// `/memory show`, etc. Those make poor titles. Skip them as
    /// title-source candidates and fall through to the next user turn.
    static func isSlashCommand(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespaces).hasPrefix("/")
    }
}
