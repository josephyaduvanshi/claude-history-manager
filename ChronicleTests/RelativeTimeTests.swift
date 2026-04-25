import XCTest
@testable import Chronicle

final class RelativeTimeTests: XCTestCase {
    private let ref = Date(timeIntervalSince1970: 1_745_000_000) // arbitrary frozen instant

    private func ago(_ seconds: Double) -> Date {
        ref.addingTimeInterval(-seconds)
    }

    func test_justNow_underAMinute() {
        XCTAssertEqual(RelativeTime.shortAgo(from: ago(0), reference: ref), "just now")
        XCTAssertEqual(RelativeTime.shortAgo(from: ago(30), reference: ref), "just now")
        XCTAssertEqual(RelativeTime.shortAgo(from: ago(59), reference: ref), "just now")
    }

    func test_minutesAgo_underAnHour() {
        XCTAssertEqual(RelativeTime.shortAgo(from: ago(60), reference: ref), "1m ago")
        XCTAssertEqual(RelativeTime.shortAgo(from: ago(300), reference: ref), "5m ago")
        XCTAssertEqual(RelativeTime.shortAgo(from: ago(59 * 60), reference: ref), "59m ago")
    }

    func test_hoursAgo_underADay() {
        XCTAssertEqual(RelativeTime.shortAgo(from: ago(3600), reference: ref), "1h ago")
        XCTAssertEqual(RelativeTime.shortAgo(from: ago(5 * 3600), reference: ref), "5h ago")
        XCTAssertEqual(RelativeTime.shortAgo(from: ago(23 * 3600), reference: ref), "23h ago")
    }

    func test_yesterday_crossesDayBoundary() {
        // Use a concrete calendar day — pick 2026-04-24 12:00 UTC as reference.
        let cal = Calendar.current
        let components = DateComponents(year: 2026, month: 4, day: 24, hour: 12)
        let reference = cal.date(from: components)!
        let yesterday = cal.date(byAdding: .day, value: -1, to: reference)!
        XCTAssertEqual(RelativeTime.shortAgo(from: yesterday, reference: reference), "yesterday")
    }

    func test_daysAgo_underAWeek() {
        // 3 days ago in clock time (not calendar) — should say "3d ago".
        XCTAssertEqual(RelativeTime.shortAgo(from: ago(3 * 86400), reference: ref), "3d ago")
        XCTAssertEqual(RelativeTime.shortAgo(from: ago(6 * 86400), reference: ref), "6d ago")
    }

    func test_weeksAgo_underFourWeeks() {
        XCTAssertEqual(RelativeTime.shortAgo(from: ago(7 * 86400), reference: ref), "1w ago")
        XCTAssertEqual(RelativeTime.shortAgo(from: ago(21 * 86400), reference: ref), "3w ago")
    }

    func test_monthsAgo_underAYear() {
        XCTAssertEqual(RelativeTime.shortAgo(from: ago(35 * 86400), reference: ref), "1mo ago")
        XCTAssertEqual(RelativeTime.shortAgo(from: ago(120 * 86400), reference: ref), "4mo ago")
    }

    func test_yearsAgo_pastOneYear() {
        XCTAssertEqual(RelativeTime.shortAgo(from: ago(400 * 86400), reference: ref), "1y ago")
        XCTAssertEqual(RelativeTime.shortAgo(from: ago(800 * 86400), reference: ref), "2y ago")
    }

    func test_futureDate_clampsToJustNow() {
        // Timestamp in the future (clock skew) — not a crash.
        let future = ref.addingTimeInterval(600)
        XCTAssertEqual(RelativeTime.shortAgo(from: future, reference: ref), "just now")
    }
}
