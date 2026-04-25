import SwiftUI

/// Environment key for `EditorLauncher`. Wired from `ChronicleApp` so every
/// view that wants to offer "Open in X" can reach the shared launcher
/// without threading it through init parameters.
private struct EditorLauncherKey: EnvironmentKey {
    static let defaultValue: EditorLauncher = EditorLauncher()
}

public extension EnvironmentValues {
    var editorLauncher: EditorLauncher {
        get { self[EditorLauncherKey.self] }
        set { self[EditorLauncherKey.self] = newValue }
    }
}
