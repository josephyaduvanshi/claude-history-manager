import XCTest
@testable import Chronicle

final class CodexProviderTests: XCTestCase {

    // MARK: - Fixture loading

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

    // MARK: - Parser

    func test_parser_extractsCanonicalMetadataFromRollout() throws {
        let url = try loadFixture("sample-session.jsonl")
        let parser = CodexParser()
        let (metadata, flags) = try parser.parse(url: url, workspaceID: "/Users/test/repo")

        XCTAssertEqual(
            metadata.sessionID.description,
            "019dbf9b-c76b-7421-91aa-7a82b8705487",
            "session_meta payload's id should win"
        )
        XCTAssertEqual(metadata.title, "Refactor authentication middleware",
                       "Title should come from thread_name_updated event, not the env_context user message")
        XCTAssertEqual(metadata.workspaceID, "/Users/test/repo")
        XCTAssertEqual(metadata.messageCount, 4,
                       "Two user + two assistant response_items in fixture")
        XCTAssertEqual(metadata.tokenCount, 2800,
                       "tokenCount should reflect the LATEST cumulative total_token_usage")
        XCTAssertEqual(metadata.inputTokens, 2500)
        XCTAssertEqual(metadata.outputTokens, 300)
        XCTAssertEqual(metadata.model, "openai", "model_provider surfaces in the model field")
        XCTAssertTrue(flags.isEmpty, "Codex parser does not emit git_push / errored flags yet")
    }

    func test_parser_filenameSessionIDFallback() throws {
        // Synthesize a rollout file with NO session_meta.id field — the
        // parser should fall back to the UUID embedded in the filename
        // (Codex naming convention: `rollout-<ts>-<uuid>.jsonl`).
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rollout-2026-04-24T00-00-00-019dbfff-aaaa-7000-bbbb-cccccccccccc.jsonl")
        try """
        {"timestamp":"2026-04-24T00:00:00.000Z","type":"session_meta","payload":{"cwd":"/x","originator":"Codex"}}
        {"timestamp":"2026-04-24T00:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hello"}]}}
        """.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let parser = CodexParser()
        let (metadata, _) = try parser.parse(url: tmp, workspaceID: "/x")
        XCTAssertEqual(metadata.sessionID.description, "019dbfff-aaaa-7000-bbbb-cccccccccccc")
        XCTAssertEqual(metadata.title, "hello",
                       "Falls back to first user message text when thread_name_updated absent")
    }

    func test_parser_skipsPartialTrailingLine() throws {
        // Codex rollouts append per-line, but a process kill mid-write
        // can land a fragment. Ensure parse() doesn't throw on partial
        // JSON at EOF.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rollout-2026-04-24T00-00-00-019dbfff-aaaa-7000-bbbb-cccccccccccd.jsonl")
        try """
        {"timestamp":"2026-04-24T00:00:00.000Z","type":"session_meta","payload":{"id":"019dbfff-aaaa-7000-bbbb-cccccccccccd","cwd":"/x"}}
        {"timestamp":"2026-04-24T00:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hi"}]}}
        {"timestamp":"2026-04-24T00:00:02.000Z","type":"event_msg","payload":{"type":"to
        """.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let parser = CodexParser()
        let (metadata, _) = try parser.parse(url: tmp, workspaceID: "/x")
        XCTAssertEqual(metadata.title, "hi", "Partial line at EOF is dropped silently")
        XCTAssertEqual(metadata.messageCount, 1)
    }

    func test_parser_extractMetadata_pullsCwdAndGit() throws {
        let url = try loadFixture("sample-session.jsonl")
        let meta = CodexParser().extractMetadata(url: url)
        XCTAssertEqual(meta?.cwd, "/Users/test/repo")
        XCTAssertEqual(meta?.gitBranch, "main")
        XCTAssertEqual(meta?.gitCommitHash, "abc123")
        XCTAssertEqual(meta?.cliVersion, "0.120.0")
        XCTAssertEqual(meta?.originator, "Codex CLI")
        XCTAssertEqual(meta?.modelProvider, "openai")
    }

    func test_parser_filenameUUIDExtraction() {
        let url = URL(fileURLWithPath: "/tmp/rollout-2026-04-24T13-09-10-019dbfff-aaaa-7000-bbbb-cccccccccccc.jsonl")
        XCTAssertEqual(
            CodexParser.extractSessionUUIDFromFilename(url),
            "019dbfff-aaaa-7000-bbbb-cccccccccccc"
        )
    }

    func test_parser_filenameUUIDExtraction_returnsNilForNonUUID() {
        let url = URL(fileURLWithPath: "/tmp/rollout-foo-bar.jsonl")
        XCTAssertNil(CodexParser.extractSessionUUIDFromFilename(url))
    }

    // MARK: - Resume builder snapshots

    func test_resume_ghosttySnapshot() {
        let cmd = CodexResumeBuilder(loginShell: "/bin/zsh").build(
            terminal: .ghostty,
            sessionID: "019dbf9b-c76b-7421-91aa-7a82b8705487",
            cwd: "/Users/test/repo"
        )
        XCTAssertEqual(cmd.executable, "/usr/bin/open")
        XCTAssertEqual(cmd.arguments, [
            "-na", "Ghostty",
            "--args",
            "--working-directory=/Users/test/repo",
            "-e", "/bin/zsh", "-i", "-c",
            #"cd "/Users/test/repo" && codex resume 019dbf9b-c76b-7421-91aa-7a82b8705487"#,
        ])
    }

    func test_resume_itermSnapshot() {
        let cmd = CodexResumeBuilder(loginShell: "/bin/zsh").build(
            terminal: .iterm,
            sessionID: "S-1",
            cwd: "/x y"
        )
        XCTAssertEqual(cmd.executable, "/usr/bin/osascript")
        XCTAssertNotNil(cmd.appleScript)
        XCTAssertTrue(cmd.appleScript!.contains("codex resume S-1"))
        XCTAssertTrue(cmd.appleScript!.contains("/x y"))
    }

    func test_resume_terminalSnapshot() {
        let cmd = CodexResumeBuilder(loginShell: "/bin/zsh").build(
            terminal: .terminal,
            sessionID: "S-2",
            cwd: "/no spaces"
        )
        XCTAssertEqual(cmd.executable, "/usr/bin/osascript")
        XCTAssertTrue(cmd.appleScript?.contains("codex resume S-2") == true)
    }

    func test_resume_escapesQuotedCwd() {
        let cmd = CodexResumeBuilder(loginShell: "/bin/zsh").build(
            terminal: .ghostty,
            sessionID: "S",
            cwd: #"/tmp/he "said""#
        )
        // Inside double quotes the embedded `"` becomes `\"`. The shell
        // command should land as: cd "/tmp/he \"said\"" && codex resume S
        XCTAssertTrue(cmd.arguments.contains(where: { $0.contains(#"\"said\""#) }),
                      "Embedded double quotes must be backslash-escaped: \(cmd.arguments)")
    }

    // MARK: - Provider

    func test_provider_idAndNames() {
        let p = CodexProvider()
        XCTAssertEqual(CodexProvider.id, .codex)
        XCTAssertEqual(p.displayName, "Codex")
        XCTAssertEqual(p.iconAssetName, "codex")
    }

    func test_provider_watchRootsPointsAtCodexSessionsDir() {
        let p = CodexProvider()
        let roots = p.watchRoots()
        XCTAssertEqual(roots.count, 1)
        XCTAssertTrue(roots.first?.path.hasSuffix(".codex/sessions") ?? false,
                      "Watch root should be ~/.codex/sessions")
    }
}
