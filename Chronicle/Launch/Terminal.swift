import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// The set of terminal emulators Chronicle can launch a `claude --resume` session in.
///
/// Adding a new terminal means updating this enum + the metadata below + the
/// `SessionLauncher.buildCommand` switch + a snapshot test.
public enum Terminal: String, CaseIterable, Identifiable, Codable, Sendable {
    case ghostty
    case iterm
    case terminal
    case alacritty
    case wezterm
    case kitty

    public var id: String { rawValue }

    /// Human-readable label shown in the UI.
    public var displayName: String {
        switch self {
        case .ghostty:   return "Ghostty"
        case .iterm:     return "iTerm"
        case .terminal:  return "Terminal"
        case .alacritty: return "Alacritty"
        case .wezterm:   return "WezTerm"
        case .kitty:     return "kitty"
        }
    }

    /// Bundle identifier for `.app`-based terminals.
    /// `nil` for purely CLI-launched terminals (wezterm / kitty).
    public var bundleID: String? {
        switch self {
        case .ghostty:   return "com.mitchellh.ghostty"
        case .iterm:     return "com.googlecode.iterm2"
        case .terminal:  return "com.apple.Terminal"
        case .alacritty: return "org.alacritty"
        case .wezterm:   return "com.github.wez.wezterm"
        case .kitty:     return "net.kovidgoyal.kitty"
        }
    }

    /// Default paths at which a CLI executable might live. Checked in order.
    /// `nil` / `[]` for terminals launched via `open -na <App>`.
    public var cliExecutableCandidates: [String] {
        switch self {
        case .wezterm:
            return [
                "/opt/homebrew/bin/wezterm",
                "/usr/local/bin/wezterm",
                "/Applications/WezTerm.app/Contents/MacOS/wezterm",
            ]
        case .kitty:
            return [
                "/Applications/kitty.app/Contents/MacOS/kitty",
                "/opt/homebrew/bin/kitty",
                "/usr/local/bin/kitty",
            ]
        default:
            return []
        }
    }

    /// Returns the first existing CLI executable path, or `nil` if none is installed.
    /// Used by SessionLauncher to resolve the actual exec path at launch time.
    public func cliExecutable(using fm: FileManager = .default) -> String? {
        for path in cliExecutableCandidates where fm.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }
}

// MARK: - Installation detection

/// Small abstraction over AppKit's `NSWorkspace.urlForApplication(withBundleIdentifier:)`
/// so tests can stub terminal detection without touching the real system.
public protocol TerminalInstallationProbe: Sendable {
    /// True if the `.app` with the given bundle ID is installed on this machine.
    func isAppInstalled(bundleID: String) -> Bool
    /// True if a CLI executable exists at one of `paths`.
    func isCLIAvailable(paths: [String]) -> Bool
}

/// Default probe that actually consults NSWorkspace + FileManager.
public struct DefaultTerminalInstallationProbe: TerminalInstallationProbe {
    public init() {}

    public func isAppInstalled(bundleID: String) -> Bool {
        #if canImport(AppKit)
        // `urlForApplication(withBundleIdentifier:)` is the LSCopyApplicationURL
        // modern replacement. Returns nil if the app isn't registered.
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
        #else
        return false
        #endif
    }

    public func isCLIAvailable(paths: [String]) -> Bool {
        let fm = FileManager.default
        return paths.contains { fm.isExecutableFile(atPath: $0) }
    }
}

public extension Terminal {
    /// Returns the list of terminals that appear to be installed on this machine.
    /// - For `.app`-based terminals, consults the `probe` for a registered bundle ID.
    /// - For CLI-based terminals, consults the `probe` for a known executable path.
    /// - `Terminal.terminal` (macOS `Terminal.app`) is always included; it ships with macOS.
    ///
    /// Tests inject a stubbed probe; production code uses `DefaultTerminalInstallationProbe()`.
    static func installed(
        probe: any TerminalInstallationProbe = DefaultTerminalInstallationProbe()
    ) -> [Terminal] {
        var out: [Terminal] = []
        for terminal in Terminal.allCases {
            if terminal == .terminal {
                out.append(terminal) // always shipped with macOS
                continue
            }

            switch terminal {
            case .wezterm, .kitty:
                // Prefer CLI presence, but an installed .app is also acceptable
                // (we'll resolve the exec path at launch time).
                if probe.isCLIAvailable(paths: terminal.cliExecutableCandidates) {
                    out.append(terminal)
                } else if let bid = terminal.bundleID, probe.isAppInstalled(bundleID: bid) {
                    out.append(terminal)
                }
            default:
                if let bid = terminal.bundleID, probe.isAppInstalled(bundleID: bid) {
                    out.append(terminal)
                }
            }
        }
        return out
    }
}
