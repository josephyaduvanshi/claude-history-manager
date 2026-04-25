import XCTest
@testable import Chronicle

final class TranscriptParserTests: XCTestCase {

    // MARK: - Helpers

    private func fixtureURL(_ path: String) -> URL {
        // Transcript-specific fixtures live in `transcript-sessions/` so the
        // workspace-count assertions in SessionsRepositoryTests (which scan
        // `sample-sessions/`) don't need to change when we add new turns
        // + tool_use events just for the transcript parser.
        if path.hasPrefix("-Users-test-tool-app") {
            return Bundle.module.url(
                forResource: "Fixtures/transcript-sessions/\(path)",
                withExtension: nil
            )!
        }
        return Bundle.module.url(
            forResource: "Fixtures/sample-sessions/\(path)",
            withExtension: nil
        )!
    }

    private func tempFile(lines: [String]) throws -> URL {
        // Temp file path keeps the expected UUID stem so SessionID parses.
        let uuid = UUID().uuidString.lowercased()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcript-parser-tests-\(UUID().uuidString)",
                                   isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(uuid).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - 1. Pure user + assistant, no tools

    func test_parse_pureUserAssistant_producesOrderedTurns() throws {
        let url = fixtureURL(
            "-Users-test-flutter-app/11111111-1111-1111-1111-111111111111.jsonl"
        )
        let t = try TranscriptParser().parse(
            url: url,
            workspaceID: "-Users-test-flutter-app"
        )

        XCTAssertEqual(t.messages.count, 4)
        guard case .user(let u1) = t.messages[0] else { return XCTFail("expected user") }
        XCTAssertEqual(u1.markdown, "Add Stripe checkout to subscription flow")
        guard case .assistant(let a1) = t.messages[1] else { return XCTFail("expected assistant") }
        XCTAssertEqual(a1.markdown, "I'll add a Stripe checkout flow.")
        guard case .user = t.messages[2] else { return XCTFail("expected user") }
        guard case .assistant = t.messages[3] else { return XCTFail("expected assistant") }

        XCTAssertEqual(t.stats.userTurns, 2)
        XCTAssertEqual(t.stats.assistantTurns, 2)
        XCTAssertEqual(t.stats.tokensInput, 200)  // 120 + 80
        XCTAssertEqual(t.stats.tokensOutput, 168) // 48 + 120
        XCTAssertTrue(t.stats.toolUseCounts.isEmpty)
        XCTAssertTrue(t.stats.filesTouched.isEmpty)
    }

    // MARK: - 2. Assistant with multiple tool_use blocks

    func test_parse_assistantWithMultipleToolUses_emitsEachAsOrderedToolCall() throws {
        let url = fixtureURL(
            "-Users-test-tool-app/33333333-3333-3333-3333-333333333333.jsonl"
        )
        let t = try TranscriptParser().parse(
            url: url,
            workspaceID: "-Users-test-tool-app"
        )

        // After the first assistant turn, we expect two tool calls in order:
        // Edit then Bash.
        let assistantIdx = t.messages.firstIndex { msg in
            if case .assistant = msg { return true }
            return false
        }
        XCTAssertNotNil(assistantIdx)
        guard let idx = assistantIdx else { return }

        guard case .toolCall(let first) = t.messages[idx + 1] else {
            return XCTFail("expected tool call after assistant")
        }
        XCTAssertEqual(first.name, "Edit")
        guard case .toolCall(let second) = t.messages[idx + 2] else {
            return XCTFail("expected second tool call")
        }
        XCTAssertEqual(second.name, "Bash")
    }

    // MARK: - 3. tool_result attaches to earlier tool_call

    func test_parse_toolResult_attachesToMatchingToolCall() throws {
        let url = fixtureURL(
            "-Users-test-tool-app/33333333-3333-3333-3333-333333333333.jsonl"
        )
        let t = try TranscriptParser().parse(
            url: url,
            workspaceID: "-Users-test-tool-app"
        )

        let editCall = t.messages.compactMap { msg -> ToolCall? in
            if case .toolCall(let c) = msg, c.name == "Edit" { return c }
            return nil
        }.first
        XCTAssertNotNil(editCall)
        XCTAssertEqual(editCall?.resultText, "Edit applied to lib/billing/webhook.dart")
        XCTAssertNotNil(editCall?.durationMs)
        XCTAssertGreaterThanOrEqual(editCall!.durationMs ?? -1, 0)

        let bashCall = t.messages.compactMap { msg -> ToolCall? in
            if case .toolCall(let c) = msg, c.name == "Bash" { return c }
            return nil
        }.first
        XCTAssertEqual(bashCall?.resultText, "All tests passed (42 tests)")
    }

    // MARK: - 4. Harness junk filtered from user turns

    func test_parse_filtersHarnessJunkUserTurns() throws {
        let url = fixtureURL(
            "-Users-test-tool-app/33333333-3333-3333-3333-333333333333.jsonl"
        )
        let t = try TranscriptParser().parse(
            url: url,
            workspaceID: "-Users-test-tool-app"
        )

        // The fixture has 3 user-type events that are NOT tool_result carriers:
        //   "Edit the webhook handler..."
        //   "<system-reminder>ignore</system-reminder>"  — junk, dropped
        //   "ship it"
        let userTurns = t.messages.compactMap { msg -> UserTurn? in
            if case .user(let u) = msg { return u }
            return nil
        }
        XCTAssertEqual(userTurns.count, 2)
        XCTAssertTrue(userTurns.contains { $0.markdown.contains("Edit the webhook") })
        XCTAssertTrue(userTurns.contains { $0.markdown == "ship it" })
        XCTAssertFalse(userTurns.contains { $0.markdown.contains("system-reminder") })
    }

    // MARK: - 5. Empty file returns empty transcript

    func test_parse_emptyFile_returnsEmptyTranscript() throws {
        let url = try tempFile(lines: [])
        let t = try TranscriptParser().parse(url: url, workspaceID: "ws-empty")
        XCTAssertTrue(t.messages.isEmpty)
        XCTAssertEqual(t.stats.userTurns, 0)
        XCTAssertEqual(t.stats.assistantTurns, 0)
        XCTAssertEqual(t.workspaceID, "ws-empty")
    }

    // MARK: - 6. Stats aggregation

    func test_parse_computesToolUseCountsAndFilesTouched() throws {
        let url = fixtureURL(
            "-Users-test-tool-app/33333333-3333-3333-3333-333333333333.jsonl"
        )
        let t = try TranscriptParser().parse(
            url: url,
            workspaceID: "-Users-test-tool-app"
        )

        XCTAssertEqual(t.stats.toolUseCounts["Edit"], 2)
        XCTAssertEqual(t.stats.toolUseCounts["Bash"], 1)

        // Two Edit calls, both on the same file path → one FileTouch with edits=2
        let webhook = t.stats.filesTouched.first { $0.path == "lib/billing/webhook.dart" }
        XCTAssertNotNil(webhook, "expected webhook.dart in filesTouched")
        XCTAssertEqual(webhook?.edits, 2)
        // Only one distinct path was touched via file_path arg.
        XCTAssertEqual(t.stats.filesTouched.count, 1)
    }

    // MARK: - 7. Model extracted from assistant message

    func test_parse_extractsModelFromAssistantMessage() throws {
        let url = fixtureURL(
            "-Users-test-tool-app/33333333-3333-3333-3333-333333333333.jsonl"
        )
        let t = try TranscriptParser().parse(
            url: url,
            workspaceID: "-Users-test-tool-app"
        )
        XCTAssertEqual(t.stats.model, "claude-sonnet-4-6")
    }

    // MARK: - 8. SessionID round-trips through filename

    func test_parse_sessionID_matchesFilename() throws {
        let url = fixtureURL(
            "-Users-test-tool-app/33333333-3333-3333-3333-333333333333.jsonl"
        )
        let t = try TranscriptParser().parse(url: url, workspaceID: "-Users-test-tool-app")
        XCTAssertEqual(t.sessionID.description, "33333333-3333-3333-3333-333333333333")
    }

    // MARK: - 9. Invalid UUID filename throws

    func test_parse_invalidFilename_throws() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tp-bad-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("not-a-uuid.jsonl")
        try? "".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try TranscriptParser().parse(url: url, workspaceID: "ws"))
    }

    // MARK: - 10. Assistant with no text but a tool call is still emitted

    func test_parse_assistantTurnEmitted_evenWhenOnlyToolCalls() throws {
        let uuid = "44444444-4444-4444-4444-444444444444"
        let line = """
        {"type":"assistant","timestamp":"2026-04-22T14:00:00.000Z","uuid":"a-1","message":{"id":"m1","model":"claude-opus","role":"assistant","content":[{"type":"tool_use","id":"tu_99","name":"Read","input":{"file_path":"README.md"}}],"usage":{"input_tokens":10,"output_tokens":0}}}
        """
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tp-only-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(uuid).jsonl")
        try line.write(to: url, atomically: true, encoding: .utf8)

        let t = try TranscriptParser().parse(url: url, workspaceID: "ws-x")
        XCTAssertEqual(t.messages.count, 2)
        guard case .assistant = t.messages[0] else { return XCTFail("expected assistant") }
        guard case .toolCall(let call) = t.messages[1] else { return XCTFail("expected tool call") }
        XCTAssertEqual(call.name, "Read")
        XCTAssertEqual(call.args["file_path"], .string("README.md"))
        XCTAssertEqual(t.stats.toolUseCounts["Read"], 1)
        XCTAssertEqual(t.stats.filesTouched.first?.path, "README.md")
    }

    // MARK: - 11. JSONValue conversion basics

    func test_jsonValue_fromFoundation_preservesStringsAndNumbers() {
        let any: [String: Any] = [
            "file_path": "x.swift",
            "count": 3,
            "flag": true,
            "nested": ["a", "b"],
        ]
        let v = JSONValue.from(any)
        guard case .object(let dict) = v else { return XCTFail("expected object") }
        XCTAssertEqual(dict["file_path"], .string("x.swift"))
        XCTAssertEqual(dict["count"], .number(3))
        XCTAssertEqual(dict["flag"], .bool(true))
        if case .array(let arr) = dict["nested"] {
            XCTAssertEqual(arr, [.string("a"), .string("b")])
        } else {
            XCTFail("expected nested array")
        }
    }

    func test_jsonValue_shortInlineSummary_prefersFilePath() {
        let v = JSONValue.object([
            "file_path": .string("lib/foo.dart"),
            "old_string": .string("x"),
        ])
        XCTAssertEqual(v.shortInlineSummary(), "\"file_path\": \"lib/foo.dart\"")
    }

    /// Bug C — large bash tool_result blobs must be truncated to a fixed
    /// budget AND the parse must complete fast even when the line is huge.
    func test_parse_truncatesLargeToolResults_andRunsFast() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("99999999-9999-9999-9999-999999999999.jsonl")

        // 50KB stdout — well past the 10KB truncation budget.
        let bigPayload = String(repeating: "x", count: 50 * 1024)

        let lines = [
            #"{"type":"user","timestamp":"2026-01-01T00:00:00Z","content":"run grep please"}"#,
            #"{"type":"assistant","timestamp":"2026-01-01T00:00:30Z","message":{"id":"msg-1","model":"claude-opus-4-7","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"grep -r foo ."}}],"usage":{"input_tokens":10,"output_tokens":4}}}"#,
            #"{"type":"user","timestamp":"2026-01-01T00:00:45Z","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"\#(bigPayload)"}]}}"#,
        ]
        try lines.joined(separator: "\n").write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let started = Date()
        let transcript = try TranscriptParser().parse(url: tmp, workspaceID: "x")
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 0.5, "50KB tool_result must parse in well under 500ms")

        // Walk transcript for the tool call and confirm its result is truncated.
        var foundCall: ToolCall?
        for msg in transcript.messages {
            if case .toolCall(let call) = msg, call.id == "toolu_1" {
                foundCall = call
                break
            }
        }
        guard let call = foundCall else {
            XCTFail("expected tool call to be present")
            return
        }
        guard let result = call.resultText else {
            XCTFail("expected resultText to be populated")
            return
        }
        XCTAssertTrue(result.contains("…[truncated"),
                      "result must contain truncation marker")
        XCTAssertLessThan(result.count, TranscriptParser.maxToolResultLength + 80,
                          "truncated result must be near the cap (plus marker text)")
    }
}
