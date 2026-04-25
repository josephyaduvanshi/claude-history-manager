import XCTest
@testable import Chronicle

final class WorkspacePathDecoderTests: XCTestCase {
    let decoder = WorkspacePathDecoder()

    func test_decode_simpleHomePath() {
        let r = decoder.decode("-Users-josephyaduvanshi-Code-flutter-apps-aayo")
        XCTAssertEqual(r.decodedPath, "/Users/josephyaduvanshi/Code/flutter/apps/aayo")
        XCTAssertEqual(r.group, "flutter")
        XCTAssertEqual(r.displayName, "flutter / apps / aayo")
    }

    func test_decode_securityPath() {
        let r = decoder.decode("-Users-josephyaduvanshi-Code-security-pentest")
        XCTAssertEqual(r.group, "security")
        XCTAssertEqual(r.displayName, "security / pentest")
    }

    func test_decode_aiClaudePath() {
        let r = decoder.decode("-Users-josephyaduvanshi-Code-ai-claude-cowork")
        XCTAssertEqual(r.group, "ai/claude")
        XCTAssertEqual(r.displayName, "ai / claude / cowork")
    }

    func test_decode_homeDirectoryFallback() {
        let r = decoder.decode("-Users-josephyaduvanshi")
        XCTAssertEqual(r.decodedPath, "/Users/josephyaduvanshi")
        XCTAssertEqual(r.group, "uncategorized")
    }

    func test_decode_legacyDesktopPath() {
        let r = decoder.decode("-Users-josephyaduvanshi-Desktop-aayo")
        XCTAssertEqual(r.group, "desktop")
        XCTAssertEqual(r.displayName, "Desktop / aayo")
    }
}
