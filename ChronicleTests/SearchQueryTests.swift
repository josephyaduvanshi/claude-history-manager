import XCTest
@testable import Chronicle

final class SearchQueryTests: XCTestCase {

    // MARK: - Empty / plain

    func test_parse_emptyString_returnsEmptyQuery() {
        let q = SearchQueryParser.parse("")
        XCTAssertTrue(q.isEmpty)
        XCTAssertFalse(q.needsFullText)
    }

    func test_parse_whitespaceOnly_returnsEmptyQuery() {
        let q = SearchQueryParser.parse("   \n   \t  ")
        XCTAssertTrue(q.isEmpty)
    }

    func test_parse_plainText_fillsTitleText() {
        let q = SearchQueryParser.parse("stripe webhook")
        XCTAssertEqual(q.titleText, "stripe webhook")
        XCTAssertEqual(q.fullText, "")
        XCTAssertTrue(q.tags.isEmpty)
        XCTAssertNil(q.timeWindow)
    }

    func test_parse_unicodeWhitespace_collapsesToSingleSpaces() {
        // NBSP, regular space, tab — all treated as token boundaries.
        let q = SearchQueryParser.parse("foo\u{00A0}bar\tbaz")
        XCTAssertEqual(q.titleText, "foo bar baz")
    }

    // MARK: - /full:

    func test_parse_fullCommand_capturesRestOfLine() {
        let q = SearchQueryParser.parse("/full: stripe webhook timeout")
        XCTAssertEqual(q.fullText, "stripe webhook timeout")
        XCTAssertEqual(q.titleText, "")
        XCTAssertTrue(q.needsFullText)
    }

    func test_parse_fullCommand_withInlineValue() {
        let q = SearchQueryParser.parse("/full:stripe webhook")
        XCTAssertEqual(q.fullText, "stripe webhook")
    }

    func test_parse_fullCommand_eatsSubsequentSlashTokens() {
        // After /full:, remaining tokens — even /today — are part of the body.
        let q = SearchQueryParser.parse("/full: stripe /today foo")
        XCTAssertEqual(q.fullText, "stripe /today foo")
        XCTAssertNil(q.timeWindow, "/today AFTER /full: must not be re-interpreted")
    }

    func test_parse_textBeforeFullIsPreserved_textAfterIsEaten() {
        let q = SearchQueryParser.parse("title words /full: body words")
        XCTAssertEqual(q.titleText, "title words")
        XCTAssertEqual(q.fullText, "body words")
    }

    // MARK: - /today /this-week /last30days

    func test_parse_today() {
        let q = SearchQueryParser.parse("/today")
        XCTAssertEqual(q.timeWindow, .today)
    }

    func test_parse_thisWeek_bothForms() {
        XCTAssertEqual(SearchQueryParser.parse("/this-week").timeWindow, .thisWeek)
        XCTAssertEqual(SearchQueryParser.parse("/thisweek").timeWindow, .thisWeek)
    }

    func test_parse_last30Days_bothForms() {
        XCTAssertEqual(SearchQueryParser.parse("/last30days").timeWindow, .last30Days)
        XCTAssertEqual(SearchQueryParser.parse("/last-30d").timeWindow, .last30Days)
    }

    // MARK: - /tag

    func test_parse_tag_bareWord() {
        let q = SearchQueryParser.parse("/tag:bug")
        XCTAssertEqual(q.tags, ["bug"])
    }

    func test_parse_tag_quotedMultiWord() {
        let q = SearchQueryParser.parse(#"/tag:"client work""#)
        XCTAssertEqual(q.tags, ["client work"])
    }

    func test_parse_tag_multipleAppended() {
        let q = SearchQueryParser.parse(#"/tag:bug /tag:"client work" /tag:billing"#)
        XCTAssertEqual(q.tags, ["bug", "client work", "billing"])
    }

    // MARK: - /in

    func test_parse_in_bareWord() {
        let q = SearchQueryParser.parse("/in:flutter")
        XCTAssertEqual(q.workspaces, ["flutter"])
    }

    func test_parse_in_quoted() {
        let q = SearchQueryParser.parse(#"/in:"flutter / apps""#)
        XCTAssertEqual(q.workspaces, ["flutter / apps"])
    }

    // MARK: - combinations

    func test_parse_combination_titleAndInAndToday() {
        let q = SearchQueryParser.parse("stripe /in:flutter /today")
        XCTAssertEqual(q.titleText, "stripe")
        XCTAssertEqual(q.workspaces, ["flutter"])
        XCTAssertEqual(q.timeWindow, .today)
    }

    func test_parse_combination_tagAndPlainText() {
        let q = SearchQueryParser.parse("webhook /tag:bug timeout")
        XCTAssertEqual(q.titleText, "webhook timeout")
        XCTAssertEqual(q.tags, ["bug"])
    }

    // MARK: - unknown slash tokens

    func test_parse_unknownSlashCommand_fallsBackToPlainText() {
        // `/unknown` — keep as plain text rather than silently dropping it.
        let q = SearchQueryParser.parse("/unknown foo")
        XCTAssertEqual(q.titleText, "/unknown foo")
    }

    // MARK: - leading/trailing whitespace

    func test_parse_stripsLeadingTrailingWhitespace() {
        let q = SearchQueryParser.parse("   stripe checkout  ")
        XCTAssertEqual(q.titleText, "stripe checkout")
    }

    // MARK: - isEmpty / needsFullText

    func test_isEmpty_whenOnlyTitleText_isFalse() {
        let q = SearchQueryParser.parse("foo")
        XCTAssertFalse(q.isEmpty)
    }

    func test_isEmpty_whenOnlyTimeWindow_isFalse() {
        let q = SearchQueryParser.parse("/today")
        XCTAssertFalse(q.isEmpty)
    }

    func test_needsFullText_true_whenFullCommandPresent() {
        let q = SearchQueryParser.parse("/full: stripe")
        XCTAssertTrue(q.needsFullText)
    }
}
