import XCTest
@testable import Chronicle

final class JsonlParserTests: XCTestCase {
    private func fixtureURL(_ path: String) -> URL {
        Bundle.module.url(forResource: "Fixtures/sample-sessions/\(path)",
                          withExtension: nil)!
    }

    func test_parse_extractsTitleFromFirstUserMessage() throws {
        let url = fixtureURL("-Users-test-flutter-app/11111111-1111-1111-1111-111111111111.jsonl")
        let m = try JsonlParser().parse(url: url, workspaceID: "-Users-test-flutter-app")
        XCTAssertEqual(m.title, "Add Stripe checkout to subscription flow")
    }

    func test_parse_countsUserAndAssistantMessages() throws {
        let url = fixtureURL("-Users-test-flutter-app/11111111-1111-1111-1111-111111111111.jsonl")
        let m = try JsonlParser().parse(url: url, workspaceID: "-Users-test-flutter-app")
        XCTAssertEqual(m.messageCount, 4)
    }

    func test_parse_sumsTokenUsage() throws {
        let url = fixtureURL("-Users-test-flutter-app/11111111-1111-1111-1111-111111111111.jsonl")
        let m = try JsonlParser().parse(url: url, workspaceID: "-Users-test-flutter-app")
        // 120+48+80+120
        XCTAssertEqual(m.tokenCount, 368)
    }

    func test_parse_extractsCreatedAndLastModified() throws {
        let url = fixtureURL("-Users-test-flutter-app/11111111-1111-1111-1111-111111111111.jsonl")
        let m = try JsonlParser().parse(url: url, workspaceID: "-Users-test-flutter-app")
        let isoCreated = ISO8601DateFormatter().string(from: m.createdAt)
        let isoLast = ISO8601DateFormatter().string(from: m.lastModifiedAt)
        XCTAssertEqual(isoCreated, "2026-04-22T14:03:00Z")
        XCTAssertEqual(isoLast,    "2026-04-22T14:06:00Z")
    }

    func test_parse_extractsSessionIDFromFilename() throws {
        let url = fixtureURL("-Users-test-flutter-app/11111111-1111-1111-1111-111111111111.jsonl")
        let m = try JsonlParser().parse(url: url, workspaceID: "-Users-test-flutter-app")
        XCTAssertEqual(m.sessionID, try SessionID(string: "11111111-1111-1111-1111-111111111111"))
    }

    func test_parse_emptyFile_throws() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID()).jsonl")
        try "".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertThrowsError(try JsonlParser().parse(url: tmp, workspaceID: "x"))
    }

    func test_parse_unknownEventTypes_areIgnored() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("33333333-3333-3333-3333-333333333333.jsonl")
        let lines = [
            #"{"type":"queue-operation","timestamp":"2026-01-01T00:00:00Z","sessionId":"33333333-3333-3333-3333-333333333333"}"#,
            #"{"type":"user","timestamp":"2026-01-01T00:01:00Z","sessionId":"33333333-3333-3333-3333-333333333333","content":"hi"}"#,
        ]
        try lines.joined(separator: "\n").write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let m = try JsonlParser().parse(url: tmp, workspaceID: "x")
        XCTAssertEqual(m.title, "hi")
        XCTAssertEqual(m.messageCount, 1) // queue-operation does not count
    }

    func test_parse_realClaudeCodeFormat_nestedMessageContent() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("44444444-4444-4444-4444-444444444444.jsonl")
        let lines = [
            #"{"type":"permission-mode","permissionMode":"default","sessionId":"44444444-4444-4444-4444-444444444444"}"#,
            #"{"type":"file-history-snapshot","messageId":"x","snapshot":{}}"#,
            #"{"type":"user","message":{"role":"user","content":"build me a search bar"},"timestamp":"2026-04-22T14:03:00Z","sessionId":"44444444-4444-4444-4444-444444444444"}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"OK building."}],"usage":{"input_tokens":50,"output_tokens":120}},"timestamp":"2026-04-22T14:04:00Z","sessionId":"44444444-4444-4444-4444-444444444444"}"#,
        ]
        try lines.joined(separator: "\n").write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let m = try JsonlParser().parse(url: tmp, workspaceID: "x")
        XCTAssertEqual(m.title, "build me a search bar")
        XCTAssertEqual(m.messageCount, 2)
        XCTAssertEqual(m.tokenCount, 170)
    }

    func test_parse_realClaudeCodeFormat_arrayContentBlocks() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("55555555-5555-5555-5555-555555555555.jsonl")
        let lines = [
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"first text block"},{"type":"text","text":"second"}]},"timestamp":"2026-04-22T14:03:00Z","sessionId":"55555555-5555-5555-5555-555555555555"}"#,
        ]
        try lines.joined(separator: "\n").write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let m = try JsonlParser().parse(url: tmp, workspaceID: "x")
        XCTAssertEqual(m.title, "first text block")
    }

    func test_parse_skipsHarnessJunkAndUsesNextRealUserMessage() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("77777777-7777-7777-7777-777777777777.jsonl")
        let lines = [
            // harness-injected pseudo-user messages — must be skipped
            #"{"type":"user","message":{"role":"user","content":"<local-command-caveat>Caveat: The messages below were generated by the user while running local commands.</local-command-caveat>"},"timestamp":"2026-04-22T14:03:00Z"}"#,
            #"{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"},"timestamp":"2026-04-22T14:04:00Z"}"#,
            #"{"type":"user","message":{"role":"user","content":"<local-command-stdout>done</local-command-stdout>"},"timestamp":"2026-04-22T14:05:00Z"}"#,
            // first REAL user message — must become the title
            #"{"type":"user","message":{"role":"user","content":"Actually build me the search bar"},"timestamp":"2026-04-22T14:06:00Z"}"#,
        ]
        try lines.joined(separator: "\n").write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let m = try JsonlParser().parse(url: tmp, workspaceID: "x")
        XCTAssertEqual(m.title, "Actually build me the search bar")
    }

    func test_parse_skipsSystemReminderJunkInsideArrayContent() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("88888888-8888-8888-8888-888888888888.jsonl")
        let lines = [
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"<system-reminder>\nThe task tools haven't been used recently.\n</system-reminder>"}]},"timestamp":"2026-04-22T14:03:00Z"}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"read HANDOFF.md and go"}]},"timestamp":"2026-04-22T14:04:00Z"}"#,
        ]
        try lines.joined(separator: "\n").write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let m = try JsonlParser().parse(url: tmp, workspaceID: "x")
        XCTAssertEqual(m.title, "read HANDOFF.md and go")
    }

    func test_parse_allUserMessagesJunk_fallsBackToNoUserMessage() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("99999999-9999-9999-9999-999999999999.jsonl")
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"<local-command-caveat>x</local-command-caveat>"},"timestamp":"2026-04-22T14:03:00Z"}"#,
            #"{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"},"timestamp":"2026-04-22T14:04:00Z"}"#,
        ]
        try lines.joined(separator: "\n").write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let m = try JsonlParser().parse(url: tmp, workspaceID: "x")
        XCTAssertEqual(m.title, "(no user message)")
    }

    func test_isHarnessJunk_directAPI() {
        XCTAssertTrue(JsonlParser.isHarnessJunk("<local-command-caveat>anything</local-command-caveat>"))
        XCTAssertTrue(JsonlParser.isHarnessJunk("<command-name>/help</command-name>"))
        XCTAssertTrue(JsonlParser.isHarnessJunk("<system-reminder>foo</system-reminder>"))
        XCTAssertTrue(JsonlParser.isHarnessJunk("  <a></a><b></b>  "))
        XCTAssertTrue(JsonlParser.isHarnessJunk(""))
        XCTAssertTrue(JsonlParser.isHarnessJunk("   \n  "))
        XCTAssertFalse(JsonlParser.isHarnessJunk("Build me a search bar"))
        XCTAssertFalse(JsonlParser.isHarnessJunk("read HANDOFF.md and go"))
        XCTAssertFalse(JsonlParser.isHarnessJunk("Why does <foo> appear? explain."))
    }

    func test_parse_sessionWithoutUserMessage_doesNotThrow_usesFallback() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("66666666-6666-6666-6666-666666666666.jsonl")
        let lines = [
            #"{"type":"permission-mode","sessionId":"66666666-6666-6666-6666-666666666666"}"#,
            #"{"type":"attachment","attachment":{},"timestamp":"2026-04-22T14:03:00Z","sessionId":"66666666-6666-6666-6666-666666666666"}"#,
        ]
        try lines.joined(separator: "\n").write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let m = try JsonlParser().parse(url: tmp, workspaceID: "x")
        XCTAssertEqual(m.title, "(no user message)")  // fallback, not throw
    }

    // MARK: - parseWithFlags: git_push + errored

    func test_parseWithFlags_topLevelToolUse_gitPush_setsFlag() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("77777777-7777-7777-7777-777777777777.jsonl")
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"push it"},"timestamp":"2026-04-22T14:03:00Z"}"#,
            #"{"type":"tool_use","input":{"command":"git push origin main"},"timestamp":"2026-04-22T14:04:00Z"}"#,
        ]
        try lines.joined(separator: "\n").write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let (meta, flags) = try JsonlParser().parseWithFlags(url: tmp, workspaceID: "x")
        XCTAssertEqual(meta.title, "push it")
        XCTAssertTrue(flags.contains(JsonlParser.Flag.gitPush))
        XCTAssertFalse(flags.contains(JsonlParser.Flag.errored))
    }

    func test_parseWithFlags_assistantInlineToolUse_gitPush_setsFlag() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("88888888-8888-8888-8888-888888888888.jsonl")
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"deploy"},"timestamp":"2026-04-22T14:03:00Z"}"#,
            #"""
            {"type":"assistant","message":{"role":"assistant","usage":{"input_tokens":10,"output_tokens":20},"content":[{"type":"text","text":"ok"},{"type":"tool_use","name":"Bash","input":{"command":"git  push\toriginmain"}}]},"timestamp":"2026-04-22T14:04:00Z"}
            """#,
        ]
        try lines.joined(separator: "\n").write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let (_, flags) = try JsonlParser().parseWithFlags(url: tmp, workspaceID: "x")
        XCTAssertTrue(flags.contains(JsonlParser.Flag.gitPush))
    }

    func test_parseWithFlags_toolResultWithErrorColon_setsErroredFlag() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("99999999-9999-9999-9999-999999999999.jsonl")
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"run it"},"timestamp":"2026-04-22T14:03:00Z"}"#,
            #"{"type":"tool_result","content":"error: command not found: foo"}"#,
        ]
        try lines.joined(separator: "\n").write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let (_, flags) = try JsonlParser().parseWithFlags(url: tmp, workspaceID: "x")
        XCTAssertTrue(flags.contains(JsonlParser.Flag.errored))
    }

    func test_parseWithFlags_toolResultExitCode_setsErroredFlag() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.jsonl")
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"run tests"},"timestamp":"2026-04-22T14:03:00Z"}"#,
            #"{"type":"tool_result","content":"FAIL tests/foo.ts\n\nExit code: 2"}"#,
        ]
        try lines.joined(separator: "\n").write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let (_, flags) = try JsonlParser().parseWithFlags(url: tmp, workspaceID: "x")
        XCTAssertTrue(flags.contains(JsonlParser.Flag.errored))
    }

    func test_parseWithFlags_userToolResultCarrier_withIsError_setsErroredFlag() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb.jsonl")
        let lines = [
            #"""
            {"type":"user","message":{"role":"user","content":[{"type":"tool_result","is_error":true,"content":"some output"}]},"timestamp":"2026-04-22T14:03:00Z"}
            """#,
            #"{"type":"user","message":{"role":"user","content":"try again"},"timestamp":"2026-04-22T14:04:00Z"}"#,
        ]
        try lines.joined(separator: "\n").write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let (meta, flags) = try JsonlParser().parseWithFlags(url: tmp, workspaceID: "x")
        XCTAssertEqual(meta.title, "try again")  // tool_result carrier skipped
        XCTAssertTrue(flags.contains(JsonlParser.Flag.errored))
    }

    func test_parseWithFlags_benignSession_hasNoFlags() throws {
        let url = fixtureURL("-Users-test-flutter-app/11111111-1111-1111-1111-111111111111.jsonl")
        let (_, flags) = try JsonlParser().parseWithFlags(url: url, workspaceID: "x")
        XCTAssertFalse(flags.contains(JsonlParser.Flag.gitPush))
        XCTAssertFalse(flags.contains(JsonlParser.Flag.errored))
    }

    func test_mentionsGitPush_rejectsGitPushPrefixesOfOtherWords() {
        XCTAssertTrue(JsonlParser.mentionsGitPush("git push"))
        XCTAssertTrue(JsonlParser.mentionsGitPush("  git  push origin"))
        XCTAssertTrue(JsonlParser.mentionsGitPush("GIT PUSH"))
        XCTAssertFalse(JsonlParser.mentionsGitPush("git pushback"))
        XCTAssertFalse(JsonlParser.mentionsGitPush("foogit push"))
        XCTAssertFalse(JsonlParser.mentionsGitPush("git pull"))
    }

    func test_containsErrorSignal_triggersOnClassicPatterns() {
        XCTAssertTrue(JsonlParser.containsErrorSignal("error: no such file"))
        XCTAssertTrue(JsonlParser.containsErrorSignal("Exit code: 9"))
        XCTAssertTrue(JsonlParser.containsErrorSignal("non-zero exit status"))
        XCTAssertTrue(JsonlParser.containsErrorSignal("command failed"))
        XCTAssertFalse(JsonlParser.containsErrorSignal("exit code: 0"))
        XCTAssertFalse(JsonlParser.containsErrorSignal("all green"))
    }

    // MARK: - Workspace metadata extraction (Bug A)

    func test_extractWorkspaceMetadata_pullsCwdFromUserLine() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID()).jsonl")
        let lines = [
            #"{"type":"permission-mode","timestamp":"2026-01-01T00:00:00Z"}"#,
            #"{"type":"user","cwd":"/Users/me/Desktop/PROGRAMMING 2/citadel_password_manager","gitBranch":"main","version":"2.1.91","timestamp":"2026-01-01T00:01:00Z","content":"hi"}"#,
        ]
        try lines.joined(separator: "\n").write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let meta = JsonlParser().extractWorkspaceMetadata(url: tmp)
        XCTAssertEqual(meta?.cwd, "/Users/me/Desktop/PROGRAMMING 2/citadel_password_manager")
        XCTAssertEqual(meta?.gitBranch, "main")
        XCTAssertEqual(meta?.version, "2.1.91")
    }

    func test_extractWorkspaceMetadata_returnsNil_whenNoMatchingFields() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID()).jsonl")
        let lines = [
            #"{"type":"permission-mode","timestamp":"2026-01-01T00:00:00Z"}"#,
            #"{"type":"summary","timestamp":"2026-01-01T00:01:00Z"}"#,
        ]
        try lines.joined(separator: "\n").write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let meta = JsonlParser().extractWorkspaceMetadata(url: tmp)
        XCTAssertNil(meta)
    }

    func test_extractWorkspaceMetadata_caps_at30Lines_byDefault() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID()).jsonl")
        // Cap is 30; put cwd on line 100 — should NOT be picked up.
        var lines: [String] = []
        for _ in 0..<99 {
            lines.append(#"{"type":"permission-mode"}"#)
        }
        lines.append(#"{"type":"user","cwd":"/foo","timestamp":"2026-01-01T00:01:00Z","content":"hi"}"#)
        try lines.joined(separator: "\n").write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let meta = JsonlParser().extractWorkspaceMetadata(url: tmp)
        XCTAssertNil(meta)

        // With a higher line cap it's detectable.
        let metaHi = JsonlParser().extractWorkspaceMetadata(url: tmp, lineCap: 200)
        XCTAssertEqual(metaHi?.cwd, "/foo")
    }

    func test_parseWithFlags_populatesInputAndOutputTokens_separately() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("44444444-4444-4444-4444-444444444444.jsonl")
        let lines = [
            #"{"type":"user","timestamp":"2026-01-01T00:00:00Z","content":"hi"}"#,
            #"{"type":"assistant","timestamp":"2026-01-01T00:00:30Z","message":{"model":"claude-opus-4-7","content":[{"type":"text","text":"hello"}],"usage":{"input_tokens":120,"output_tokens":48}}}"#,
            #"{"type":"assistant","timestamp":"2026-01-01T00:01:00Z","message":{"model":"claude-opus-4-7","content":[{"type":"text","text":"world"}],"usage":{"input_tokens":80,"output_tokens":30}}}"#,
        ]
        try lines.joined(separator: "\n").write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let m = try JsonlParser().parse(url: tmp, workspaceID: "x")
        XCTAssertEqual(m.inputTokens, 200)
        XCTAssertEqual(m.outputTokens, 78)
        XCTAssertEqual(m.tokenCount, 278)
        XCTAssertEqual(m.model, "claude-opus-4-7")
    }
}
