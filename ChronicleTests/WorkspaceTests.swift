import XCTest
@testable import Chronicle

final class WorkspaceTests: XCTestCase {
    func test_initialization_storesValues() {
        let ws = Workspace(
            id: "-Users-josephyaduvanshi-Code-flutter-apps-aayo",
            decodedPath: "/Users/josephyaduvanshi/Code/flutter/apps/aayo",
            group: "flutter",
            displayName: "flutter / apps / aayo"
        )
        XCTAssertEqual(ws.id, "-Users-josephyaduvanshi-Code-flutter-apps-aayo")
        XCTAssertEqual(ws.group, "flutter")
        XCTAssertEqual(ws.displayName, "flutter / apps / aayo")
    }

    func test_isHashableAndEquatable() {
        let a = Workspace(id: "x", decodedPath: "/x", group: "g", displayName: "d")
        let b = Workspace(id: "x", decodedPath: "/x", group: "g", displayName: "d")
        XCTAssertEqual(a, b)
        XCTAssertEqual(Set([a, b]).count, 1)
    }

    // MARK: - shortName / parentGroup / leafName (Bug 6)

    func test_shortName_returnsLastTwoComponents() {
        let ws = Workspace(
            id: "-Users-me-Code-flutter-apps-aayo",
            decodedPath: "/Users/me/Code/flutter/apps/aayo",
            group: "flutter",
            displayName: "flutter / apps / aayo"
        )
        XCTAssertEqual(ws.shortName, "apps / aayo")
    }

    func test_shortName_falls_back_whenPathIsSingleComponent() {
        let ws = Workspace(
            id: "only",
            decodedPath: "/only",
            group: "g",
            displayName: "only"
        )
        // Only "only" as a component — fall back to last component.
        XCTAssertEqual(ws.shortName, "only")
    }

    func test_shortName_truncates_veryLongPair() {
        let long = "extremely-long-workspace-folder-name-that-exceeds"
        let ws = Workspace(
            id: "x",
            decodedPath: "/Users/me/Parent/\(long)",
            group: "g",
            displayName: "d"
        )
        XCTAssertTrue(ws.shortName.count <= 32,
                      "shortName should be <= 32 chars, got \(ws.shortName.count)")
        XCTAssertTrue(ws.shortName.hasPrefix("…"),
                      "long shortName should ellipsize from the start: \(ws.shortName)")
    }

    func test_parentGroup_isSecondToLastComponent() {
        let ws = Workspace(
            id: "x",
            decodedPath: "/Users/me/Desktop/StealthZero/sz-proxy-mac",
            group: "desktop",
            displayName: "Desktop / StealthZero / sz-proxy-mac"
        )
        XCTAssertEqual(ws.parentGroup, "StealthZero")
    }

    func test_leafName_isLastComponent() {
        let ws = Workspace(
            id: "x",
            decodedPath: "/Users/me/Code/flutter/apps/aayo",
            group: "flutter",
            displayName: "flutter / apps / aayo"
        )
        XCTAssertEqual(ws.leafName, "aayo")
    }

    func test_parentGroup_fallsBackToGroup_forShortPaths() {
        let ws = Workspace(
            id: "only",
            decodedPath: "/only",
            group: "uncategorized",
            displayName: "only"
        )
        XCTAssertEqual(ws.parentGroup, "uncategorized")
    }
}
