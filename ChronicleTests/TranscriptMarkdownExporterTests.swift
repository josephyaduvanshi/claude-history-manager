import XCTest
@testable import Chronicle

final class TranscriptMarkdownExporterTests: XCTestCase {
    func test_export_producesHeaderWithSessionAndCounts() throws {
        let url = Bundle.module.url(
            forResource: "Fixtures/transcript-sessions/-Users-test-tool-app/33333333-3333-3333-3333-333333333333.jsonl",
            withExtension: nil
        )!
        let transcript = try TranscriptParser().parse(
            url: url,
            workspaceID: "-Users-test-tool-app"
        )
        let session = SessionMetadata(
            sessionID: try SessionID(string: "33333333-3333-3333-3333-333333333333"),
            workspaceID: "-Users-test-tool-app",
            title: "Edit the webhook",
            createdAt: transcript.stats.createdAt,
            lastModifiedAt: transcript.stats.lastModifiedAt,
            messageCount: 5,
            tokenCount: transcript.stats.totalTokens,
            isLive: false
        )

        let md = TranscriptMarkdownExporter.export(
            session: session,
            transcript: transcript,
            workspaceDisplayName: "Test / tool-app"
        )

        XCTAssertTrue(md.hasPrefix("# Edit the webhook"))
        XCTAssertTrue(md.contains("- Workspace: Test / tool-app"))
        XCTAssertTrue(md.contains("- Messages: \(transcript.stats.userTurns) user + \(transcript.stats.assistantTurns) assistant"))
        XCTAssertTrue(md.contains("Edit·2, Bash·1") || md.contains("Edit·2"))
        // Must carry a divider between header and messages.
        XCTAssertTrue(md.contains("\n---\n"))
    }

    func test_export_numberEveryMessageAndSerializesToolCalls() throws {
        let url = Bundle.module.url(
            forResource: "Fixtures/transcript-sessions/-Users-test-tool-app/33333333-3333-3333-3333-333333333333.jsonl",
            withExtension: nil
        )!
        let transcript = try TranscriptParser().parse(
            url: url,
            workspaceID: "-Users-test-tool-app"
        )
        let session = SessionMetadata(
            sessionID: try SessionID(string: "33333333-3333-3333-3333-333333333333"),
            workspaceID: "-Users-test-tool-app",
            title: "x",
            createdAt: Date(),
            lastModifiedAt: Date(),
            messageCount: 0,
            tokenCount: 0,
            isLive: false
        )
        let md = TranscriptMarkdownExporter.export(
            session: session,
            transcript: transcript,
            workspaceDisplayName: "ws"
        )

        // First message is the user "Edit the webhook..." turn.
        XCTAssertTrue(md.contains("## 01 · You"))
        // An assistant turn at 02 and a tool section should both appear.
        XCTAssertTrue(md.contains("## 02 · Claude"))
        XCTAssertTrue(md.contains("Tool: Edit"))
        // Args should be fenced as ```json.
        XCTAssertTrue(md.contains("```json"))
    }
}
