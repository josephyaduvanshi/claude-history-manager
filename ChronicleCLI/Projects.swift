import Foundation

/// On-disk root containing per-workspace folders, e.g. ~/.claude/projects.
struct ProjectsRoot {
    let url: URL
    let fm = FileManager.default

    init(url: URL) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else {
            throw CLIError.badRoot(url.path)
        }
        self.url = url
    }

    /// Returns every immediate subdirectory of `url`. Each is a workspace.
    func workspaces() throws -> [Workspace] {
        let entries = try fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map { Workspace(url: $0) }
            .sorted { $0.folderName < $1.folderName }
    }

    /// Resolve a user-supplied workspace identifier to a Workspace. Accepts
    /// the on-disk folder name (`-Users-foo-bar`) or a decoded path
    /// (`/Users/foo/bar`); for paths we match against each workspace's
    /// canonical cwd (read from the first jsonl that has one) so paths
    /// containing hyphens still resolve correctly.
    func resolveWorkspace(_ identifier: String) throws -> Workspace {
        let all = try workspaces()
        // 1. Exact folder-name match.
        if let direct = all.first(where: { $0.folderName == identifier }) {
            return direct
        }
        // 2. Decoded-path match (against each workspace's canonical cwd).
        let target = (identifier as NSString).expandingTildeInPath
        for ws in all {
            if let cwd = ws.canonicalCwd(), cwd == target { return ws }
        }
        // 3. Suffix match on folder name (so "claude-history-manager" finds
        //    "-Users-josephyaduvanshi-Code-swift-apps-claude-history-manager").
        if let suffix = all.first(where: { $0.folderName.hasSuffix("-" + identifier) || $0.folderName == "-" + identifier }) {
            return suffix
        }
        throw CLIError.notFound("workspace \(identifier)")
    }

    /// Best-effort match for "the workspace this shell is sitting in" — used
    /// when `chronicle sessions` is invoked with no `-w`. Compares each
    /// workspace's canonical cwd against $PWD.
    func workspaceMatchingCwd() throws -> Workspace? {
        let cwd = fm.currentDirectoryPath
        let all = try workspaces()
        return all.first { $0.canonicalCwd() == cwd }
    }
}

/// One workspace directory, e.g. ~/.claude/projects/-Users-foo-bar/.
struct Workspace {
    let url: URL

    var folderName: String { url.lastPathComponent }

    /// Decoded path if the folder name encodes one (replace `-` → `/`).
    /// Lossy: paths whose components themselves contain `-` cannot be
    /// recovered from the folder name alone. Use `canonicalCwd()` for an
    /// authoritative answer.
    var decodedNameAsPath: String {
        if folderName.hasPrefix("-") {
            return "/" + folderName.dropFirst().replacingOccurrences(of: "-", with: "/")
        }
        return folderName
    }

    /// `cwd` field from the first jsonl line that has one. Authoritative
    /// answer for "what directory does this workspace correspond to."
    /// Cached lazily on the (immutable) Workspace lifetime would require
    /// reference semantics, so we just re-read on demand — this is rare.
    func canonicalCwd() -> String? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return nil }
        for file in files where file.pathExtension == "jsonl" {
            guard let h = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? h.close() }
            // Read up to 64 KB; the metadata is typically in the first few
            // lines so we don't need to slurp the whole file.
            guard let chunk = try? h.read(upToCount: 64 * 1024) else { continue }
            for line in chunk.split(separator: 0x0A) {
                if let cwd = JsonlLine.cwd(from: line), !cwd.isEmpty {
                    return cwd
                }
            }
        }
        return nil
    }

    /// Every `.jsonl` file in this workspace.
    func sessionFiles() throws -> [URL] {
        let files = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        )
        return files.filter { $0.pathExtension == "jsonl" }
    }
}
