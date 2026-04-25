import XCTest
@testable import Chronicle

final class SmartFolderTests: XCTestCase {
    func test_codable_today_roundtrip() throws {
        let q: SmartFolderQuery = .today
        let data = try JSONEncoder().encode(q)
        let decoded = try JSONDecoder().decode(SmartFolderQuery.self, from: data)
        XCTAssertEqual(decoded, .today)
    }

    func test_codable_lastNDays_roundtrip() throws {
        let q: SmartFolderQuery = .lastNDays(14)
        let data = try JSONEncoder().encode(q)
        let decoded = try JSONDecoder().decode(SmartFolderQuery.self, from: data)
        XCTAssertEqual(decoded, .lastNDays(14))
    }

    func test_codable_usedGitPush_roundtrip() throws {
        let q: SmartFolderQuery = .usedGitPush
        let data = try JSONEncoder().encode(q)
        XCTAssertEqual(try JSONDecoder().decode(SmartFolderQuery.self, from: data), .usedGitPush)
    }

    func test_codable_erroredSessions_roundtrip() throws {
        let q: SmartFolderQuery = .erroredSessions
        let data = try JSONEncoder().encode(q)
        XCTAssertEqual(try JSONDecoder().decode(SmartFolderQuery.self, from: data), .erroredSessions)
    }

    func test_codable_search_roundtrip_preservesAllFields() throws {
        var sq = SearchQuery()
        sq.titleText = "stripe webhook"
        sq.fullText = "exponential"
        sq.tags = ["client", "urgent"]
        sq.workspaces = ["flutter"]
        sq.timeWindow = .relative(days: 9)
        sq.limit = 42
        let q: SmartFolderQuery = .search(sq)

        let data = try JSONEncoder().encode(q)
        let decoded = try JSONDecoder().decode(SmartFolderQuery.self, from: data)
        guard case .search(let s2) = decoded else {
            XCTFail("expected .search after roundtrip; got \(decoded)")
            return
        }
        XCTAssertEqual(s2.titleText, "stripe webhook")
        XCTAssertEqual(s2.fullText, "exponential")
        XCTAssertEqual(s2.tags, ["client", "urgent"])
        XCTAssertEqual(s2.workspaces, ["flutter"])
        XCTAssertEqual(s2.timeWindow, .relative(days: 9))
        XCTAssertEqual(s2.limit, 42)
    }

    func test_codable_unknownKind_decodesToCustom_emptyString() throws {
        // Simulate a forward-version row with an unknown `kind`.
        let json = Data(#"{"kind":"cosmicRayBurst"}"#.utf8)
        let decoded = try JSONDecoder().decode(SmartFolderQuery.self, from: json)
        XCTAssertEqual(decoded, .custom(raw: ""))
    }

    func test_builtIns_hasFourEntries_withExpectedNames() {
        let names = SmartFolder.builtIns.map(\.name)
        XCTAssertEqual(names, ["Today", "This week", "Used `git push`", "Errored sessions"])
    }

    func test_builtIns_sortOrderIsMonotonic() {
        let orders = SmartFolder.builtIns.map(\.sortOrder)
        XCTAssertEqual(orders, orders.sorted())
    }
}
