import Foundation

// MARK: - Release payload

public struct GitHubRelease: Decodable, Equatable, Sendable {
    /// `{user}/{repo}` path this checker queries. Kept as a static so the
    /// hard-coded username is trivial to change at release time.
    public static let repoPath = "josephyaduvanshi/claude-history-manager"

    public let tagName: String
    public let name: String?
    public let body: String?
    public let htmlURL: String
    public let publishedAt: String?
    public let prerelease: Bool?
    public let draft: Bool?

    enum CodingKeys: String, CodingKey {
        case tagName     = "tag_name"
        case name
        case body
        case htmlURL     = "html_url"
        case publishedAt = "published_at"
        case prerelease
        case draft
    }
}

// MARK: - Outcome

public enum UpdateCheckOutcome: Equatable, Sendable {
    case upToDate(currentVersion: String)
    case updateAvailable(latest: GitHubRelease, currentVersion: String)
    case error(String)
}

// MARK: - HTTP abstraction

/// Abstraction over URLSession so tests can stub the transport without real
/// network I/O. Returns decoded `Data` for the given URL or throws.
public protocol UpdateHTTPClient: Sendable {
    func fetch(_ url: URL) async throws -> Data
}

public struct URLSessionUpdateHTTPClient: UpdateHTTPClient {
    public init() {}
    public func fetch(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Chronicle/\(UpdateChecker.currentVersion())",
                     forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        return data
    }
}

// MARK: - UpdateChecker

public struct UpdateChecker: Sendable {
    public let repoPath: String
    public let httpClient: UpdateHTTPClient

    public init(repoPath: String = GitHubRelease.repoPath,
                httpClient: UpdateHTTPClient = URLSessionUpdateHTTPClient()) {
        self.repoPath = repoPath
        self.httpClient = httpClient
    }

    public var latestReleaseURL: URL {
        URL(string: "https://api.github.com/repos/\(repoPath)/releases/latest")!
    }

    /// Reads `CFBundleShortVersionString` from the main bundle. Returns
    /// `"0.0.0"` as a safe default when the key is missing (e.g. running
    /// via `swift run` from the debug build which has no Info.plist).
    public static func currentVersion() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "0.0.0"
    }

    public func check(currentVersion override: String? = nil) async -> UpdateCheckOutcome {
        let current = override ?? Self.currentVersion()
        do {
            let data = try await httpClient.fetch(latestReleaseURL)
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            if release.draft == true || release.prerelease == true {
                return .upToDate(currentVersion: current)
            }
            if Self.isNewer(remote: release.tagName, than: current) {
                return .updateAvailable(latest: release, currentVersion: current)
            }
            return .upToDate(currentVersion: current)
        } catch {
            AppLogger.updates.warn("check failed: \(error.localizedDescription)")
            return .error(error.localizedDescription)
        }
    }

    // MARK: - Version comparison

    /// Returns true when `remote` represents a strictly-newer semver than
    /// `local`. Both accept an optional leading `v`. Missing / non-numeric
    /// segments are treated as zero. Extra segments in one but not the
    /// other compare as the longer version being newer (e.g. 1.0.1 > 1.0).
    public static func isNewer(remote: String, than local: String) -> Bool {
        let r = parse(remote)
        let l = parse(local)
        let count = max(r.count, l.count)
        for i in 0..<count {
            let a = i < r.count ? r[i] : 0
            let b = i < l.count ? l[i] : 0
            if a > b { return true }
            if a < b { return false }
        }
        return false
    }

    private static func parse(_ raw: String) -> [Int] {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        // Strip anything after a `-` (pre-release tags) so 1.0.0-beta parses as 1.0.0.
        if let dash = s.firstIndex(of: "-") {
            s = String(s[s.startIndex..<dash])
        }
        return s.split(separator: ".").map { Int($0) ?? 0 }
    }
}
