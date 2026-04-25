import SwiftUI

// MARK: - Environment keys for launcher + preference

/// Wires `SessionLauncher` into any view via `@Environment(\.sessionLauncher)`.
///
/// AppView injects the production launcher at the root of the scene so deeper
/// views (PreviewView's action bar in particular) don't need to receive it
/// through init parameters.
private struct SessionLauncherKey: EnvironmentKey {
    static let defaultValue: any SessionLauncherProtocol = SessionLauncher()
}

/// Wires `TerminalPreference` into any view via `@Environment(\.terminalPreference)`.
private struct TerminalPreferenceKey: EnvironmentKey {
    /// Nil means "no preference wiring was set up", views should no-op rather
    /// than crash. AppView always injects a real preference in production.
    static let defaultValue: TerminalPreference? = nil
}

/// Wires the `SessionsRepositoryProtocol` into a view tree so the menubar
/// (which doesn't know about AppState) can refresh its live/recent sections
/// and run searches.
private struct SessionsRepositoryKey: EnvironmentKey {
    static let defaultValue: (any SessionsRepositoryProtocol)? = nil
}

public extension EnvironmentValues {
    var sessionLauncher: any SessionLauncherProtocol {
        get { self[SessionLauncherKey.self] }
        set { self[SessionLauncherKey.self] = newValue }
    }

    var terminalPreference: TerminalPreference? {
        get { self[TerminalPreferenceKey.self] }
        set { self[TerminalPreferenceKey.self] = newValue }
    }

    var sessionsRepository: (any SessionsRepositoryProtocol)? {
        get { self[SessionsRepositoryKey.self] }
        set { self[SessionsRepositoryKey.self] = newValue }
    }
}
