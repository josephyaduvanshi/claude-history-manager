import Foundation
import os

/// Thin facade over `os.Logger` so the rest of the app doesn't import
/// OSLog directly. Four severity levels mapped to the underlying signposts:
///
/// - `debug`  → developer-only breadcrumbs (stripped in release by `os`)
/// - `info`   → routine state transitions worth keeping
/// - `warn`   → non-fatal problems the user may not notice
/// - `error`  → failures the user almost certainly noticed
///
/// All messages route to the unified system log under the subsystem
/// `app.chronicle.Chronicle`; categories are passed per call-site.
///
/// Message parameters are plain `String`; callers interpolate at the call
/// site. `os.Logger`'s privacy guards still apply because we wrap the
/// message inside `\(message, privacy: .public)`, tune per-category if we
/// ever log anything sensitive. For now Chronicle only logs generic
/// bookkeeping so `.public` is safe.
public struct AppLogger: Sendable {
    public static let subsystem: String = "app.chronicle.Chronicle"

    private let logger: Logger

    public init(category: String) {
        self.logger = Logger(subsystem: Self.subsystem, category: category)
    }

    public func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }

    public func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    public func warn(_ message: String) {
        logger.warning("\(message, privacy: .public)")
    }

    public func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }

    // MARK: - Shared category accessors

    /// Startup / bootstrap / app-lifetime events.
    public static let app = AppLogger(category: "app")
    /// Font registration and bundle resource loading.
    public static let fonts = AppLogger(category: "fonts")
    /// JsonlParser / repository indexing.
    public static let parser = AppLogger(category: "parser")
    /// Filesystem and live-process watchers.
    public static let watchers = AppLogger(category: "watchers")
    /// iCloud Drive sync + push/pull round trips.
    public static let sync = AppLogger(category: "sync")
    /// GitHub Releases update checker.
    public static let updates = AppLogger(category: "updates")
    /// Editor launcher and terminal launcher dispatch.
    public static let launch = AppLogger(category: "launch")
    /// Search query execution + result counts. Tail with
    /// `log stream --predicate 'subsystem == "app.chronicle.Chronicle" && category == "search"'`
    /// to audit why a query came back empty.
    public static let search = AppLogger(category: "search")
}
