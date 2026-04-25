import Foundation

/// Structured representation of a user's search input. Produced by `SearchQueryParser`
/// from a raw search string that may contain slash-commands (`/full:`, `/today`,
/// `/tag:foo`, `/in:bar`) mixed with free-form title text.
public struct SearchQuery: Equatable, Sendable {
    public enum TimeWindow: Equatable, Sendable {
        case today
        case thisWeek      // last 7 days
        case last30Days
        case relative(days: Int)
    }

    /// Everything after `/full:`, matched against the FTS5 transcript index.
    public var fullText: String = ""

    /// Free-form text to match against `sessions.title` via LIKE.
    public var titleText: String = ""

    /// Tag filters from `/tag:foo` or `/tag:"client work"`.
    public var tags: [String] = []

    /// Workspace filters from `/in:foo` (matched against workspace displayName or decodedPath).
    public var workspaces: [String] = []

    /// Date range filter (`/today`, `/this-week`, `/last30days`).
    public var timeWindow: TimeWindow? = nil

    /// Max rows to return (default 500; repository honors this).
    public var limit: Int = 500

    public init() {}

    /// True when the query requires the FTS5 transcript index to answer.
    public var needsFullText: Bool { !fullText.isEmpty }

    /// True when the query has no meaningful filters; callers should treat it as "show everything".
    public var isEmpty: Bool {
        titleText.isEmpty
            && fullText.isEmpty
            && tags.isEmpty
            && workspaces.isEmpty
            && timeWindow == nil
    }
}

/// Parses a raw search string into a `SearchQuery`.
///
/// Supported slash-commands (leading `/`):
/// - `/full: ...`, captures the REST OF THE LINE as `fullText` (multi-word).
/// - `/today`, `/this-week` or `/thisweek`, `/last30days` or `/last-30d`, set `timeWindow`.
/// - `/tag:foo` or `/tag:"two words"`, appends to `tags`.
/// - `/in:foo` or `/in:"two / path"`, appends to `workspaces`.
///
/// Any token that isn't a recognised slash-command (or is outside `/full:`'s greedy
/// capture) is appended to `titleText` with original whitespace preserved. Unknown
/// slash-commands are treated as plain text so typos don't silently disappear.
public enum SearchQueryParser {

    public static func parse(_ raw: String) -> SearchQuery {
        var query = SearchQuery()

        // Normalise all whitespace (including NBSP / unicode) but keep ASCII spaces.
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return query }

        var titleBuf: [String] = []

        var scanner = Scanner(trimmed)
        while !scanner.atEnd {
            scanner.skipWhitespace()
            if scanner.atEnd { break }

            // Is this position a slash-token?
            if scanner.peek() == "/" {
                // Remember cursor so we can fall back to plain-text if the slash token is unrecognised.
                let checkpoint = scanner.cursor
                let token = scanner.readSlashToken()

                let lower = token.name.lowercased()
                switch lower {
                case "full":
                    // Greedy: capture the REST OF THE LINE verbatim.
                    let rest = scanner.readRestOfLine()
                    // If value portion already captured (e.g. `/full:foo bar`), prefix it.
                    var pieces: [String] = []
                    if let v = token.value, !v.isEmpty { pieces.append(v) }
                    let restTrim = rest.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !restTrim.isEmpty { pieces.append(restTrim) }
                    query.fullText = pieces.joined(separator: " ")
                case "today":
                    query.timeWindow = .today
                case "this-week", "thisweek":
                    query.timeWindow = .thisWeek
                case "last30days", "last-30d", "last30d":
                    query.timeWindow = .last30Days
                case "tag":
                    if let v = token.value, !v.isEmpty {
                        query.tags.append(v)
                    }
                case "in":
                    if let v = token.value, !v.isEmpty {
                        query.workspaces.append(v)
                    }
                default:
                    // Unknown slash-command; treat the ORIGINAL source as plain title text.
                    // Reset the cursor and consume the bare word.
                    scanner.cursor = checkpoint
                    let word = scanner.readPlainWord()
                    if !word.isEmpty { titleBuf.append(word) }
                }
            } else {
                let word = scanner.readPlainWord()
                if !word.isEmpty { titleBuf.append(word) }
            }
        }

        query.titleText = titleBuf.joined(separator: " ")
        return query
    }
}

// MARK: - Scanner

/// Tiny character-level scanner over `String.UnicodeScalarView`.
/// Handles quoted strings, slash-prefixed tokens, and whitespace boundaries.
private struct Scanner {
    let scalars: [Unicode.Scalar]
    var cursor: Int = 0

    init(_ string: String) {
        self.scalars = Array(string.unicodeScalars)
    }

    var atEnd: Bool { cursor >= scalars.count }

    func peek() -> Unicode.Scalar? {
        atEnd ? nil : scalars[cursor]
    }

    mutating func advance() -> Unicode.Scalar? {
        guard !atEnd else { return nil }
        let s = scalars[cursor]
        cursor += 1
        return s
    }

    mutating func skipWhitespace() {
        while !atEnd {
            let s = scalars[cursor]
            if CharacterSet.whitespacesAndNewlines.contains(s) {
                cursor += 1
            } else { break }
        }
    }

    /// Reads a bare word (whitespace-delimited). Does NOT strip leading slash.
    mutating func readPlainWord() -> String {
        var out = String.UnicodeScalarView()
        while !atEnd {
            let s = scalars[cursor]
            if CharacterSet.whitespacesAndNewlines.contains(s) { break }
            out.append(s)
            cursor += 1
        }
        return String(out)
    }

    /// Reads the rest of the input verbatim (including inner whitespace).
    mutating func readRestOfLine() -> String {
        guard !atEnd else { return "" }
        let slice = scalars[cursor..<scalars.count]
        cursor = scalars.count
        var out = String.UnicodeScalarView()
        out.append(contentsOf: slice)
        return String(out)
    }

    struct SlashToken {
        let name: String    // e.g. "tag", "in", "full", "today"
        let value: String?  // optional value portion after `:`
    }

    /// Reads a slash-prefixed token from the current position.
    /// Assumes `peek() == "/"`. Handles:
    ///   `/today`            -> SlashToken(name: "today", value: nil)
    ///   `/tag:foo`          -> SlashToken(name: "tag", value: "foo")
    ///   `/tag:"client work"`-> SlashToken(name: "tag", value: "client work")
    ///   `/full:stripe`      -> SlashToken(name: "full", value: "stripe")
    mutating func readSlashToken() -> SlashToken {
        // Consume leading slash.
        _ = advance()  // '/'

        // Read name until ':' or whitespace.
        var nameScalars = String.UnicodeScalarView()
        while !atEnd {
            let s = scalars[cursor]
            if s == ":" || CharacterSet.whitespacesAndNewlines.contains(s) { break }
            nameScalars.append(s)
            cursor += 1
        }
        let name = String(nameScalars)

        // If we stopped at ':', read the value (possibly quoted).
        var value: String? = nil
        if !atEnd, scalars[cursor] == ":" {
            cursor += 1  // consume ':'
            value = readTokenValue()
        }
        return SlashToken(name: name, value: value)
    }

    /// Reads a slash-token value: either a quoted string (double quotes)
    /// or a bare word up to the next whitespace.
    mutating func readTokenValue() -> String {
        guard !atEnd else { return "" }
        let s = scalars[cursor]
        if s == "\"" {
            // Quoted string; read until closing quote or end.
            cursor += 1
            var out = String.UnicodeScalarView()
            while !atEnd {
                let c = scalars[cursor]
                if c == "\"" {
                    cursor += 1
                    break
                }
                out.append(c)
                cursor += 1
            }
            return String(out)
        } else {
            return readPlainWord()
        }
    }
}
