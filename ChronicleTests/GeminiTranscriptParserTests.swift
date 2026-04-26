import XCTest
@testable import Chronicle

/// Validates `GeminiTranscriptParser` produces the right `Transcript.Stats`
/// off the real `~/.gemini/tmp/<project>/chats/session-*.json` shape:
/// tool calls land on a top-level `toolCalls: [...]` array on each
/// assistant message, NOT inside `content[].functionCall` (that was
/// guesswork). The preview pane was reading `—` for both Tools Used
/// and Files Touched on every Gemini session until this was fixed.
final class GeminiTranscriptParserTests: XCTestCase {

    private func loadFixture(_ name: String) throws -> URL {
        guard let url = Bundle.module.url(
            forResource: "Fixtures/Providers/gemini/\(name)",
            withExtension: nil
        ) else {
            XCTFail("Could not locate Gemini fixture \(name)")
            throw NSError(domain: "test", code: 1)
        }
        return url
    }

    // MARK: - Sample fixture (no tools)

    func test_transcript_extractsTokensAndMessageSplitFromSession() throws {
        let url = try loadFixture("sample-session.json")
        let parser = GeminiTranscriptParser()
        let sessionID = try SessionID(string: "0e6a1a77-e6f4-4c30-91f8-0a699b5e51c0")

        let transcript = try parser.parse(
            url: url,
            sessionID: sessionID,
            workspaceID: "auth-module"
        )

        XCTAssertEqual(transcript.stats.userTurns, 2)
        XCTAssertEqual(transcript.stats.assistantTurns, 2)
        XCTAssertEqual(transcript.stats.tokensInput, 1000)
        XCTAssertEqual(transcript.stats.tokensOutput, 170)
        XCTAssertEqual(transcript.stats.model, "gemini-2.5-pro")
        XCTAssertEqual(transcript.messages.count, 4,
                       "Phase 4: parser now populates messages for transcript view (2 user + 2 gemini)")
    }

    // MARK: - Real Gemini wire shape

    /// Real Gemini sessions write tool calls as a top-level
    /// `toolCalls: [{ name, args, ... }]` array on each assistant
    /// message — NOT as `content[].functionCall` blocks. This test
    /// uses a synthetic file shaped exactly like
    /// ~/.gemini/tmp/*/chats/session-*.json and asserts the parser
    /// extracts both Tools Used and Files Touched.
    func test_transcript_extractsToolCallsFromTopLevelToolCallsArray() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-toolcalls-\(UUID().uuidString).json")
        let body = """
        {
          "sessionId": "0e6a1a77-e6f4-4c30-91f8-0a699b5e51c0",
          "projectHash": "abc",
          "startTime": "2026-04-17T12:52:00.000Z",
          "lastUpdated": "2026-04-17T13:15:30.000Z",
          "kind": "main",
          "messages": [
            {
              "id": "m1",
              "timestamp": "2026-04-17T12:52:00.000Z",
              "type": "user",
              "content": [{"text": "review the auth module"}]
            },
            {
              "id": "m2",
              "timestamp": "2026-04-17T12:52:30.000Z",
              "type": "gemini",
              "content": "Reading the files now.",
              "model": "gemini-2.5-pro",
              "tokens": {"input": 200, "output": 50, "cached": 0, "thoughts": 10, "total": 260},
              "toolCalls": [
                {
                  "id": "list_directory_1",
                  "name": "list_directory",
                  "args": { "dir_path": "frontend/src/components/home/" },
                  "status": "success"
                },
                {
                  "id": "read_file_1",
                  "name": "read_file",
                  "args": { "file_path": "/Users/test/repo/src/auth.ts" },
                  "status": "success"
                },
                {
                  "id": "run_shell_1",
                  "name": "run_shell_command",
                  "args": { "command": "rg --files -t ts" },
                  "status": "success"
                }
              ]
            },
            {
              "id": "m3",
              "timestamp": "2026-04-17T13:15:00.000Z",
              "type": "gemini",
              "content": "Patching now.",
              "model": "gemini-2.5-pro",
              "tokens": {"input": 800, "output": 120, "total": 950},
              "toolCalls": [
                {
                  "id": "write_file_1",
                  "name": "write_file",
                  "args": { "file_path": "/Users/test/repo/src/auth.ts", "content": "..." },
                  "status": "success"
                },
                {
                  "id": "read_file_2",
                  "name": "read_file",
                  "args": { "file_path": "/Users/test/repo/src/login.ts" },
                  "status": "success"
                }
              ]
            }
          ]
        }
        """
        try body.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let sessionID = try SessionID(string: "0e6a1a77-e6f4-4c30-91f8-0a699b5e51c0")
        let transcript = try GeminiTranscriptParser().parse(
            url: tmp,
            sessionID: sessionID,
            workspaceID: "auth-module"
        )

        XCTAssertEqual(transcript.stats.userTurns, 1)
        XCTAssertEqual(transcript.stats.assistantTurns, 2)
        XCTAssertEqual(transcript.stats.toolUseCounts["list_directory"], 1)
        XCTAssertEqual(transcript.stats.toolUseCounts["read_file"], 2)
        XCTAssertEqual(transcript.stats.toolUseCounts["run_shell_command"], 1)
        XCTAssertEqual(transcript.stats.toolUseCounts["write_file"], 1)

        let paths = Set(transcript.stats.filesTouched.map(\.path))
        XCTAssertTrue(paths.contains("/Users/test/repo/src/auth.ts"),
                      "read_file/write_file file_path should be in Files Touched")
        XCTAssertTrue(paths.contains("/Users/test/repo/src/login.ts"))
        XCTAssertTrue(paths.contains("frontend/src/components/home/"),
                      "list_directory dir_path should be in Files Touched")

        // The auth.ts path was hit twice (read + write) — its edits count
        // should reflect both. (Sort by edits, descending.)
        let topTouch = transcript.stats.filesTouched.first
        XCTAssertEqual(topTouch?.path, "/Users/test/repo/src/auth.ts")
        XCTAssertEqual(topTouch?.edits, 2)
    }

    // MARK: - Real-data smoke test

    /// Smoke test against an actual session from `~/.gemini/tmp`.
    /// Skipped on machines without a Gemini history; otherwise asserts
    /// non-empty Tools Used (Files Touched is best-effort because some
    /// real sessions are pure run_shell_command and have no path
    /// arguments).
    ///
    /// Prefers a session that also includes `write_file` (so Files
    /// Touched is guaranteed non-empty) and falls back to any session
    /// with `toolCalls`.
    func test_transcript_realGeminiFileProducesNonBlankStats() throws {
        let fm = FileManager.default
        let geminiRoot = fm.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/tmp")
        guard fm.fileExists(atPath: geminiRoot.path) else {
            throw XCTSkip("No Gemini sessions directory present; skipping real-data smoke test")
        }
        let candidate: URL
        if let withWrite = Self.findSession(under: geminiRoot, containing: "\"write_file\"") {
            candidate = withWrite
        } else if let withTools = Self.findSession(under: geminiRoot, containing: "\"toolCalls\"") {
            candidate = withTools
        } else {
            throw XCTSkip("No Gemini sessions with toolCalls found; skipping")
        }

        let parser = GeminiTranscriptParser()
        let sessionID = try SessionID(string: "0e6a1a77-e6f4-4c30-91f8-0a699b5e51c0")
        let transcript = try parser.parse(
            url: candidate,
            sessionID: sessionID,
            workspaceID: candidate.path
        )

        XCTAssertFalse(transcript.stats.toolUseCounts.isEmpty,
                       "Real Gemini session \(candidate.lastPathComponent) must produce non-empty Tools Used")

        let toolsList = transcript.stats.toolUseCounts
            .map { "\($0.key)×\($0.value)" }
            .sorted()
            .joined(separator: ", ")
        let pathList = transcript.stats.filesTouched.prefix(8).map(\.path).joined(separator: ", ")
        print("[real Gemini] \(candidate.path)")
        print("[real Gemini] tools=[\(toolsList)]")
        print("[real Gemini] files=[\(pathList)]")
    }

    /// Scan `root` recursively for the first `session-*.json` whose
    /// content includes `needle`. We don't parse the JSON here — a
    /// string contains check on a small prefix is enough to pick a
    /// candidate.
    static func findSession(under root: URL, containing needle: String) -> URL? {
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in walker {
            guard url.lastPathComponent.hasPrefix("session-"),
                  url.pathExtension == "json" else { continue }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let text = String(
                    data: data.prefix(1024 * 1024),
                    encoding: .utf8
                  ) else { continue }
            if text.contains(needle) {
                return url
            }
        }
        return nil
    }

    // MARK: - Empty / malformed file

    func test_transcript_emptyFileReturnsEmptyStats() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-empty-\(UUID().uuidString).json")
        try "".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let sessionID = try SessionID(string: "11111111-1111-4111-8111-111111111111")
        let transcript = try GeminiTranscriptParser().parse(
            url: tmp,
            sessionID: sessionID,
            workspaceID: "/x"
        )
        XCTAssertEqual(transcript.stats.userTurns, 0)
        XCTAssertEqual(transcript.stats.assistantTurns, 0)
        XCTAssertEqual(transcript.stats.totalTokens, 0)
    }

    // MARK: - Message body extraction (Phase 4)

    func test_geminiTranscript_populatesUserAndAssistantMessages() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemini-msg-test-\(UUID().uuidString).json")
        let json: [String: Any] = [
            "sessionId": "0e6a1a77-1234-5678-90ab-cdef12345678",
            "startTime": "2026-04-25T12:00:00Z",
            "lastUpdated": "2026-04-25T12:00:10Z",
            "messages": [
                ["type": "user", "content": "hello gemini", "timestamp": "2026-04-25T12:00:01Z"],
                ["type": "gemini", "content": [["text": "hi back"]],
                 "timestamp": "2026-04-25T12:00:02Z",
                 "model": "gemini-2.5-pro",
                 "tokens": ["input": 5, "output": 3]]
            ]
        ]
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let parser = GeminiTranscriptParser()
        let sid = try SessionID(string: "0e6a1a77-1234-5678-90ab-cdef12345678")
        let transcript = try parser.parse(url: url, sessionID: sid, workspaceID: "gemini:test")

        XCTAssertEqual(transcript.messages.count, 2)
        guard case .user(let u) = transcript.messages.first else {
            XCTFail("First message must be a user turn"); return
        }
        XCTAssertEqual(u.markdown, "hello gemini")
        guard case .assistant(let a) = transcript.messages.last else {
            XCTFail("Last message must be an assistant turn"); return
        }
        XCTAssertEqual(a.markdown, "hi back")
    }

    // MARK: - Legacy functionCall back-compat

    func test_transcript_handlesLegacyContentFunctionCallShape() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-legacy-fc-\(UUID().uuidString).json")
        let body = """
        {
          "sessionId": "22222222-2222-4222-8222-222222222222",
          "projectHash": "x",
          "startTime": "2026-04-17T00:00:00.000Z",
          "lastUpdated": "2026-04-17T00:00:00.000Z",
          "kind": "main",
          "messages": [
            {"id":"m1","timestamp":"2026-04-17T00:00:00.000Z","type":"user","content":[{"text":"x"}]},
            {"id":"m2","timestamp":"2026-04-17T00:00:01.000Z","type":"gemini","model":"gemini-2.5-pro","tokens":{"input":1,"output":2},"content":[
              {"functionCall":{"name":"read_file","args":{"file_path":"/legacy/file.ts"}}}
            ]}
          ]
        }
        """
        try body.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let sessionID = try SessionID(string: "22222222-2222-4222-8222-222222222222")
        let transcript = try GeminiTranscriptParser().parse(
            url: tmp,
            sessionID: sessionID,
            workspaceID: "/x"
        )
        XCTAssertEqual(transcript.stats.toolUseCounts["read_file"], 1,
                       "Legacy content[].functionCall path still counted for back-compat")
        XCTAssertTrue(transcript.stats.filesTouched.contains { $0.path == "/legacy/file.ts" })
    }

    // MARK: - Tool-call interleaving (Phase 4 follow-up)

    func test_geminiTranscript_emitsToolCallsAfterAssistantMessage() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemini-tc-test-\(UUID().uuidString).json")
        let json: [String: Any] = [
            "sessionId": "0e6a1a77-1234-5678-90ab-cdef12345678",
            "messages": [
                ["type": "user", "content": "what's in /tmp", "timestamp": "2026-04-25T12:00:01Z"],
                ["type": "gemini", "content": [["text": "Listing now"]],
                 "timestamp": "2026-04-25T12:00:02Z",
                 "model": "gemini-2.5-pro",
                 "tokens": ["input": 5, "output": 3],
                 "toolCalls": [
                     ["name": "list_directory",
                      "args": ["dir_path": "/tmp"],
                      "result": "foo.txt\nbar.txt"]
                 ]]
            ]
        ]
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let parser = GeminiTranscriptParser()
        let sid = try SessionID(string: "0e6a1a77-1234-5678-90ab-cdef12345678")
        let transcript = try parser.parse(url: url, sessionID: sid, workspaceID: "gemini:test")

        XCTAssertEqual(transcript.messages.count, 3,
            "user, assistant, tool call (after assistant)")
        guard case .user = transcript.messages[0],
              case .assistant = transcript.messages[1],
              case .toolCall(let tc) = transcript.messages[2] else {
            XCTFail("Order: user, assistant, toolCall. Got: \(transcript.messages.map(\.id))")
            return
        }
        XCTAssertEqual(tc.name, "list_directory")
        XCTAssertEqual(tc.resultText, "foo.txt\nbar.txt")
        if case .string(let p) = tc.args["dir_path"] {
            XCTAssertEqual(p, "/tmp")
        } else {
            XCTFail("toolCall.args[dir_path] should be .string")
        }
    }
}
