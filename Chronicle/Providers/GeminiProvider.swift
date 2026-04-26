import Foundation

/// Gemini CLI provider. Wires `GeminiParser`, `GeminiWatcher`, and
/// `GeminiResumeBuilder` into the multi-provider protocol.
///
/// Layout: Gemini stores sessions per-project under
/// `~/.gemini/tmp/<project_dir>/chats/session-*.json`. Older Gemini
/// builds named the project dir after the friendly project name
/// (e.g. `r2-gem`); newer builds use a SHA256 of the cwd. Both
/// coexist on long-running installs, so we don't assume a format.
///
/// Cwd recovery: `~/.gemini/projects.json` maps **cwd → friendly
/// name**, so for name-based dirs a reverse lookup recovers the cwd.
/// Hash-based dirs have no recovery — those sessions surface with a
/// nil cwd and the metadata pane shows "—".
public struct GeminiProvider: Provider {
    public static let id: ProviderID = .gemini
    public let displayName = "Gemini"
    public let iconAssetName = "gemini"

    public init() {}

    public func isAvailable() -> Bool {
        // Two signals: tmp dir exists with at least one project subdir
        // AND projects.json exists. Without projects.json we'd surface
        // sessions with no cwd at all, which is a poor first impression.
        let tmp = Self.tmpRoot()
        let projects = Self.projectsFile()
        guard FileManager.default.fileExists(atPath: tmp.path),
              FileManager.default.fileExists(atPath: projects.path) else {
            return false
        }
        // At least one project dir with at least one session file.
        return Self.discoverProjectDirs().contains { dir in
            let chats = dir.appendingPathComponent("chats", isDirectory: true)
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: chats,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { return false }
            return files.contains(where: { $0.lastPathComponent.hasPrefix("session-") })
        }
    }

    public func watchRoots() -> [URL] {
        // One watch per project's `chats/` dir. The Watcher itself
        // tops this list off at 32 most-recently-modified projects.
        Self.discoverProjectDirs()
            .map { $0.appendingPathComponent("chats", isDirectory: true) }
    }

    public func makeParser() -> any SessionParser { GeminiParser() }

    public func resumeCommand(
        sessionID: String,
        cwd: String,
        terminal: Terminal,
        loginShell: String
    ) -> LaunchCommand {
        GeminiResumeBuilder(loginShell: loginShell)
            .build(terminal: terminal, sessionID: sessionID, cwd: cwd)
    }

    // MARK: - Path helpers

    public static func tmpRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/tmp", isDirectory: true)
    }

    public static func projectsFile() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/projects.json", isDirectory: false)
    }

    /// All project subdirs under `~/.gemini/tmp/`, regardless of
    /// whether they're hash-named or friendly-named.
    public static func discoverProjectDirs() -> [URL] {
        let tmp = tmpRoot()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: tmp,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
    }

    /// Reverse lookup from project dir name → cwd, via projects.json.
    /// Returns nil for hash-named dirs that don't appear as a value
    /// in the projects map. Reads + parses projects.json on each
    /// call; the file is small and read frequency is bounded by
    /// bootstrap and switch-provider events.
    public static func cwd(forProjectDirName name: String) -> String? {
        let url = projectsFile()
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = raw["projects"] as? [String: String] else {
            return nil
        }
        // Reverse: find the cwd whose friendly name matches the dir.
        for (cwd, friendly) in projects where friendly == name {
            return cwd
        }
        return nil
    }
}
