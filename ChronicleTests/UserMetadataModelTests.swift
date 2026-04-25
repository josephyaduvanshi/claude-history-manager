import XCTest
@testable import Chronicle

final class UserMetadataModelTests: XCTestCase {
    private let sid = try! SessionID(string: "11111111-1111-1111-1111-111111111111")

    func test_empty_defaultsAllFlagsFalseAndNoCustomTitleOrNote() {
        let m = UserMetadata.empty(for: sid)
        XCTAssertEqual(m.sessionID, sid)
        XCTAssertFalse(m.isPinned)
        XCTAssertFalse(m.isArchived)
        XCTAssertFalse(m.isDeleted)
        XCTAssertNil(m.customTitle)
        XCTAssertNil(m.note)
        XCTAssertNil(m.deletedAt)
    }

    func test_id_isSessionIDDescription() {
        let m = UserMetadata.empty(for: sid)
        XCTAssertEqual(m.id, sid.description)
    }

    func test_tag_clampsHueToValidRange() {
        XCTAssertEqual(Tag.clampHue(400), 40)
        XCTAssertEqual(Tag.clampHue(-10), 350)
        XCTAssertEqual(Tag.clampHue(0), 0)
        XCTAssertEqual(Tag.clampHue(360), 0)
    }

    func test_tag_paletteHasEightEntries() {
        XCTAssertEqual(Tag.palette.count, 8)
    }

    func test_sessionWithMetadata_displayTitle_prefersCustomOverRaw() {
        let raw = SessionMetadata(
            sessionID: sid,
            workspaceID: "-ws",
            title: "Raw parsed title",
            createdAt: Date(),
            lastModifiedAt: Date(),
            messageCount: 3,
            tokenCount: 120,
            isLive: false
        )
        var meta = UserMetadata.empty(for: sid)
        meta.customTitle = "My project brief"
        let swm = SessionWithMetadata(session: raw, userMetadata: meta, tags: [])
        XCTAssertEqual(swm.displayTitle, "My project brief")
    }

    func test_sessionWithMetadata_displayTitle_fallsBackToRaw_whenCustomEmpty() {
        let raw = SessionMetadata(
            sessionID: sid,
            workspaceID: "-ws",
            title: "Raw parsed title",
            createdAt: Date(),
            lastModifiedAt: Date(),
            messageCount: 3,
            tokenCount: 120,
            isLive: false
        )
        var meta = UserMetadata.empty(for: sid)
        meta.customTitle = ""
        let swm = SessionWithMetadata(session: raw, userMetadata: meta, tags: [])
        XCTAssertEqual(swm.displayTitle, "Raw parsed title")
    }
}
