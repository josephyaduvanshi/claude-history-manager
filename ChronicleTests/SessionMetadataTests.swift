import XCTest
@testable import Chronicle

final class SessionMetadataTests: XCTestCase {
    func test_initialization() throws {
        let id = try SessionID(string: "11111111-1111-1111-1111-111111111111")
        let m = SessionMetadata(
            sessionID: id,
            workspaceID: "-Users-test-flutter-app",
            title: "Add Stripe checkout to subscription flow",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastModifiedAt: Date(timeIntervalSince1970: 1_700_000_500),
            messageCount: 47,
            tokenCount: 38_412,
            isLive: true
        )
        XCTAssertEqual(m.sessionID, id)
        XCTAssertEqual(m.title, "Add Stripe checkout to subscription flow")
        XCTAssertEqual(m.messageCount, 47)
        XCTAssertTrue(m.isLive)
    }
}
