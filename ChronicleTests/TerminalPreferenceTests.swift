import XCTest
import GRDB
@testable import Chronicle

final class TerminalPreferenceTests: XCTestCase {

    /// Fresh in-memory UserDefaults suite per test so nothing leaks across runs.
    private func makeDefaults(name: String = UUID().uuidString) -> UserDefaults {
        UserDefaults(suiteName: name)!
    }

    /// Installed-probe double that claims ghostty is available.
    private struct GhosttyOnlyProbe: TerminalInstallationProbe {
        func isAppInstalled(bundleID: String) -> Bool {
            bundleID == Terminal.ghostty.bundleID
        }
        func isCLIAvailable(paths: [String]) -> Bool { false }
    }

    // MARK: - Default terminal

    func test_defaultTerminal_returnsTerminalAppWhenUnset_withEmptyProbe() async throws {
        let dbq = try DatabaseQueue()
        try Migrations.all(dbq)
        struct EmptyProbe: TerminalInstallationProbe {
            func isAppInstalled(bundleID: String) -> Bool { false }
            func isCLIAvailable(paths: [String]) -> Bool { false }
        }
        let pref = TerminalPreference(defaults: makeDefaults(), database: dbq, installationProbe: EmptyProbe())
        let t = await pref.defaultTerminal()
        XCTAssertEqual(t, .terminal)
    }

    func test_defaultTerminal_fallsBackToFirstInstalled() async throws {
        let dbq = try DatabaseQueue()
        try Migrations.all(dbq)
        let pref = TerminalPreference(defaults: makeDefaults(), database: dbq, installationProbe: GhosttyOnlyProbe())
        // Ghostty comes before Terminal in the CaseIterable order.
        let t = await pref.defaultTerminal()
        XCTAssertEqual(t, .ghostty)
    }

    func test_setDefaultTerminal_roundTripsThroughUserDefaults() async throws {
        let dbq = try DatabaseQueue()
        try Migrations.all(dbq)
        let defaults = makeDefaults()
        let pref = TerminalPreference(defaults: defaults, database: dbq, installationProbe: GhosttyOnlyProbe())

        await pref.setDefaultTerminal(.iterm)

        // Read back through the same actor.
        let got = await pref.defaultTerminal()
        XCTAssertEqual(got, .iterm)

        // Raw UserDefaults key present too.
        XCTAssertEqual(defaults.string(forKey: TerminalPreference.defaultTerminalKey), "iterm")
    }

    // MARK: - Per-session override

    private func sid(_ s: String) -> SessionID {
        try! SessionID(string: s)
    }

    func test_override_returnsNilWhenAbsent() async throws {
        let dbq = try DatabaseQueue()
        try Migrations.all(dbq)
        let pref = TerminalPreference(defaults: makeDefaults(), database: dbq)
        let ov = try await pref.override(for: sid("11111111-1111-1111-1111-111111111111"))
        XCTAssertNil(ov)
    }

    func test_setOverride_writeAndRead() async throws {
        let dbq = try DatabaseQueue()
        try Migrations.all(dbq)
        let pref = TerminalPreference(defaults: makeDefaults(), database: dbq)

        let s = sid("11111111-1111-1111-1111-111111111111")
        try await pref.setOverride(.kitty, for: s)
        let ov = try await pref.override(for: s)
        XCTAssertEqual(ov, .kitty)
    }

    func test_setOverride_upsertsExistingRow() async throws {
        let dbq = try DatabaseQueue()
        try Migrations.all(dbq)
        let pref = TerminalPreference(defaults: makeDefaults(), database: dbq)

        let s = sid("22222222-2222-2222-2222-222222222222")
        try await pref.setOverride(.ghostty, for: s)
        try await pref.setOverride(.wezterm, for: s)
        let ov = try await pref.override(for: s)
        XCTAssertEqual(ov, .wezterm)
    }

    func test_setOverride_nilClearsRow() async throws {
        let dbq = try DatabaseQueue()
        try Migrations.all(dbq)
        let pref = TerminalPreference(defaults: makeDefaults(), database: dbq)

        let s = sid("33333333-3333-3333-3333-333333333333")
        try await pref.setOverride(.alacritty, for: s)
        try await pref.setOverride(nil, for: s)
        let ov = try await pref.override(for: s)
        XCTAssertNil(ov, "passing nil must delete the override row")
    }

    // MARK: - Resolved

    func test_resolved_returnsOverrideWhenPresent() async throws {
        let dbq = try DatabaseQueue()
        try Migrations.all(dbq)
        let pref = TerminalPreference(defaults: makeDefaults(), database: dbq, installationProbe: GhosttyOnlyProbe())
        await pref.setDefaultTerminal(.ghostty)

        let s = sid("44444444-4444-4444-4444-444444444444")
        try await pref.setOverride(.iterm, for: s)
        let t = try await pref.resolved(for: s)
        XCTAssertEqual(t, .iterm, "override must win over default")
    }

    func test_resolved_returnsDefaultWhenNoOverride() async throws {
        let dbq = try DatabaseQueue()
        try Migrations.all(dbq)
        let pref = TerminalPreference(defaults: makeDefaults(), database: dbq, installationProbe: GhosttyOnlyProbe())
        await pref.setDefaultTerminal(.wezterm)

        let s = sid("55555555-5555-5555-5555-555555555555")
        let t = try await pref.resolved(for: s)
        XCTAssertEqual(t, .wezterm)
    }
}
