import XCTest
@testable import Chronicle

final class TerminalInstallationTests: XCTestCase {

    // MARK: - Enum metadata

    func test_allCases_count_isSix() {
        XCTAssertEqual(Terminal.allCases.count, 6)
    }

    func test_displayName_isStableAcrossAllCases() {
        XCTAssertEqual(Terminal.ghostty.displayName,   "Ghostty")
        XCTAssertEqual(Terminal.iterm.displayName,     "iTerm")
        XCTAssertEqual(Terminal.terminal.displayName,  "Terminal")
        XCTAssertEqual(Terminal.alacritty.displayName, "Alacritty")
        XCTAssertEqual(Terminal.wezterm.displayName,   "WezTerm")
        XCTAssertEqual(Terminal.kitty.displayName,     "kitty")
    }

    func test_bundleID_matchesKnownApps() {
        XCTAssertEqual(Terminal.ghostty.bundleID,   "com.mitchellh.ghostty")
        XCTAssertEqual(Terminal.iterm.bundleID,     "com.googlecode.iterm2")
        XCTAssertEqual(Terminal.terminal.bundleID,  "com.apple.Terminal")
        XCTAssertEqual(Terminal.alacritty.bundleID, "org.alacritty")
        XCTAssertEqual(Terminal.wezterm.bundleID,   "com.github.wez.wezterm")
        XCTAssertEqual(Terminal.kitty.bundleID,     "net.kovidgoyal.kitty")
    }

    func test_cliCandidates_onlyPopulatedForCliTerminals() {
        XCTAssertTrue(Terminal.ghostty.cliExecutableCandidates.isEmpty)
        XCTAssertTrue(Terminal.iterm.cliExecutableCandidates.isEmpty)
        XCTAssertTrue(Terminal.terminal.cliExecutableCandidates.isEmpty)
        XCTAssertTrue(Terminal.alacritty.cliExecutableCandidates.isEmpty)
        XCTAssertFalse(Terminal.wezterm.cliExecutableCandidates.isEmpty)
        XCTAssertFalse(Terminal.kitty.cliExecutableCandidates.isEmpty)
    }

    func test_id_equalsRawValue() {
        for terminal in Terminal.allCases {
            XCTAssertEqual(terminal.id, terminal.rawValue)
        }
    }

    // MARK: - Installation detection with a stub probe

    /// Always returns false — simulates a mac with no extra terminals installed.
    private struct EmptyProbe: TerminalInstallationProbe {
        func isAppInstalled(bundleID: String) -> Bool { false }
        func isCLIAvailable(paths: [String]) -> Bool { false }
    }

    func test_installed_alwaysIncludesTerminalAppOnMacOS() {
        // Even with nothing detected, Terminal.app ships with macOS.
        let installed = Terminal.installed(probe: EmptyProbe())
        XCTAssertTrue(installed.contains(.terminal))
    }

    func test_installed_withDefaultProbe_includesTerminalApp() {
        // Smoke test against the real system — Terminal.app always exists.
        let installed = Terminal.installed()
        XCTAssertTrue(installed.contains(.terminal), "macOS always ships with Terminal.app")
    }

    /// Probe that flags Ghostty + Alacritty as installed and wezterm CLI present.
    private struct ScriptedProbe: TerminalInstallationProbe {
        let installedBundleIDs: Set<String>
        let availableCLIPaths: Set<String>
        func isAppInstalled(bundleID: String) -> Bool {
            installedBundleIDs.contains(bundleID)
        }
        func isCLIAvailable(paths: [String]) -> Bool {
            paths.contains { availableCLIPaths.contains($0) }
        }
    }

    func test_installed_detectsGhosttyAlacrittyAndWezterm_viaStub() {
        let probe = ScriptedProbe(
            installedBundleIDs: [
                Terminal.ghostty.bundleID!,
                Terminal.alacritty.bundleID!,
            ],
            availableCLIPaths: ["/opt/homebrew/bin/wezterm"]
        )
        let installed = Set(Terminal.installed(probe: probe))
        XCTAssertTrue(installed.contains(.ghostty))
        XCTAssertTrue(installed.contains(.alacritty))
        XCTAssertTrue(installed.contains(.wezterm))
        XCTAssertTrue(installed.contains(.terminal)) // always
        XCTAssertFalse(installed.contains(.iterm))
        XCTAssertFalse(installed.contains(.kitty))
    }

    func test_installed_kittyViaCliPath() {
        let probe = ScriptedProbe(
            installedBundleIDs: [],
            availableCLIPaths: ["/Applications/kitty.app/Contents/MacOS/kitty"]
        )
        XCTAssertTrue(Terminal.installed(probe: probe).contains(.kitty))
    }

    func test_installed_kittyViaBundleID_whenCliMissing() {
        let probe = ScriptedProbe(
            installedBundleIDs: [Terminal.kitty.bundleID!],
            availableCLIPaths: []
        )
        XCTAssertTrue(Terminal.installed(probe: probe).contains(.kitty))
    }
}
