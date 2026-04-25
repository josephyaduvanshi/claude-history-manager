import XCTest
@testable import Chronicle

/// Validates `CodexTranscriptParser` produces the right `Transcript.Stats`
/// off a real-shaped rollout. Used by the preview pane to populate
/// Files Touched / Tools Used / Messages split / token breakdown for
/// Codex sessions.
final class CodexTranscriptParserTests: XCTestCase {

    private func loadFixture(_ name: String) throws -> URL {
        guard let url = Bundle.module.url(
            forResource: "Fixtures/Providers/codex/\(name)",
            withExtension: nil
        ) else {
            XCTFail("Could not locate Codex fixture \(name) in test bundle")
            throw NSError(domain: "test", code: 1)
        }
        return url
    }

    // MARK: - Sample fixture (no tools)

    func test_transcript_extractsTokensAndMessageSplitFromRollout() throws {
        let url = try loadFixture("sample-session.jsonl")
        let sessionID = try SessionID(string: "019dbf9b-c76b-7421-91aa-7a82b8705487")
        let parser = CodexTranscriptParser()

        let transcript = try parser.parse(
            url: url,
            sessionID: sessionID,
            workspaceID: "/Users/test/repo"
        )

        // Stats — the message split should match the parser's existing
        // metadata extraction. Two response_item messages with role=user
        // (env_context stub + a real prompt) and two with role=assistant.
        XCTAssertEqual(transcript.stats.userTurns, 2,
                       "Counts every response_item message with role=user")
        XCTAssertEqual(transcript.stats.assistantTurns, 2,
                       "Counts every response_item message with role=assistant")

        // Tokens — last token_count event wins (cumulative).
        XCTAssertEqual(transcript.stats.tokensInput, 2500)
        XCTAssertEqual(transcript.stats.tokensOutput, 300)
        XCTAssertEqual(transcript.stats.totalTokens, 2800)

        // Messages array stays empty — preview pane only consumes Stats.
        XCTAssertTrue(transcript.messages.isEmpty,
                      "Codex transcript parser populates Stats only, not message list")

        // Sample fixture has no tool calls, so Tools Used / Files Touched empty.
        XCTAssertTrue(transcript.stats.toolUseCounts.isEmpty)
        XCTAssertTrue(transcript.stats.filesTouched.isEmpty)
    }

    // MARK: - Synthetic fixture with tools

    func test_transcript_extractsToolUseCountsAndApplyPatchPaths() throws {
        // Build a rollout in memory that includes a couple of function_call
        // events, including an apply_patch with the standard heredoc body.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rollout-test-\(UUID().uuidString).jsonl")
        let body = """
        {"timestamp":"2026-04-24T13:00:00.000Z","type":"session_meta","payload":{"id":"019dbf9b-c76b-7421-91aa-7a82b8705487","cwd":"/Users/test/repo","model_provider":"openai"}}
        {"timestamp":"2026-04-24T13:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"refactor"}]}}
        {"timestamp":"2026-04-24T13:00:02.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\\"cmd\\":\\"ls -1\\",\\"workdir\\":\\"/x\\"}","call_id":"c1"}}
        {"timestamp":"2026-04-24T13:00:03.000Z","type":"response_item","payload":{"type":"function_call","name":"apply_patch","arguments":"{\\"input\\":\\"*** Begin Patch\\\\n*** Update File: src/auth.ts\\\\n@@\\\\n-old\\\\n+new\\\\n*** End Patch\\\\n\\"}","call_id":"c2"}}
        {"timestamp":"2026-04-24T13:00:04.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\\"cmd\\":\\"apply_patch <<'PATCH'\\\\n*** Begin Patch\\\\n*** Add File: src/new_feature.ts\\\\n+console.log('hi')\\\\n*** End Patch\\\\nPATCH\\"}","call_id":"c3"}}
        {"timestamp":"2026-04-24T13:00:05.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"done"}]}}
        """
        try body.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let sessionID = try SessionID(string: "019dbf9b-c76b-7421-91aa-7a82b8705487")
        let transcript = try CodexTranscriptParser().parse(
            url: tmp,
            sessionID: sessionID,
            workspaceID: "/Users/test/repo"
        )

        XCTAssertEqual(transcript.stats.userTurns, 1)
        XCTAssertEqual(transcript.stats.assistantTurns, 1)
        XCTAssertEqual(transcript.stats.toolUseCounts["exec_command"], 2,
                       "Both exec_command function_calls should be counted")
        XCTAssertEqual(transcript.stats.toolUseCounts["apply_patch"], 1,
                       "Direct apply_patch tool call should be counted")

        let paths = Set(transcript.stats.filesTouched.map(\.path))
        XCTAssertTrue(paths.contains("src/auth.ts"),
                      "apply_patch headers in the `input` arg should yield Update File paths")
        XCTAssertTrue(paths.contains("src/new_feature.ts"),
                      "apply_patch headers embedded in exec_command cmd should also be parsed")
    }

    // MARK: - apply_patch header parsing helper

    func test_parseApplyPatchHeaders_handlesAllStandardMarkers() {
        let body = """
        *** Begin Patch
        *** Update File: src/a.ts
        @@
        -x
        +y
        *** Add File: src/b.ts
        +new
        *** Delete File: src/c.ts
        *** Move File: old.txt -> new.txt
        *** End Patch
        """
        let paths = CodexTranscriptParser.parseApplyPatchHeaders(body)
        XCTAssertEqual(Set(paths), Set([
            "src/a.ts", "src/b.ts", "src/c.ts", "new.txt",
        ]))
    }

    // MARK: - Empty file

    func test_transcript_emptyFileReturnsEmptyStats() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rollout-empty-\(UUID().uuidString).jsonl")
        try "".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let sessionID = try SessionID(string: "019dbf9b-0000-7421-91aa-7a82b8705487")
        let transcript = try CodexTranscriptParser().parse(
            url: tmp,
            sessionID: sessionID,
            workspaceID: "/x"
        )
        XCTAssertEqual(transcript.stats.userTurns, 0)
        XCTAssertEqual(transcript.stats.assistantTurns, 0)
        XCTAssertEqual(transcript.stats.totalTokens, 0)
    }
}
