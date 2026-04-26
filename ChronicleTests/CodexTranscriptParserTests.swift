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

    // MARK: - custom_tool_call shape (real Codex CLI ~0.120+)

    /// Real Codex rollouts deliver `apply_patch` as `payload.type ==
    /// "custom_tool_call"` with the patch body on `payload.input`
    /// directly (NOT a JSON-encoded args bag like `function_call`). The
    /// preview pane was showing blank Files Touched / Tools Used until
    /// the parser learned this shape.
    func test_transcript_handlesCustomToolCallApplyPatch() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rollout-custom-\(UUID().uuidString).jsonl")
        // Mirrors a real on-disk record from
        // ~/.codex/sessions/2026/04/25/rollout-2026-04-25T11-08-19-019dc22e-2f75-78c0-b6db-b78accd6b1e0.jsonl
        let body = """
        {"timestamp":"2026-04-25T01:11:00.000Z","type":"session_meta","payload":{"id":"019dc22e-2f75-78c0-b6db-b78accd6b1e0","cwd":"/Users/test/repo","model_provider":"openai"}}
        {"timestamp":"2026-04-25T01:11:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"add an icon"}]}}
        {"timestamp":"2026-04-25T01:11:12.979Z","type":"response_item","payload":{"type":"custom_tool_call","status":"completed","call_id":"call_MWD6hPcV","name":"apply_patch","input":"*** Begin Patch\\n*** Add File: docs/branding/generate_icon.py\\n+#!/usr/bin/env python3\\n+print('hi')\\n*** End Patch"}}
        {"timestamp":"2026-04-25T01:11:13.000Z","type":"response_item","payload":{"type":"custom_tool_call","status":"completed","call_id":"call_xyz","name":"apply_patch","input":"*** Begin Patch\\n*** Update File: docs/branding/icon.png\\n*** End Patch"}}
        {"timestamp":"2026-04-25T01:11:14.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\\"cmd\\":\\"ls\\"}","call_id":"c1"}}
        {"timestamp":"2026-04-25T01:11:15.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"done"}]}}
        """
        try body.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let sessionID = try SessionID(string: "019dc22e-2f75-78c0-b6db-b78accd6b1e0")
        let transcript = try CodexTranscriptParser().parse(
            url: tmp,
            sessionID: sessionID,
            workspaceID: "/Users/test/repo"
        )

        XCTAssertEqual(transcript.stats.toolUseCounts["apply_patch"], 2,
                       "Both custom_tool_call apply_patch invocations should be counted")
        XCTAssertEqual(transcript.stats.toolUseCounts["exec_command"], 1)

        let paths = Set(transcript.stats.filesTouched.map(\.path))
        XCTAssertTrue(paths.contains("docs/branding/generate_icon.py"),
                      "Add File path from custom_tool_call.input should be extracted")
        XCTAssertTrue(paths.contains("docs/branding/icon.png"),
                      "Update File path from custom_tool_call.input should be extracted")
    }

    // MARK: - Real-data smoke test

    /// Smoke test against an actual rollout from `~/.codex/sessions`.
    /// The point isn't to hard-code expected values (every machine
    /// will produce different output) — it's to verify the parser
    /// never returns blank Tools Used / blank Files Touched against
    /// real Codex wire data, which is the exact symptom the user
    /// reported. Skipped in CI / on machines without a Codex history.
    ///
    /// Two passes: prefer a rollout that contains `apply_patch`
    /// (so we can assert Files Touched is non-empty too), fall back
    /// to any rollout with tool calls otherwise.
    func test_transcript_realCodexFileProducesNonBlankStats() throws {
        let fm = FileManager.default
        let codexRoot = (fm.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions"))
        guard fm.fileExists(atPath: codexRoot.path) else {
            throw XCTSkip("No Codex sessions directory present; skipping real-data smoke test")
        }
        let candidate: URL
        if let withPatch = Self.findRollout(under: codexRoot, containing: "\"name\":\"apply_patch\"") {
            candidate = withPatch
        } else if let withTools = Self.findRollout(under: codexRoot, containingAny: ["\"function_call\"", "\"custom_tool_call\""]) {
            candidate = withTools
        } else {
            throw XCTSkip("No Codex rollouts with tool calls found; skipping")
        }

        let parser = CodexTranscriptParser()
        let sessionID = try SessionID(string: "019dbf9b-c76b-7421-91aa-7a82b8705487")
        let transcript = try parser.parse(
            url: candidate,
            sessionID: sessionID,
            workspaceID: candidate.path
        )

        XCTAssertFalse(transcript.stats.toolUseCounts.isEmpty,
                       "Real Codex rollout \(candidate.lastPathComponent) must produce non-empty Tools Used")
        // Files Touched is best-effort; we assert it's non-empty only when
        // the rollout actually contains an apply_patch (which always
        // writes a path).
        if transcript.stats.toolUseCounts["apply_patch"] != nil {
            XCTAssertFalse(transcript.stats.filesTouched.isEmpty,
                           "Rollout has apply_patch but Files Touched is empty for \(candidate.lastPathComponent)")
        }
        // Print a summary to stdout for orchestrator-level inspection.
        let toolsList = transcript.stats.toolUseCounts
            .map { "\($0.key)×\($0.value)" }
            .sorted()
            .joined(separator: ", ")
        let pathList = transcript.stats.filesTouched.prefix(8).map(\.path).joined(separator: ", ")
        print("[real Codex] \(candidate.path)")
        print("[real Codex] tools=[\(toolsList)]")
        print("[real Codex] files=[\(pathList)]")
    }

    /// Scan `root` recursively for the first `rollout-*.jsonl` whose
    /// content includes any of `needles`. Reads only the first 1 MB
    /// so it stays cheap on large rollouts.
    static func findRollout(under root: URL, containingAny needles: [String]) -> URL? {
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in walker {
            guard url.lastPathComponent.hasPrefix("rollout-"),
                  url.pathExtension == "jsonl" else { continue }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let text = String(
                    data: data.prefix(1024 * 1024),
                    encoding: .utf8
                  ) else { continue }
            for needle in needles where text.contains(needle) {
                return url
            }
        }
        return nil
    }

    static func findRollout(under root: URL, containing needle: String) -> URL? {
        return findRollout(under: root, containingAny: [needle])
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
