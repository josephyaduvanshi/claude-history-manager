import Foundation
import GRDB

/// User preferences for which terminal to launch `claude --resume` in.
///
/// Two storage layers:
///   - `UserDefaults` for the machine-wide default terminal.
///   - SQLite `session_terminal_overrides` for per-session choices
///     (`nil` override = use default).
///
/// An actor so concurrent reads/writes from the UI + background launches
/// don't race. Main-thread callers touch it via `Task { await ... }`.
public actor TerminalPreference {
    // MARK: - Keys

    /// UserDefaults key for the machine-wide default terminal rawValue.
    /// Centralized so callers never hard-code the string elsewhere.
    public static let defaultTerminalKey = "chronicle.defaultTerminal"

    // MARK: - Stored state

    private let defaults: UserDefaults
    private let database: any DatabaseWriter
    /// Optional installation probe so `defaultTerminal()` can fall back to the
    /// first actually-installed terminal when the key is unset. Tests can
    /// stub this; production uses the real probe.
    private let installationProbe: any TerminalInstallationProbe

    // MARK: - Init

    public init(
        defaults: UserDefaults = .standard,
        database: any DatabaseWriter,
        installationProbe: any TerminalInstallationProbe = DefaultTerminalInstallationProbe()
    ) {
        self.defaults = defaults
        self.database = database
        self.installationProbe = installationProbe
    }

    // MARK: - Default terminal

    /// Resolve the user's default terminal. Falls back to the first installed
    /// terminal if the preference is unset; `.terminal` is always a valid
    /// final fallback since Terminal.app ships with macOS.
    public func defaultTerminal() -> Terminal {
        if let raw = defaults.string(forKey: Self.defaultTerminalKey),
           let t = Terminal(rawValue: raw) {
            return t
        }
        // Unset; pick the first installed, preferring ghostty > iterm > terminal.
        let installed = Terminal.installed(probe: installationProbe)
        return installed.first ?? .terminal
    }

    /// Persist the user's default terminal choice.
    ///
    /// After writing, posts `.chronicleDefaultTerminalChanged` on the main
    /// thread so live UI (AppView's `state.defaultTerminal`) can refresh
    /// without an app relaunch.
    public func setDefaultTerminal(_ t: Terminal) async {
        defaults.set(t.rawValue, forKey: Self.defaultTerminalKey)
        await MainActor.run {
            NotificationCenter.default.post(
                name: .chronicleDefaultTerminalChanged,
                object: nil
            )
        }
    }

    // MARK: - Per-session override

    /// Returns the per-session terminal override, or `nil` if the session
    /// should use the user's default terminal.
    public func override(for sessionID: SessionID) throws -> Terminal? {
        let key = sessionID.rawValue.uuidString
        return try database.read { db in
            try Terminal.fetchOptional(
                db,
                sql: "SELECT terminal_raw FROM session_terminal_overrides WHERE session_id = ?",
                arguments: [key]
            )
        }
    }

    /// Write or clear the per-session terminal override.
    /// - Parameters:
    ///   - terminal: nil means "clear" (delete the row → fall back to default).
    ///   - sessionID: the session to override.
    public func setOverride(_ terminal: Terminal?, for sessionID: SessionID) throws {
        let key = sessionID.rawValue.uuidString
        try database.write { db in
            if let terminal {
                try db.execute(sql: """
                    INSERT INTO session_terminal_overrides (session_id, terminal_raw)
                    VALUES (?, ?)
                    ON CONFLICT(session_id) DO UPDATE SET terminal_raw = excluded.terminal_raw
                    """,
                    arguments: [key, terminal.rawValue])
            } else {
                try db.execute(
                    sql: "DELETE FROM session_terminal_overrides WHERE session_id = ?",
                    arguments: [key]
                )
            }
        }
    }

    /// Resolved terminal for a given session: override if set, else default.
    public func resolved(for sessionID: SessionID) throws -> Terminal {
        if let ov = try override(for: sessionID) { return ov }
        return defaultTerminal()
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted by `TerminalPreference.setDefaultTerminal(_:)` after the new
    /// default terminal has been written to UserDefaults. Subscribers (e.g.
    /// `AppView`) refetch the default so the UI reflects the change live , 
    /// without requiring an app relaunch.
    public static let chronicleDefaultTerminalChanged = Notification.Name(
        "chronicle.defaultTerminalChanged"
    )
}

// MARK: - GRDB row decoding for Terminal

extension Terminal {
    /// Fetch a `Terminal` from a single-column `terminal_raw TEXT` query, or
    /// nil if no row exists / the raw string doesn't match a known case.
    fileprivate static func fetchOptional(
        _ db: GRDB.Database,
        sql: String,
        arguments: StatementArguments
    ) throws -> Terminal? {
        guard let raw = try String.fetchOne(db, sql: sql, arguments: arguments) else { return nil }
        return Terminal(rawValue: raw)
    }
}
