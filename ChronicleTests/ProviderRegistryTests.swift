import XCTest
@testable import Chronicle

final class ProviderRegistryTests: XCTestCase {

    // MARK: - Test doubles

    private struct ClaudeStub: Provider {
        static let id: ProviderID = .claude
        var displayName: String { "Claude Code" }
        var iconAssetName: String { "claude" }
        let available: Bool
        func isAvailable() -> Bool { available }
        func watchRoots() -> [URL] { [] }
        func makeParser() -> any SessionParser { Sink() }
        func resumeCommand(sessionID: String, cwd: String, terminal: Terminal, loginShell: String) -> LaunchCommand {
            LaunchCommand(executable: "/bin/true", arguments: [])
        }
    }

    private struct CodexStub: Provider {
        static let id: ProviderID = .codex
        var displayName: String { "Codex" }
        var iconAssetName: String { "codex" }
        let available: Bool
        func isAvailable() -> Bool { available }
        func watchRoots() -> [URL] { [] }
        func makeParser() -> any SessionParser { Sink() }
        func resumeCommand(sessionID: String, cwd: String, terminal: Terminal, loginShell: String) -> LaunchCommand {
            LaunchCommand(executable: "/bin/true", arguments: [])
        }
    }

    private struct GeminiStub: Provider {
        static let id: ProviderID = .gemini
        var displayName: String { "Gemini" }
        var iconAssetName: String { "gemini" }
        let available: Bool
        func isAvailable() -> Bool { available }
        func watchRoots() -> [URL] { [] }
        func makeParser() -> any SessionParser { Sink() }
        func resumeCommand(sessionID: String, cwd: String, terminal: Terminal, loginShell: String) -> LaunchCommand {
            LaunchCommand(executable: "/bin/true", arguments: [])
        }
    }

    private struct Sink: SessionParser {
        func parse(url: URL, workspaceID: String) throws -> (SessionMetadata, Set<String>) {
            throw NSError(domain: "stub", code: 0)
        }
    }

    // MARK: - Tests

    func test_onlyAvailableProvidersAreRetained() async {
        let registry = ProviderRegistry(candidates: [
            ClaudeStub(available: true),
            CodexStub(available: false),
            GeminiStub(available: true),
        ])
        let ids = await registry.availableIDs()
        XCTAssertEqual(ids, [.claude, .gemini], "Codex was unavailable, must not appear")
    }

    func test_orderedReturnsCanonicalOrderRegardlessOfInputOrder() async {
        // Feed the registry in reverse order; canonical ordering must win.
        let registry = ProviderRegistry(candidates: [
            GeminiStub(available: true),
            CodexStub(available: true),
            ClaudeStub(available: true),
        ])
        let ids = await registry.availableIDs()
        XCTAssertEqual(ids, [.claude, .codex, .gemini])
    }

    func test_lookupByIDReturnsProvider() async {
        let registry = ProviderRegistry(candidates: [
            ClaudeStub(available: true),
        ])
        let claude = await registry.provider(for: .claude)
        XCTAssertNotNil(claude)
        XCTAssertEqual(claude?.displayName, "Claude Code")

        let codex = await registry.provider(for: .codex)
        XCTAssertNil(codex, "Unavailable provider must not be returned")
    }

    func test_emptyRegistryHasZeroCount() async {
        let registry = ProviderRegistry(candidates: [
            ClaudeStub(available: false),
            CodexStub(available: false),
            GeminiStub(available: false),
        ])
        let count = await registry.count
        XCTAssertEqual(count, 0)
    }

    func test_singleAvailableProviderRendersJustItself() async {
        let registry = ProviderRegistry(candidates: [
            ClaudeStub(available: true),
            CodexStub(available: false),
            GeminiStub(available: false),
        ])
        let ordered = await registry.ordered()
        XCTAssertEqual(ordered.count, 1)
        XCTAssertEqual(ProviderID.claude, type(of: ordered[0]).id)
    }

    func test_providerInstanceIDMatchesStaticID() {
        let claude: any Provider = ClaudeStub(available: true)
        let codex: any Provider = CodexStub(available: true)
        let gemini: any Provider = GeminiStub(available: true)
        XCTAssertEqual(claude.id, .claude)
        XCTAssertEqual(codex.id, .codex)
        XCTAssertEqual(gemini.id, .gemini)
    }

    func test_providerIDStringRoundtrip() {
        XCTAssertEqual(ProviderID.claude.rawValue, "claude")
        XCTAssertEqual(ProviderID.codex.rawValue, "codex")
        XCTAssertEqual(ProviderID.gemini.rawValue, "gemini")
        XCTAssertEqual(ProviderID(rawValue: "claude"), .claude)
        XCTAssertEqual(ProviderID(rawValue: "codex"), .codex)
        XCTAssertEqual(ProviderID(rawValue: "gemini"), .gemini)
        XCTAssertNil(ProviderID(rawValue: "aider"))
    }
}
