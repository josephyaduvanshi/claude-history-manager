import Foundation

public struct WorkspacePathDecoder {
    public struct Result: Equatable, Sendable {
        public let decodedPath: String
        public let group: String
        public let displayName: String
    }

    public init() {}

    public func decode(_ encoded: String) -> Result {
        let path = "/" + encoded
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .replacingOccurrences(of: "-", with: "/")
        let components = path.split(separator: "/").map(String.init)

        // Find Code anchor
        if let codeIdx = components.firstIndex(of: "Code"), codeIdx + 1 < components.count {
            let after = Array(components.suffix(from: codeIdx + 1))
            // ai/<sub> case
            if after[0] == "ai", after.count >= 2 {
                let group = "ai/\(after[1])"
                let display = after.joined(separator: " / ")
                return Result(decodedPath: path, group: group, displayName: display)
            }
            let group = after[0]
            let display = after.joined(separator: " / ")
            return Result(decodedPath: path, group: group, displayName: display)
        }

        // Desktop anchor
        if let deskIdx = components.firstIndex(of: "Desktop"), deskIdx + 1 < components.count {
            let after = Array(components.suffix(from: deskIdx + 1))
            let display = "Desktop / " + after.joined(separator: " / ")
            return Result(decodedPath: path, group: "desktop", displayName: display)
        }

        // School anchor
        if let schoolIdx = components.firstIndex(of: "School"), schoolIdx + 1 < components.count {
            let after = Array(components.suffix(from: schoolIdx + 1))
            let display = "School / " + after.joined(separator: " / ")
            return Result(decodedPath: path, group: "school", displayName: display)
        }

        // Documents anchor
        if let docsIdx = components.firstIndex(of: "Documents"), docsIdx + 1 < components.count {
            let after = Array(components.suffix(from: docsIdx + 1))
            let display = "Documents / " + after.joined(separator: " / ")
            return Result(decodedPath: path, group: "documents", displayName: display)
        }

        // Fallback
        return Result(decodedPath: path, group: "uncategorized", displayName: components.last ?? path)
    }
}
