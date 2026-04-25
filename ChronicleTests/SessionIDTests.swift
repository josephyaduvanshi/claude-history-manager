import XCTest
@testable import Chronicle

final class SessionIDTests: XCTestCase {
    func test_initFromString_validUUID() throws {
        let id = try SessionID(string: "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(id.rawValue.uuidString.lowercased(),
                       "11111111-1111-1111-1111-111111111111")
    }

    func test_initFromString_invalid_throws() {
        XCTAssertThrowsError(try SessionID(string: "not-a-uuid"))
    }

    func test_isHashableAndEquatable() throws {
        let a = try SessionID(string: "11111111-1111-1111-1111-111111111111")
        let b = try SessionID(string: "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(a, b)
        XCTAssertEqual(Set([a, b]).count, 1)
    }
}
