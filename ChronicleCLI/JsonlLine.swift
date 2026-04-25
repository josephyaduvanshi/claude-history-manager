import Foundation

/// Helpers that pull individual fields out of a single JSONL line without
/// fully decoding the whole record. Designed for cheap scans where we only
/// need cwd / type / message text. Falls back to JSONSerialization when a
/// field is found, so escapes are decoded correctly.
enum JsonlLine {
    /// Decode a single line and return the requested string field, if
    /// present. Returns nil for non-string values, missing keys, malformed
    /// JSON, or empty strings.
    static func string(_ key: String, from data: Data) -> String? {
        guard !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let dict = obj as? [String: Any],
              let s = dict[key] as? String,
              !s.isEmpty else { return nil }
        return s
    }

    static func cwd(from data: Data.SubSequence) -> String? {
        string("cwd", from: Data(data))
    }

    /// Surface "user message text" from a parsed dict, accepting both the
    /// raw-string form (`message.content == "..."`) and the typed-blocks
    /// form (`message.content == [{type: text, text: "..."}, ...]`).
    static func userText(from dict: [String: Any]) -> String? {
        guard let m = dict["message"] as? [String: Any] else { return nil }
        if let s = m["content"] as? String, !s.isEmpty { return s }
        if let blocks = m["content"] as? [[String: Any]] {
            let texts = blocks.compactMap { b -> String? in
                if (b["type"] as? String) == "text", let t = b["text"] as? String { return t }
                return nil
            }
            let joined = texts.joined(separator: "\n")
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    static func assistantText(from dict: [String: Any]) -> String? {
        // Same shape as user, just role differs in the source.
        userText(from: dict)
    }
}

/// One parsed line.
struct ParsedLine {
    let dict: [String: Any]

    init?(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return nil
        }
        self.dict = obj
    }

    var type: String { dict["type"] as? String ?? "" }
    var sessionID: String? { dict["sessionId"] as? String }
    var timestamp: String? { dict["timestamp"] as? String }
    var cwd: String? { dict["cwd"] as? String }
    var gitBranch: String? { dict["gitBranch"] as? String }
    var version: String? { dict["version"] as? String }
}
