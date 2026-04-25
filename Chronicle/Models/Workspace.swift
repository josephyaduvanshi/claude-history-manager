import Foundation

/// A logical workspace = one folder under `~/.claude/projects/`.
/// `id` is the encoded folder name; `decodedPath` is the real filesystem path.
public struct Workspace: Hashable, Equatable, Codable, Sendable, Identifiable {
    public let id: String                // encoded folder name (used as DB key)
    public let decodedPath: String       // /Users/.../Code/flutter/apps/aayo (best-effort decoded)
    public let group: String             // "flutter", "security", "ai/claude", "work", etc.
    public let displayName: String       // "flutter / apps / aayo"

    /// Authoritative cwd extracted from inside the session jsonl files for this
    /// workspace. The dash-decoded `decodedPath` is lossy (any `/`, ` `, `_`,
    /// `-`, `.` in the original cwd collapses to `-` in the folder name) so we
    /// peek at the first few jsonl lines and pull `cwd` directly. When this is
    /// non-nil the launcher uses it instead of `decodedPath`. Nil when no jsonl
    /// in the workspace contained a `cwd` field.
    public let cwd: String?

    /// `gitBranch` field captured from the same jsonl line as `cwd`. Nil if
    /// the session wasn't in a git repo (or the parser hasn't seen it yet).
    public let gitBranch: String?

    /// Claude Code version from the same line. Useful for the preview pane , 
    /// e.g. "claude 2.1.91", and for diagnostics. Nil when missing.
    public let claudeVersion: String?

    public init(
        id: String,
        decodedPath: String,
        group: String,
        displayName: String,
        cwd: String? = nil,
        gitBranch: String? = nil,
        claudeVersion: String? = nil
    ) {
        self.id = id
        self.decodedPath = decodedPath
        self.group = group
        self.displayName = displayName
        self.cwd = cwd
        self.gitBranch = gitBranch
        self.claudeVersion = claudeVersion
    }

    /// The path the launcher should `cd` into before invoking
    /// `claude --resume`. Prefers the authoritative `cwd` extracted from
    /// jsonl, falls back to the lossy dash-decoded path.
    public var resumeCWD: String {
        cwd ?? decodedPath
    }

    /// Path components derived from `decodedPath` ,  `/Users/me/Desktop/Foo/Bar`
    /// becomes `["Users", "me", "Desktop", "Foo", "Bar"]`. Skips empty
    /// segments so leading/trailing slashes don't pollute the array.
    public var pathComponents: [String] {
        decodedPath.split(separator: "/").map(String.init)
    }

    /// Compact sidebar label; last 2 path components, joined by " / ",
    /// truncated to 32 chars. Falls back to displayName if the path is too
    /// short to derive a pair.
    public var shortName: String {
        let comps = pathComponents
        let pair: String
        if comps.count >= 2 {
            pair = comps[(comps.count - 2)..<comps.count].joined(separator: " / ")
        } else if let last = comps.last {
            pair = last
        } else {
            pair = displayName
        }
        // Truncate from the end if too long; keep the workspace name
        // (the last component) intact by leaning into middle-truncation.
        let maxLen = 32
        if pair.count <= maxLen { return pair }
        // Favor the final component, truncate the prefix.
        let dropN = pair.count - maxLen + 1  // +1 for ellipsis
        let startIdx = pair.index(pair.startIndex, offsetBy: dropN)
        return "…" + String(pair[startIdx...])
    }

    /// Name of the parent directory; the second-to-last path component.
    /// Used to roll up sibling workspaces in the sidebar ("StealthZero (6)").
    /// Falls back to `group` when the decoded path is too short.
    public var parentGroup: String {
        let comps = pathComponents
        guard comps.count >= 2 else { return group }
        return comps[comps.count - 2]
    }

    /// Last path component; the workspace's actual folder name.
    public var leafName: String {
        pathComponents.last ?? displayName
    }

    /// Coarse-grained category bucket used by the sidebar to group ~35
    /// workspaces into ~8 colored buckets ("FLUTTER", "SECURITY", etc.).
    ///
    /// Pure metadata; derived from `decodedPath` segments, the workspace
    /// name (`leafName` / `parentGroup`), and `displayName`. No filesystem
    /// I/O so the result is instant and deterministic.
    public var category: WorkspaceCategory {
        WorkspaceCategory.derive(for: self)
    }
}

/// One of ~8 colored buckets the sidebar groups workspaces into. Derivation
/// is path/name-string based; see `derive(for:)`. New buckets should be
/// added sparingly; the visual budget for the sidebar is roughly 8 colors.
public enum WorkspaceCategory: String, CaseIterable, Hashable, Sendable {
    case flutter
    case security
    case aiClaude
    case work
    case rust
    case go
    case python
    case web
    case other

    /// Uppercase label rendered in the sidebar bucket header.
    public var displayLabel: String {
        switch self {
        case .flutter:  return "FLUTTER"
        case .security: return "SECURITY"
        case .aiClaude: return "AI / CLAUDE"
        case .work:     return "WORK"
        case .rust:     return "RUST"
        case .go:       return "GO"
        case .python:   return "PYTHON"
        case .web:      return "WEB"
        case .other:    return "OTHER"
        }
    }

    /// Stable string key for `AppState.expandedWorkspaceGroups`. Prefixed
    /// so it can't collide with the legacy parent-group keys (which were
    /// raw directory names without the `cat:` prefix).
    public var expansionKey: String {
        "cat:" + rawValue
    }

    /// Render order in the sidebar; categories with more "signal" come
    /// first, `other` always trails. Stable so the sidebar doesn't reflow
    /// when the workspace list mutates.
    public var sortIndex: Int {
        switch self {
        case .aiClaude: return 0
        case .flutter:  return 1
        case .web:      return 2
        case .security: return 3
        case .rust:     return 4
        case .go:       return 5
        case .python:   return 6
        case .work:     return 7
        case .other:    return 8
        }
    }

    /// Pure metadata derivation; no filesystem reads. Inspects the
    /// workspace's decoded path components, leaf folder name, and parent
    /// directory name; first heuristic to fire wins. The order of checks
    /// matters: more specific buckets (rust, flutter, go) are tested
    /// before broader catch-alls (work, web).
    ///
    /// Heuristic uses ONLY universally-meaningful tokens (programming
    /// languages, common ecosystem names, generic domain words); not
    /// project-specific names. This makes the bucketing useful for any
    /// open-source user, not just one developer's workspace layout.
    public static func derive(for workspace: Workspace) -> WorkspaceCategory {
        let comps = workspace.pathComponents.map { $0.lowercased() }
        let leaf = workspace.leafName.lowercased()
        let parent = workspace.parentGroup.lowercased()
        let display = workspace.displayName.lowercased()
        let segs = Set(comps)
        let nameHits = segs.union([leaf, parent])
            .union(display.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) })

        func segContains(_ tokens: Set<String>) -> Bool {
            !nameHits.isDisjoint(with: tokens)
        }
        func leafOrParentContains(_ needle: String) -> Bool {
            leaf.contains(needle) || parent.contains(needle)
        }

        // --- AI / LLM-related work ---
        let aiTokens: Set<String> = [
            "claude", "anthropic", "openai", "gpt", "chatgpt",
            "gemini", "ollama", "mistral", "llama", "llm",
            "ai", "ml", "agent", "agents", "rag", "embeddings",
            "langchain", "llamaindex", "huggingface",
        ]
        if segContains(aiTokens) { return .aiClaude }
        if leafOrParentContains("claude") || leafOrParentContains("agent") { return .aiClaude }

        // --- Security / auth ---
        let securityTokens: Set<String> = [
            "security", "auth", "oauth", "oidc", "sso",
            "vault", "secrets", "secret", "password", "passwords",
            "crypto", "cryptography", "tls", "ssl", "pki",
            "pentest", "exploit", "exploits", "ctf", "infosec",
        ]
        if segContains(securityTokens) { return .security }

        // --- Rust ---
        if segs.contains("rust") || leafOrParentContains("rust") { return .rust }
        if segs.contains("cargo") || segs.contains(".cargo") { return .rust }

        // --- Go ---
        if segs.contains("go") || leaf == "go" || parent == "go" { return .go }
        if segs.contains("golang") { return .go }

        // --- Flutter / Dart ---
        if segs.contains("flutter") || leafOrParentContains("flutter") { return .flutter }
        if segs.contains("dart") { return .flutter }

        // --- Python ---
        if segs.contains("python") || leafOrParentContains("python") { return .python }
        if segs.contains("py") || leaf.hasSuffix("-py") || leaf.hasSuffix("_py") { return .python }
        let pythonEcosystem: Set<String> = [
            "django", "flask", "fastapi", "pytorch", "tensorflow",
            "jupyter", "notebook", "notebooks", "pandas", "numpy",
        ]
        if segContains(pythonEcosystem) { return .python }

        // --- Web / frontend ---
        let webTokens: Set<String> = [
            "web", "frontend", "front-end", "front_end",
            "next", "nextjs", "nuxt", "astro",
            "react", "vue", "svelte", "sveltekit", "solid",
            "site", "website", "landing", "blog", "docs",
            "html", "css", "tailwind", "ts", "typescript", "js", "javascript", "node", "nodejs",
        ]
        if segContains(webTokens) { return .web }

        // --- Work / general projects / education ---
        let workTokens: Set<String> = [
            "work", "projects", "project", "desktop", "documents",
            "edu", "education", "school", "university", "course",
            "assignment", "homework", "playground", "scratch", "sandbox",
        ]
        if segContains(workTokens) { return .work }
        // EDUC#### / CS#### / MATH#### style course codes.
        let coursePattern = #/^[a-z]{2,5}\d{3,5}$/#
        if (try? coursePattern.wholeMatch(in: leaf)) != nil { return .work }
        if (try? coursePattern.wholeMatch(in: parent)) != nil { return .work }

        return .other
    }
}
