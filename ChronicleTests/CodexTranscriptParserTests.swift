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

        // Messages array now populated (Phase 4): one entry per
        // user/assistant message in the rollout. Sample fixture has
        // two of each.
        XCTAssertEqual(transcript.messages.count, 4,
                       "Phase 4: parser now populates messages for transcript view")

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

    // MARK: - isPathLikeToken heuristic

    func test_isPathLikeToken_acceptsAndRejectsExpectedShapes() {
        XCTAssertTrue(CodexTranscriptParser.isPathLikeToken("Chronicle/Repository/SessionsRepository.swift"))
        XCTAssertTrue(CodexTranscriptParser.isPathLikeToken("./Package.swift"))
        XCTAssertTrue(CodexTranscriptParser.isPathLikeToken("/tmp/foo.txt"))
        XCTAssertTrue(CodexTranscriptParser.isPathLikeToken("~/.config/foo.toml"))
        XCTAssertTrue(CodexTranscriptParser.isPathLikeToken("Migrations.swift"))
        XCTAssertTrue(CodexTranscriptParser.isPathLikeToken("../sibling/file.go"))

        XCTAssertFalse(CodexTranscriptParser.isPathLikeToken("-ba"))
        XCTAssertFalse(CodexTranscriptParser.isPathLikeToken("--name"))
        XCTAssertFalse(CodexTranscriptParser.isPathLikeToken("'!**/.build/**'"))
        XCTAssertFalse(CodexTranscriptParser.isPathLikeToken("'1,260p'"))
        XCTAssertFalse(CodexTranscriptParser.isPathLikeToken(""))

        XCTAssertTrue(CodexTranscriptParser.isPathLikeToken("'Chronicle/UI/AppView.swift'"))
        XCTAssertTrue(CodexTranscriptParser.isPathLikeToken("\"Package.swift\""))
    }

    // MARK: - tokenizeShell

    func test_tokenizeShell_handlesQuotesAndBackslashEscapes() {
        XCTAssertEqual(
            CodexTranscriptParser.tokenizeShell("nl -ba foo.swift"),
            ["nl", "-ba", "foo.swift"]
        )
        XCTAssertEqual(
            CodexTranscriptParser.tokenizeShell("sed -n '1,20p' bar.swift"),
            ["sed", "-n", "'1,20p'", "bar.swift"]
        )
        XCTAssertEqual(
            CodexTranscriptParser.tokenizeShell(#"rg -n "PRAGMA foreign_keys" Chronicle"#),
            ["rg", "-n", "\"PRAGMA foreign_keys\"", "Chronicle"]
        )
        XCTAssertEqual(
            CodexTranscriptParser.tokenizeShell("cat path\\ with\\ spaces.txt"),
            ["cat", "path with spaces.txt"]
        )
        XCTAssertEqual(
            CodexTranscriptParser.tokenizeShell("   leading   trailing   "),
            ["leading", "trailing"]
        )
        XCTAssertEqual(CodexTranscriptParser.tokenizeShell(""), [])
    }

    // MARK: - Real-shape tests (sampled from ~/.codex/sessions/2026/04/)

    func test_extractFilePaths_nl_extractsPathArgument() {
        let paths = CodexTranscriptParser.extractFilePaths(
            toolName: "exec_command",
            args: ["cmd": "nl -ba Chronicle/Repository/SessionsRepository.swift"]
        )
        XCTAssertEqual(paths, ["Chronicle/Repository/SessionsRepository.swift"])
    }

    func test_extractFilePaths_nlPipeSed_extractsFromFirstPipeSegmentOnly() {
        let paths = CodexTranscriptParser.extractFilePaths(
            toolName: "exec_command",
            args: ["cmd": "nl -ba Chronicle/Repository/SessionsRepository.swift | sed -n '1,260p'"]
        )
        XCTAssertEqual(paths, ["Chronicle/Repository/SessionsRepository.swift"])
    }

    func test_extractFilePaths_sedNoPipe_extractsPathArgument() {
        let paths = CodexTranscriptParser.extractFilePaths(
            toolName: "exec_command",
            args: ["cmd": "sed -n '254,340p' Chronicle/Repository/Migrations.swift"]
        )
        XCTAssertEqual(paths, ["Chronicle/Repository/Migrations.swift"])
    }

    func test_extractFilePaths_rgWithGlobNegation_skipsGlobAndQuotedPattern() {
        let paths = CodexTranscriptParser.extractFilePaths(
            toolName: "exec_command",
            args: ["cmd": #"rg -n "PRAGMA foreign_keys" Chronicle -g '!**/.build/**'"#]
        )
        XCTAssertEqual(paths, [])
    }

    func test_extractFilePaths_rgWithSourceFileArgs_extractsThem() {
        let paths = CodexTranscriptParser.extractFilePaths(
            toolName: "exec_command",
            args: ["cmd": #"rg -n "PRAGMA" Chronicle/Repository/Database.swift Chronicle/Repository/Migrations.swift"#]
        )
        XCTAssertEqual(
            paths,
            ["Chronicle/Repository/Database.swift", "Chronicle/Repository/Migrations.swift"]
        )
    }

    func test_extractFilePaths_swiftBuild_extractsNothing() {
        XCTAssertEqual(
            CodexTranscriptParser.extractFilePaths(
                toolName: "exec_command",
                args: ["cmd": "swift build"]
            ),
            []
        )
    }

    func test_extractFilePaths_swiftTest_extractsNothing() {
        XCTAssertEqual(
            CodexTranscriptParser.extractFilePaths(
                toolName: "exec_command",
                args: ["cmd": "swift test --filter CodexTranscriptParserTests"]
            ),
            []
        )
    }

    func test_extractFilePaths_gitStatus_extractsNothing() {
        XCTAssertEqual(
            CodexTranscriptParser.extractFilePaths(
                toolName: "exec_command",
                args: ["cmd": "git status"]
            ),
            []
        )
    }

    func test_extractFilePaths_cat_extractsPathArgument() {
        XCTAssertEqual(
            CodexTranscriptParser.extractFilePaths(
                toolName: "exec_command",
                args: ["cmd": "cat /tmp/output.log"]
            ),
            ["/tmp/output.log"]
        )
    }

    func test_extractFilePaths_redirectionToFile_extractsTarget() {
        XCTAssertEqual(
            CodexTranscriptParser.extractFilePaths(
                toolName: "exec_command",
                args: ["cmd": "echo hello > /tmp/out.txt"]
            ),
            ["/tmp/out.txt"]
        )
    }

    func test_extractFilePaths_findWithDotRoot_extractsRoot() {
        let paths = CodexTranscriptParser.extractFilePaths(
            toolName: "exec_command",
            args: ["cmd": #"find . -name "*.swift""#]
        )
        XCTAssertEqual(paths, [])
    }

    func test_extractFilePaths_apply_patch_unchanged_regression() {
        let body = """
        *** Begin Patch
        *** Update File: Chronicle/UI/AppView.swift
        @@
        *** End Patch
        """
        XCTAssertEqual(
            CodexTranscriptParser.extractFilePaths(
                toolName: "apply_patch",
                args: ["input": body]
            ),
            ["Chronicle/UI/AppView.swift"]
        )
    }

    func test_extractFilePaths_applyPatchViaShell_unchanged_regression() {
        let body = """
        cat <<'EOF' | apply_patch
        *** Begin Patch
        *** Update File: Chronicle/UI/MenubarView.swift
        @@
        *** End Patch
        EOF
        """
        XCTAssertEqual(
            CodexTranscriptParser.extractFilePaths(
                toolName: "exec_command",
                args: ["cmd": body]
            ),
            ["Chronicle/UI/MenubarView.swift"]
        )
    }

    func test_extractFilePathsFromCustomToolCall_execCommand_extractsShellArgs() {
        let paths = CodexTranscriptParser.extractFilePathsFromCustomToolCall(
            toolName: "exec_command",
            input: "cat Chronicle/UI/AppView.swift"
        )
        XCTAssertEqual(paths, ["Chronicle/UI/AppView.swift"])
    }

    // MARK: - Logical-operator and redirect coverage

    func test_extractFilePaths_logicalAnd_inspectsBothSegments() {
        let paths = CodexTranscriptParser.extractFilePaths(
            toolName: "exec_command",
            args: ["cmd": "nl Chronicle/UI/AppView.swift && cat Chronicle/UI/MenubarView.swift"]
        )
        XCTAssertEqual(
            paths,
            ["Chronicle/UI/AppView.swift", "Chronicle/UI/MenubarView.swift"]
        )
    }

    func test_extractFilePaths_semicolon_inspectsBothSegments() {
        let paths = CodexTranscriptParser.extractFilePaths(
            toolName: "exec_command",
            args: ["cmd": "ls /tmp ; cat /tmp/log.txt"]
        )
        // ls is in skipHeads → contributes nothing; cat contributes its arg
        XCTAssertEqual(paths, ["/tmp/log.txt"])
    }

    func test_extractFilePaths_logicalOr_inspectsBothSegments() {
        let paths = CodexTranscriptParser.extractFilePaths(
            toolName: "exec_command",
            args: ["cmd": "test -f Chronicle/UI/AppView.swift || cat Chronicle/UI/MenubarView.swift"]
        )
        // `test -f` extracts (Chronicle/UI/AppView.swift); cat extracts the second
        XCTAssertEqual(
            paths.sorted(),
            ["Chronicle/UI/AppView.swift", "Chronicle/UI/MenubarView.swift"].sorted()
        )
    }

    func test_extractFilePaths_inputRedirect_extractsSource() {
        let paths = CodexTranscriptParser.extractFilePaths(
            toolName: "exec_command",
            args: ["cmd": "swift build < /tmp/input.txt"]
        )
        // swift is skipHead so its argv contributes nothing, but the
        // input redirect is still picked up.
        XCTAssertEqual(paths, ["/tmp/input.txt"])
    }

    func test_extractFilePaths_sedInPlaceBsdEmptySuffix_currentBehavior() {
        // BSD/macOS sed -i requires an empty suffix arg. The pattern-consumer
        // logic skips '' as the pattern, then 's/foo/bar/' is the next
        // positional and currently passes isPathLikeToken (contains '/').
        // We document this as a known false-positive limitation; future
        // refactors must either preserve or fix it deliberately.
        let paths = CodexTranscriptParser.extractFilePaths(
            toolName: "exec_command",
            args: ["cmd": "sed -i '' 's/foo/bar/' Chronicle/UI/AppView.swift"]
        )
        // Snapshot of today's reality, not the ideal: the sed substitution
        // pattern leaks through alongside the real path because the pattern
        // consumer treats `''` as the pattern and `s/foo/bar/` then passes
        // isPathLikeToken (contains a `/`). If a future refactor fixes this,
        // update both elements of the expected array deliberately.
        XCTAssertEqual(paths, ["s/foo/bar/", "Chronicle/UI/AppView.swift"])
    }

    // MARK: - Message body extraction (Phase 4)

    func test_codexTranscript_populatesUserAndAssistantMessages() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-msg-test-\(UUID().uuidString).jsonl")
        let lines = [
            #"{"type":"session_meta","timestamp":"2026-04-25T12:00:00Z","payload":{"cwd":"/tmp/x","model_provider":"openai","cli_version":"0.120"}}"#,
            #"{"type":"response_item","timestamp":"2026-04-25T12:00:01Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hello codex"}]}}"#,
            #"{"type":"response_item","timestamp":"2026-04-25T12:00:02Z","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"hi back"}]}}"#,
            #"{"type":"response_item","timestamp":"2026-04-25T12:00:03Z","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"system prompt — should be skipped"}]}}"#,
        ]
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let parser = CodexTranscriptParser()
        let sid = try SessionID(string: "019dbf9b-c76b-7421-91aa-7a82b8705487")
        let transcript = try parser.parse(url: url, sessionID: sid, workspaceID: "codex:/tmp/x")

        XCTAssertEqual(transcript.messages.count, 2,
            "Developer-role messages must be filtered; user + assistant remain")

        guard case .user(let u) = transcript.messages.first else {
            XCTFail("First message must be a user turn")
            return
        }
        XCTAssertEqual(u.markdown, "hello codex")

        guard case .assistant(let a) = transcript.messages.last else {
            XCTFail("Last message must be an assistant turn")
            return
        }
        XCTAssertEqual(a.markdown, "hi back")
    }

    func test_codexTranscript_concatenatesMultipleContentBlocks() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-multi-\(UUID().uuidString).jsonl")
        let lines = [
            #"{"type":"response_item","timestamp":"2026-04-25T12:00:01Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"line 1"},{"type":"input_text","text":"line 2"}]}}"#,
        ]
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let parser = CodexTranscriptParser()
        let sid = try SessionID(string: "019dbf9b-c76b-7421-91aa-7a82b8705487")
        let transcript = try parser.parse(url: url, sessionID: sid, workspaceID: "codex:/tmp/x")
        guard case .user(let u) = transcript.messages.first else {
            XCTFail("Expected one user message"); return
        }
        XCTAssertEqual(u.markdown, "line 1\nline 2",
            "Multiple content blocks must be newline-joined")
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

    // MARK: - Tool-call interleaving (Phase 4 follow-up)

    func test_codexTranscript_emitsToolCallsBetweenMessages() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-tc-test-\(UUID().uuidString).jsonl")
        let lines = [
            #"{"type":"response_item","timestamp":"2026-04-25T12:00:01Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"list files"}]}}"#,
            #"{"type":"response_item","timestamp":"2026-04-25T12:00:02Z","payload":{"type":"function_call","name":"exec_command","call_id":"call_001","arguments":"{\"cmd\":\"ls /tmp\"}"}}"#,
            #"{"type":"response_item","timestamp":"2026-04-25T12:00:03Z","payload":{"type":"function_call_output","call_id":"call_001","output":"foo.txt\nbar.txt"}}"#,
            #"{"type":"response_item","timestamp":"2026-04-25T12:00:04Z","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"two files"}]}}"#,
        ]
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let parser = CodexTranscriptParser()
        let sid = try SessionID(string: "019dbf9b-c76b-7421-91aa-7a82b8705487")
        let transcript = try parser.parse(url: url, sessionID: sid, workspaceID: "codex:/tmp/x")

        XCTAssertEqual(transcript.messages.count, 3,
            "Expected user + tool call + assistant in chronological order")
        guard case .user = transcript.messages[0],
              case .toolCall(let tc) = transcript.messages[1],
              case .assistant = transcript.messages[2] else {
            XCTFail("Order should be user, toolCall, assistant. Got: \(transcript.messages.map(\.id))")
            return
        }
        XCTAssertEqual(tc.name, "exec_command")
        XCTAssertEqual(tc.resultText, "foo.txt\nbar.txt",
            "function_call_output must populate resultText for matching call_id")
    }

    func test_codexTranscript_customToolCallProducesToolCall() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-ctc-\(UUID().uuidString).jsonl")
        let lines = [
            #"{"type":"response_item","timestamp":"2026-04-25T12:00:01Z","payload":{"type":"custom_tool_call","name":"apply_patch","call_id":"call_002","input":"*** Begin Patch\n*** Update File: foo.swift\n*** End Patch"}}"#,
        ]
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let parser = CodexTranscriptParser()
        let sid = try SessionID(string: "019dbf9b-c76b-7421-91aa-7a82b8705487")
        let transcript = try parser.parse(url: url, sessionID: sid, workspaceID: "codex:/tmp/x")

        XCTAssertEqual(transcript.messages.count, 1)
        guard case .toolCall(let tc) = transcript.messages.first else {
            XCTFail("Expected a toolCall message"); return
        }
        XCTAssertEqual(tc.name, "apply_patch")
        if case .string(let s) = tc.args["input"] {
            XCTAssertTrue(s.contains("*** Update File: foo.swift"))
        } else {
            XCTFail("custom_tool_call args must carry the input string under 'input' key")
        }
    }

    func test_codexTranscript_skipsMessageWithEmptyContentBlocks() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-blank-\(UUID().uuidString).jsonl")
        let lines = [
            // Empty content array — should be skipped, NOT produce a blank bubble.
            #"{"type":"response_item","timestamp":"2026-04-25T12:00:01Z","payload":{"type":"message","role":"assistant","content":[]}}"#,
            // Non-empty assistant — should produce a bubble.
            #"{"type":"response_item","timestamp":"2026-04-25T12:00:02Z","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"hi"}]}}"#,
        ]
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let parser = CodexTranscriptParser()
        let sid = try SessionID(string: "019dbf9b-c76b-7421-91aa-7a82b8705487")
        let transcript = try parser.parse(url: url, sessionID: sid, workspaceID: "codex:/tmp/x")

        XCTAssertEqual(transcript.messages.count, 1,
            "Empty-content assistant message must be skipped")
        guard case .assistant(let a) = transcript.messages.first else {
            XCTFail("Expected the non-empty assistant turn"); return
        }
        XCTAssertEqual(a.markdown, "hi")
        // Stats still counts both for accurate session-stats parity with Claude.
        XCTAssertEqual(transcript.stats.assistantTurns, 2)
    }

    // MARK: - turn_context model extraction (Phase 6a)

    /// Codex CLI ~0.120+ emits a `turn_context` event whose top-level
    /// `model` field carries the actual model name (e.g. `gpt-5.4`).
    /// The parser previously only read `session_meta.model_provider`,
    /// which is just the API host (`openai`). UI showed "openai"
    /// everywhere instead of the real model. Verify turn_context.model
    /// takes precedence.
    func test_codexTranscript_capturesModelFromTurnContext() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-tc-\(UUID().uuidString).jsonl")
        let lines = [
            #"{"type":"session_meta","timestamp":"2026-04-25T12:00:00Z","payload":{"model_provider":"openai","cwd":"/tmp"}}"#,
            #"{"type":"turn_context","timestamp":"2026-04-25T12:00:01Z","model":"gpt-5.4","collaboration_mode":{"mode":"default"}}"#,
            #"{"type":"response_item","timestamp":"2026-04-25T12:00:02Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hi"}]}}"#,
        ]
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let parser = CodexTranscriptParser()
        let sid = try SessionID(string: "019dbf9b-c76b-7421-91aa-7a82b8705487")
        let t = try parser.parse(url: url, sessionID: sid, workspaceID: "codex:/tmp")
        XCTAssertEqual(t.stats.model, "gpt-5.4",
            "turn_context.model takes precedence over session_meta.model_provider")
    }
}
