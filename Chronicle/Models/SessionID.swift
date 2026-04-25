import Foundation

/// Strongly-typed wrapper around a session UUID to prevent mixing with other ID kinds.
public struct SessionID: Hashable, Equatable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public enum InitError: Error, Equatable {
        case invalidUUID(String)
    }

    public init(string: String) throws {
        guard let uuid = UUID(uuidString: string) else {
            throw InitError.invalidUUID(string)
        }
        self.rawValue = uuid
    }
}

extension SessionID: CustomStringConvertible {
    public var description: String { rawValue.uuidString.lowercased() }
}
