import Foundation
import AppKit

// MARK: - Editor

/// External editors Chronicle knows how to open a project path in. Each case
/// carries an Apple bundle identifier (preferred) and a CLI fallback that
/// ships on the user's `PATH` when the `.app` isn't installed.
public enum Editor: String, CaseIterable, Sendable, Codable, Identifiable {
    case cursor
    case vscode
    case zed

    public var id: String { rawValue }

    /// Human-facing name; matches the literal `.app` bundle name too.
    public var displayName: String {
        switch self {
        case .cursor: return "Cursor"
        case .vscode: return "Visual Studio Code"
        case .zed:    return "Zed"
        }
    }

    /// CFBundleIdentifier of the installed `.app`. Used for
    /// `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)`.
    public var bundleID: String {
        switch self {
        case .cursor: return "com.todesktop.230313mzl4w4u92"       // Cursor
        case .vscode: return "com.microsoft.VSCode"
        case .zed:    return "dev.zed.Zed"
        }
    }

    /// Shell-installable CLI shim. Used when the `.app` isn't found.
    public var fallbackCLI: String {
        switch self {
        case .cursor: return "cursor"
        case .vscode: return "code"
        case .zed:    return "zed"
        }
    }
}

// MARK: - EditorLauncher

public enum EditorLauncherError: Error, LocalizedError, Equatable {
    case notInstalled(Editor)

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let e):
            return """
                \(e.displayName) isn't installed. Install the desktop \
                app or its CLI shim (`\(e.fallbackCLI)`) and try again.
                """
        }
    }
}

/// A materialized command describing how to open `path` in `editor`. Either
/// `useOpenApp == true` (pass to `/usr/bin/open -a "<AppName>" <path>`) or
/// `executable` points at a resolved CLI shim like `/usr/local/bin/cursor`.
public struct EditorLaunchCommand: Equatable, Sendable {
    public let editor: Editor
    public let useOpenApp: Bool
    public let executable: String
    public let arguments: [String]

    public init(editor: Editor,
                useOpenApp: Bool,
                executable: String,
                arguments: [String]) {
        self.editor = editor
        self.useOpenApp = useOpenApp
        self.executable = executable
        self.arguments = arguments
    }
}

/// Pure launcher: resolves the `.app` bundle or CLI shim for a given Editor
/// and spawns `/usr/bin/open -a "<App>" <path>` or the CLI directly. Built
/// on top of the same `ProcessRunner` the terminal launcher uses.
public struct EditorLauncher: Sendable {
    private let processRunner: any ProcessRunner

    /// Callback Chronicle injects at test time to fake `.app` presence and
    /// CLI-on-PATH discovery. Defaults use real Launch Services + disk scan.
    public var isAppInstalled: @Sendable (Editor) -> Bool = Self.defaultIsAppInstalled
    public var cliPath: @Sendable (Editor) -> String? = Self.defaultCLIPath

    public init(
        processRunner: any ProcessRunner = DefaultProcessRunner.default,
        isAppInstalled: (@Sendable (Editor) -> Bool)? = nil,
        cliPath: (@Sendable (Editor) -> String?)? = nil
    ) {
        self.processRunner = processRunner
        if let isAppInstalled { self.isAppInstalled = isAppInstalled }
        if let cliPath { self.cliPath = cliPath }
    }

    // MARK: - Command builder (pure, for snapshot tests)

    /// Builds the `EditorLaunchCommand` for `editor` + `path` using the
    /// resolvers installed at init time. Snapshot-style tests drive this
    /// without any disk IO.
    public func buildCommand(editor: Editor, path: String) -> EditorLaunchCommand {
        if isAppInstalled(editor) {
            return EditorLaunchCommand(
                editor: editor,
                useOpenApp: true,
                executable: "/usr/bin/open",
                arguments: ["-a", editor.displayName, path]
            )
        }
        if let cli = cliPath(editor) {
            return EditorLaunchCommand(
                editor: editor,
                useOpenApp: false,
                executable: cli,
                arguments: [path]
            )
        }
        // Neither resolver returned a path. Return a placeholder command that
        // callers can surface as a user-visible error rather than spawn.
        return EditorLaunchCommand(
            editor: editor,
            useOpenApp: false,
            executable: editor.fallbackCLI,
            arguments: [path]
        )
    }

    // MARK: - Dispatch

    /// Opens `path` in `editor`. Throws `EditorLauncherError.notInstalled`
    /// when neither the `.app` nor the CLI shim resolves.
    public func open(editor: Editor, path: String) async throws {
        if isAppInstalled(editor) {
            AppLogger.launch.info("opening \(path) in \(editor.displayName) via -a")
            try await processRunner.run(
                executable: "/usr/bin/open",
                arguments: ["-a", editor.displayName, path]
            )
            return
        }
        if let cli = cliPath(editor) {
            AppLogger.launch.info("opening \(path) in \(editor.displayName) via CLI \(cli)")
            try await processRunner.run(executable: cli, arguments: [path])
            return
        }
        AppLogger.launch.warn("\(editor.displayName) not installed")
        throw EditorLauncherError.notInstalled(editor)
    }

    // MARK: - Default resolvers

    private static let defaultIsAppInstalled: @Sendable (Editor) -> Bool = { editor in
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.bundleID) != nil
    }

    private static let defaultCLIPath: @Sendable (Editor) -> String? = { editor in
        let searchPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ]
        let fm = FileManager.default
        for dir in searchPaths {
            let candidate = "\(dir)/\(editor.fallbackCLI)"
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}

// MARK: - Preference storage

/// Which editor Chronicle should offer as the "Open in X" button. Nil means
/// the Settings toggle is set to "None", hide the button.
public enum EditorPreference {
    public static let defaultsKey = "chronicle.defaultEditor"

    public static func load(from defaults: UserDefaults = .standard) -> Editor? {
        guard let raw = defaults.string(forKey: defaultsKey),
              let editor = Editor(rawValue: raw) else { return nil }
        return editor
    }

    public static func save(_ editor: Editor?, to defaults: UserDefaults = .standard) {
        if let editor {
            defaults.set(editor.rawValue, forKey: defaultsKey)
        } else {
            defaults.removeObject(forKey: defaultsKey)
        }
    }
}
