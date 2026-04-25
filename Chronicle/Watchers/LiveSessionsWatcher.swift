import Foundation

/// Abstraction over running a short-lived CLI command and capturing stdout.
/// Lets `LiveSessionsWatcher` be tested without actually spawning `ps` / `lsof`.
public protocol StdoutProcessRunner: Sendable {
    /// Runs `executable` with `arguments` and returns whatever it wrote to
    /// stdout, encoded as UTF-8. Empty string if the command produced no output.
    /// Throws if the process could not be spawned at all; non-zero exits are
    /// not errors (many `ps` / `lsof` invocations tolerate missing PIDs).
    func runCapturingStdout(executable: String, arguments: [String]) async throws -> String
}

/// Production implementation that actually forks a child process.
public struct DefaultStdoutProcessRunner: StdoutProcessRunner {
    public init() {}

    public func runCapturingStdout(executable: String,
                                   arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            do {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: executable)
                p.arguments = arguments
                let out = Pipe()
                let err = Pipe()
                p.standardOutput = out
                p.standardError = err
                try p.run()
                p.waitUntilExit()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                cont.resume(returning: text)
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}

/// Polls `ps` for running `claude` CLI processes and maps each one's
/// current-working-directory back to a Chronicle workspace. Overwrites
/// `SessionMetadata.isLive = true` on matches and pushes the list through
/// the caller's `onUpdate` handler.
public actor LiveSessionsWatcher {
    // MARK: - Public API

    public typealias UpdateHandler = @Sendable ([SessionMetadata]) async -> Void

    public init(repository: any SessionsRepositoryProtocol,
                runner: any StdoutProcessRunner = DefaultStdoutProcessRunner(),
                pollInterval: TimeInterval = 2.0,
                liveWindowSeconds: TimeInterval = 30.0) {
        self.repository = repository
        self.runner = runner
        self.pollInterval = pollInterval
        self.liveWindowSeconds = liveWindowSeconds
    }

    /// Start polling. Invokes the handler once per interval with the latest
    /// list of live sessions; delivers `[]` when nothing is running.
    public func start(onUpdate: @escaping UpdateHandler) async {
        guard pollTask == nil else { return }
        handler = onUpdate
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                let delay = await self?.pollInterval ?? 2.0
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    public func stop() async {
        pollTask?.cancel()
        pollTask = nil
        handler = nil
    }

    /// Exposed for tests: manually trigger one poll cycle.
    public func tickOnce() async -> [SessionMetadata] {
        await computeLiveSessions()
    }

    // MARK: - Internals

    private let repository: any SessionsRepositoryProtocol
    private let runner: any StdoutProcessRunner
    private let pollInterval: TimeInterval
    private let liveWindowSeconds: TimeInterval
    private var pollTask: Task<Void, Never>?
    private var handler: UpdateHandler?

    private func tick() async {
        let results = await computeLiveSessions()
        if let handler {
            await handler(results)
        }
    }

    private func computeLiveSessions() async -> [SessionMetadata] {
        // Step 1: run `ps` to get pid+args
        let psOutput: String
        do {
            psOutput = try await runner.runCapturingStdout(
                executable: "/bin/ps",
                arguments: ["-Awww", "-o", "pid=,args="]
            )
        } catch {
            return []
        }

        let pids = Self.parseClaudePIDs(psOutput: psOutput)
        guard !pids.isEmpty else { return [] }

        // Step 2: resolve each PID's CWD via lsof.
        var cwdsByPID: [Int: String] = [:]
        for pid in pids {
            do {
                let output = try await runner.runCapturingStdout(
                    executable: "/usr/sbin/lsof",
                    arguments: ["-p", String(pid), "-d", "cwd", "-Fn"]
                )
                if let cwd = Self.parseLsofCwd(output) {
                    cwdsByPID[pid] = cwd
                }
            } catch {
                continue
            }
        }
        guard !cwdsByPID.isEmpty else { return [] }

        // Step 3: fetch workspaces from repo and match each CWD → workspace by
        // longest-prefix on decodedPath.
        let workspaces: [Workspace] = (try? await repository.allWorkspaces()) ?? []
        guard !workspaces.isEmpty else { return [] }

        var matchedWSIDs: Set<String> = []
        for cwd in cwdsByPID.values {
            if let ws = Self.matchWorkspace(forCWD: cwd, in: workspaces) {
                matchedWSIDs.insert(ws.id)
            }
        }
        guard !matchedWSIDs.isEmpty else { return [] }

        // Step 4: for each matched workspace, fetch sessions whose
        // lastModifiedAt is within `liveWindowSeconds`. Overwrite isLive.
        let cutoff = Date().addingTimeInterval(-liveWindowSeconds)
        var live: [SessionMetadata] = []
        for wsID in matchedWSIDs {
            let rows = (try? await repository.sessions(inWorkspaceID: wsID)) ?? []
            for s in rows where s.lastModifiedAt >= cutoff {
                live.append(SessionMetadata(
                    sessionID: s.sessionID,
                    workspaceID: s.workspaceID,
                    title: s.title,
                    createdAt: s.createdAt,
                    lastModifiedAt: s.lastModifiedAt,
                    messageCount: s.messageCount,
                    tokenCount: s.tokenCount,
                    isLive: true
                ))
            }
        }
        // Most recent first; makes the sidebar render stable.
        live.sort { $0.lastModifiedAt > $1.lastModifiedAt }
        return live
    }

    // MARK: - Parsers (pure functions, exposed for tests)

    /// Walks `ps -Awww -o pid=,args=` output and returns PIDs whose command
    /// line looks like a `claude` CLI invocation. Matches:
    ///   - first token equals "claude"
    ///   - first token basename equals "claude"
    ///   - any token equals "claude" when previous token is `--resume`'s parent shell
    ///   - argline contains "claude " or ends with "claude"
    /// Deliberately lenient; false positives are fine (we filter later by
    /// workspace match); false negatives would hide the live indicator.
    static func parseClaudePIDs(psOutput: String) -> [Int] {
        var out: [Int] = []
        for rawLine in psOutput.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            // Split off PID and the rest.
            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2, let pid = Int(parts[0]) else { continue }
            let args = String(parts[1])
            if Self.argsLineLooksLikeClaudeCLI(args) {
                out.append(pid)
            }
        }
        return out
    }

    static func argsLineLooksLikeClaudeCLI(_ args: String) -> Bool {
        // Fast path: exact program name match.
        if args.hasPrefix("claude ") || args == "claude" { return true }
        // node wrappers / relative paths.
        let tokens = args.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = tokens.first else { return false }
        let firstBase = (first as NSString).lastPathComponent
        if firstBase == "claude" { return true }

        // Programs that wrap the CLI (node, bun, tsx, etc.); the second
        // token often is the `claude` entrypoint.
        if ["node", "bun", "tsx", "npx"].contains(firstBase) {
            if tokens.count > 1 {
                let second = (tokens[1] as NSString).lastPathComponent
                if second == "claude" || second == "claude.js" { return true }
            }
        }

        // Last-ditch: `--resume ` appears with a UUID-looking value somewhere.
        if args.contains("claude") && args.contains("--resume ") {
            return true
        }
        return false
    }

    /// Parses `lsof -p <pid> -d cwd -Fn` output for the `n<cwd>` line. The
    /// `-F` flag produces field-per-line output; we want the line starting
    /// with `n` (name). Returns nil when lsof emitted no usable line.
    static func parseLsofCwd(_ output: String) -> String? {
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line.hasPrefix("n"), line.count > 1 {
                return String(line.dropFirst())
            }
        }
        return nil
    }

    /// Finds the workspace whose decodedPath is the longest prefix of `cwd`.
    /// Ties broken by ordinal (stable).
    static func matchWorkspace(forCWD cwd: String, in workspaces: [Workspace]) -> Workspace? {
        var best: Workspace?
        var bestLen = 0
        let needle = cwd.hasSuffix("/") ? cwd : (cwd + "/")
        for ws in workspaces {
            let prefix = ws.decodedPath.hasSuffix("/") ? ws.decodedPath : (ws.decodedPath + "/")
            if needle.hasPrefix(prefix) || cwd == ws.decodedPath {
                if prefix.count > bestLen {
                    bestLen = prefix.count
                    best = ws
                }
            }
        }
        return best
    }
}
