import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Owns the app-global shortcuts Plan 04 promises:
///
///   - `⌘⇧O` , toggle the menubar dropdown open/focused.
///   - `⌘⇧⏎`, resume the most-recently-modified session in the default terminal.
///
/// Instantiated lazily in `ChronicleApp` once the repository + launcher are
/// ready; the GlobalHotkey references are retained for the lifetime of the
/// app. Failures to register (Carbon returns non-zero OSStatus) are
/// swallowed and forwarded via `onRegistrationError` so the app doesn't
/// crash on startup if another app already owns the same shortcut.
@MainActor
public final class MenubarHotkeys {
    // MARK: - Collaborators

    private let repository: any SessionsRepositoryProtocol
    private let launcher: any SessionLauncherProtocol
    private let onToggleMenubar: () -> Void
    private let onError: (String) -> Void

    // MARK: - State

    private var toggleHotkey: GlobalHotkey?
    private var resumeHotkey: GlobalHotkey?

    // MARK: - Init

    public init(
        repository: any SessionsRepositoryProtocol,
        launcher: any SessionLauncherProtocol,
        onToggleMenubar: @escaping () -> Void,
        onError: @escaping (String) -> Void = { _ in }
    ) {
        self.repository = repository
        self.launcher = launcher
        self.onToggleMenubar = onToggleMenubar
        self.onError = onError
    }

    // MARK: - Registration

    public func registerAll() {
        registerToggle()
        registerResume()
    }

    public func unregisterAll() {
        try? toggleHotkey?.unregister()
        try? resumeHotkey?.unregister()
        toggleHotkey = nil
        resumeHotkey = nil
    }

    private func registerToggle() {
        let onToggle = onToggleMenubar
        let hk = GlobalHotkey(
            key: .o,
            modifiers: [.command, .shift]
        ) {
            // The Carbon callback fires on an arbitrary thread; bounce to
            // the main actor so SwiftUI state mutations stay legal.
            Task { @MainActor in onToggle() }
        }
        do {
            try hk.register()
            toggleHotkey = hk
        } catch {
            onError("⌘⇧O registration failed: \(error.localizedDescription)")
        }
    }

    private func registerResume() {
        let repo = repository
        let launcher = launcher
        let onError = onError
        let hk = GlobalHotkey(
            key: .returnKey,
            modifiers: [.command, .shift]
        ) {
            Task { @MainActor in
                await Self.resumeLastSession(
                    repository: repo,
                    launcher: launcher,
                    onError: onError
                )
            }
        }
        do {
            try hk.register()
            resumeHotkey = hk
        } catch {
            onError("⌘⇧⏎ registration failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Actions

    /// Finds the most-recently-modified session + its workspace, resolves
    /// the user's default terminal, and hands off to `SessionLauncher`.
    /// Exposed `internal` so tests can exercise the decision logic without
    /// going through Carbon.
    internal static func resumeLastSession(
        repository: any SessionsRepositoryProtocol,
        launcher: any SessionLauncherProtocol,
        terminalPreference: TerminalPreference? = nil,
        onError: @escaping (String) -> Void
    ) async {
        do {
            let sessions = try await repository.allSessions(limit: 1)
            guard let last = sessions.first else {
                onError("No sessions available to resume.")
                return
            }
            let workspaces = try await repository.allWorkspaces()
            guard let workspace = workspaces.first(where: { $0.id == last.workspaceID }) else {
                onError("Could not find workspace for most-recent session.")
                return
            }
            let terminal: Terminal
            if let pref = terminalPreference {
                terminal = await pref.defaultTerminal()
            } else {
                terminal = .terminal
            }
            try await launcher.launch(
                terminal: terminal,
                sessionID: last.sessionID.rawValue.uuidString.lowercased(),
                workingDirectory: workspace.decodedPath
            )
        } catch {
            onError("Resume-last failed: \(error.localizedDescription)")
        }
    }
}

#if canImport(AppKit)

/// Best-effort helper to simulate a click on Chronicle's menubar status
/// button so `⌘⇧O` can open the dropdown. SwiftUI's MenuBarExtra (with
/// `.window` style) exposes its NSStatusItem via the app's windows as an
/// `NSStatusBarWindow`; we find it, ask its button to `performClick`, and
/// hope AppKit routes the open through the normal MenuBarExtra plumbing.
///
/// If macOS changes this internal arrangement in a later OS version, we
/// fall back to toggling `isInserted` on the scene; which causes a brief
/// "menubar icon flickers off/on" visual bug but at least delivers the
/// keyboard shortcut.
public enum MenubarExtraOpener {

    /// Try to open the menubar popover programmatically. Returns true if we
    /// found and clicked a status button; false otherwise.
    @MainActor
    @discardableResult
    public static func openProgrammatically() -> Bool {
        NSApp.activate(ignoringOtherApps: true)

        // NSStatusBarButton lives inside the NSStatusBarWindow that
        // MenuBarExtra's .window style spawns. Walk NSApp.windows to find it.
        for window in NSApp.windows {
            // The private "NSStatusBarWindow" class; we only care that its
            // class name matches so we don't hard-link against private API.
            let className = String(describing: type(of: window))
            guard className.contains("StatusBar") || className.contains("MenuBarExtra") else { continue }
            if let button = window.value(forKey: "statusItem") as? NSStatusItem {
                button.button?.performClick(nil)
                return true
            }
            // Fallback: try the content view's first button descendant.
            if let click = firstButton(in: window.contentView) {
                click.performClick(nil)
                return true
            }
        }
        return false
    }

    /// DFS for the first NSButton inside a view hierarchy, or nil.
    private static func firstButton(in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let btn = view as? NSButton { return btn }
        for sub in view.subviews {
            if let found = firstButton(in: sub) { return found }
        }
        return nil
    }
}

#else

public enum MenubarExtraOpener {
    @MainActor
    @discardableResult
    public static func openProgrammatically() -> Bool { false }
}

#endif
