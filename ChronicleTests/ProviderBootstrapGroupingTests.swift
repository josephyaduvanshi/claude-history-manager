import XCTest
@testable import Chronicle

/// Locks down the neutral, provider-agnostic grouping logic used by
/// the Codex / Gemini bootstrap. The previous heuristic was too
/// aggressive: any cwd containing the substring "claude" or "/ai/"
/// got bucketed into an "AI/CLAUDE" group, which polluted the Codex
/// view whenever a user worked on a project literally named after
/// Claude (e.g. `claude-history-manager`).
///
/// These tests ensure:
///   - "claude" / "/ai/" never trigger a special-case bucket.
///   - Well-known Code / Desktop / Documents prefixes are stripped.
///   - The chosen group is the parent project group (second-to-last
///     directory) when one exists, else the project itself.
final class ProviderBootstrapGroupingTests: XCTestCase {

    // MARK: - Project-name false positives the old heuristic blew

    func test_claude_history_manager_under_Code_does_not_become_AI_CLAUDE() {
        let home = NSHomeDirectory()
        let cwd = "\(home)/Code/swift/apps/claude-history-manager"
        XCTAssertEqual(SessionsRepository.groupForCwd(cwd), "Apps")
    }

    func test_repo_named_claude_anywhere_else_does_not_become_AI_CLAUDE() {
        let home = NSHomeDirectory()
        let cwd = "\(home)/Documents/notes/claude"
        XCTAssertEqual(SessionsRepository.groupForCwd(cwd), "Notes")
    }

    func test_path_containing_slash_ai_slash_does_not_force_AI_group() {
        let home = NSHomeDirectory()
        let cwd = "\(home)/Code/ai/openai-experiments"
        // "ai" is a legitimate parent group name — that's fine, it
        // just shouldn't be hard-coded to "AI/CLAUDE".
        XCTAssertEqual(SessionsRepository.groupForCwd(cwd), "Ai")
    }

    // MARK: - Spec'd examples

    func test_Code_swift_apps_chronicle_groups_to_Apps() {
        let home = NSHomeDirectory()
        XCTAssertEqual(
            SessionsRepository.groupForCwd("\(home)/Code/swift/apps/chronicle"),
            "Apps"
        )
    }

    func test_Code_security_pentest_groups_to_Security() {
        let home = NSHomeDirectory()
        XCTAssertEqual(
            SessionsRepository.groupForCwd("\(home)/Code/security/pentest"),
            "Security"
        )
    }

    func test_Desktop_StealthZero_turnitin_groups_to_StealthZero() {
        let home = NSHomeDirectory()
        XCTAssertEqual(
            SessionsRepository.groupForCwd("\(home)/Desktop/StealthZero/turnitin"),
            "StealthZero"
        )
    }

    func test_home_directory_groups_to_home() {
        XCTAssertEqual(SessionsRepository.groupForCwd(NSHomeDirectory()), "home")
    }

    func test_tilde_form_resolves_to_home() {
        XCTAssertEqual(SessionsRepository.groupForCwd("~"), "home")
        XCTAssertEqual(SessionsRepository.groupForCwd("~/"), "home")
    }

    // MARK: - Edge cases

    func test_nil_cwd_returns_Other() {
        XCTAssertEqual(SessionsRepository.groupForCwd(nil), "Other")
    }

    func test_empty_cwd_returns_Other() {
        XCTAssertEqual(SessionsRepository.groupForCwd(""), "Other")
    }

    func test_root_returns_Other() {
        XCTAssertEqual(SessionsRepository.groupForCwd("/"), "Other")
    }

    func test_trailing_slash_is_ignored() {
        let home = NSHomeDirectory()
        XCTAssertEqual(
            SessionsRepository.groupForCwd("\(home)/Code/swift/apps/chronicle/"),
            "Apps"
        )
    }

    func test_single_segment_after_prefix_uses_that_segment() {
        let home = NSHomeDirectory()
        // Only one component after stripping "Code/" — fall back to it.
        XCTAssertEqual(
            SessionsRepository.groupForCwd("\(home)/Code/standalone"),
            "Standalone"
        )
    }

    func test_unknown_prefix_path_uses_second_to_last_component() {
        // No Code/Desktop/Documents prefix — still pick the parent.
        XCTAssertEqual(
            SessionsRepository.groupForCwd("/var/log/myapp/run-1"),
            "Myapp"
        )
    }

    func test_camel_case_name_is_preserved() {
        let home = NSHomeDirectory()
        XCTAssertEqual(
            SessionsRepository.groupForCwd("\(home)/Desktop/StealthZero"),
            "StealthZero"
        )
    }

    func test_tilde_relative_path_resolves_through_home() {
        XCTAssertEqual(
            SessionsRepository.groupForCwd("~/Code/swift/apps/chronicle"),
            "Apps"
        )
    }
}
