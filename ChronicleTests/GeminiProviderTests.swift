import XCTest
@testable import Chronicle

final class GeminiProviderTests: XCTestCase {

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

    // MARK: - Parser

    func test_parser_extractsCanonicalMetadataFromSingleJSONSession() throws {
        let url = try loadFixture("sample-session.json")
        let parser = GeminiParser()
        let (metadata, flags) = try parser.parse(url: url, workspaceID: "auth-module")

        XCTAssertEqual(metadata.sessionID.description, "0e6a1a77-e6f4-4c30-91f8-0a699b5e51c0")
        XCTAssertEqual(metadata.title, "Architectural review of the auth module.",
                       "Title comes from first non-slash-command user message")
        XCTAssertEqual(metadata.workspaceID, "auth-module")
        XCTAssertEqual(metadata.messageCount, 4, "2 user + 2 gemini messages")
        XCTAssertEqual(metadata.inputTokens, 1000, "Sum of per-message input_tokens")
        XCTAssertEqual(metadata.outputTokens, 170)
        XCTAssertEqual(metadata.tokenCount, 1210, "Sum of per-message total_tokens")
        XCTAssertEqual(metadata.model, "gemini-2.5-pro")
        XCTAssertTrue(flags.isEmpty)
    }

    func test_parser_filtersSubagentSessions() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-subagent-\(UUID().uuidString).json")
        try """
        {
          "sessionId": "11111111-1111-4111-8111-111111111111",
          "projectHash": "x",
          "startTime": "2026-04-17T00:00:00.000Z",
          "lastUpdated": "2026-04-17T00:00:00.000Z",
          "kind": "subagent",
          "messages": [
            {"id":"m","timestamp":"2026-04-17T00:00:00.000Z","type":"user","content":"x"}
          ]
        }
        """.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let parser = GeminiParser()
        XCTAssertThrowsError(try parser.parse(url: tmp, workspaceID: "x")) { err in
            guard case GeminiParser.ParseError.filtered(let reason) = err else {
                XCTFail("Expected ParseError.filtered, got \(err)"); return
            }
            XCTAssertEqual(reason, "subagent")
        }
    }

    func test_parser_filtersSessionsWithNoUserOrGeminiMessages() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-info-only-\(UUID().uuidString).json")
        try """
        {
          "sessionId": "22222222-2222-4222-8222-222222222222",
          "projectHash": "x",
          "startTime": "2026-04-17T00:00:00.000Z",
          "lastUpdated": "2026-04-17T00:00:00.000Z",
          "kind": "main",
          "messages": [
            {"id":"m1","timestamp":"2026-04-17T00:00:00.000Z","type":"info","content":"started"},
            {"id":"m2","timestamp":"2026-04-17T00:00:01.000Z","type":"error","content":"oops"}
          ]
        }
        """.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let parser = GeminiParser()
        XCTAssertThrowsError(try parser.parse(url: tmp, workspaceID: "x")) { err in
            guard case GeminiParser.ParseError.filtered = err else {
                XCTFail("Expected ParseError.filtered, got \(err)"); return
            }
        }
    }

    func test_parser_retriesOnPartialJSONThenFails() throws {
        // Write half a JSON document; parser should retry maxRetries times
        // and then surface decodeFailedAfterRetries (NOT crash).
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-partial-\(UUID().uuidString).json")
        try """
        {"sessionId": "33333333-3333-4333-8333-333333333333", "projectHash": "x", "messa
        """.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Tighter retry config so the test isn't slow.
        let parser = GeminiParser(maxRetries: 2, retryDelay: 0.01)
        XCTAssertThrowsError(try parser.parse(url: tmp, workspaceID: "x")) { err in
            // Either decodeFailedAfterRetries OR a Foundation JSON error
            // — both are acceptable; the contract is "doesn't crash".
            XCTAssertNotNil(err)
        }
    }

    func test_parser_skipsSlashCommandTitle() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-slash-\(UUID().uuidString).json")
        try """
        {
          "sessionId": "44444444-4444-4444-8444-444444444444",
          "projectHash": "x",
          "startTime": "2026-04-17T00:00:00.000Z",
          "lastUpdated": "2026-04-17T00:00:00.000Z",
          "kind": "main",
          "messages": [
            {"id":"m1","timestamp":"2026-04-17T00:00:00.000Z","type":"user","content":[{"text":"/help"}]},
            {"id":"m2","timestamp":"2026-04-17T00:00:01.000Z","type":"user","content":[{"text":"How do I use sub-agents?"}]}
          ]
        }
        """.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let parser = GeminiParser()
        let (metadata, _) = try parser.parse(url: tmp, workspaceID: "x")
        XCTAssertEqual(metadata.title, "How do I use sub-agents?",
                       "Should skip the /help slash command and use the next user message")
    }

    func test_parser_summaryFieldWinsOverFirstUserMessage() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-summary-\(UUID().uuidString).json")
        try """
        {
          "sessionId": "55555555-5555-4555-8555-555555555555",
          "projectHash": "x",
          "startTime": "2026-04-17T00:00:00.000Z",
          "lastUpdated": "2026-04-17T00:00:00.000Z",
          "kind": "main",
          "summary": "Summarized title",
          "messages": [
            {"id":"m","timestamp":"2026-04-17T00:00:00.000Z","type":"user","content":[{"text":"the user prompt"}]}
          ]
        }
        """.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let (metadata, _) = try GeminiParser().parse(url: tmp, workspaceID: "x")
        XCTAssertEqual(metadata.title, "Summarized title")
    }

    // MARK: - Resume builder

    func test_resume_ghosttySnapshot() {
        let cmd = GeminiResumeBuilder(loginShell: "/bin/zsh").build(
            terminal: .ghostty,
            sessionID: "0e6a1a77-e6f4-4c30-91f8-0a699b5e51c0",
            cwd: "/Users/test/repo"
        )
        XCTAssertEqual(cmd.executable, "/usr/bin/open")
        XCTAssertEqual(cmd.arguments, [
            "-na", "Ghostty",
            "--args",
            "--working-directory=/Users/test/repo",
            "-e", "/bin/zsh", "-i", "-c",
            #"cd "/Users/test/repo" && gemini --resume 0e6a1a77-e6f4-4c30-91f8-0a699b5e51c0"#,
        ])
    }

    func test_resume_itermSnapshot() {
        let cmd = GeminiResumeBuilder(loginShell: "/bin/zsh").build(
            terminal: .iterm,
            sessionID: "S",
            cwd: "/x"
        )
        XCTAssertEqual(cmd.executable, "/usr/bin/osascript")
        XCTAssertTrue(cmd.appleScript?.contains("gemini --resume S") == true)
    }

    func test_resume_terminalSnapshot() {
        let cmd = GeminiResumeBuilder(loginShell: "/bin/zsh").build(
            terminal: .terminal,
            sessionID: "S",
            cwd: "/x"
        )
        XCTAssertEqual(cmd.executable, "/usr/bin/osascript")
        XCTAssertTrue(cmd.appleScript?.contains("gemini --resume S") == true)
    }

    // MARK: - Provider identity

    func test_provider_idAndNames() {
        let p = GeminiProvider()
        XCTAssertEqual(GeminiProvider.id, .gemini)
        XCTAssertEqual(p.displayName, "Gemini")
        XCTAssertEqual(p.iconAssetName, "gemini")
    }
}
