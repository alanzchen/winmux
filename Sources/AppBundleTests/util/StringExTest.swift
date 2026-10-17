import Common
import XCTest

final class StringExTest: XCTestCase {
    func testJoinTruncatingDoesNotMarkAnExactFitAsTruncated() {
        XCTAssertEqual(
            ["Safari", "Calendar"].joinTruncating(separator: ", ", length: 16),
            "Safari, Calendar",
        )
    }

    func testJoinTruncatingMarksItemsOmittedAfterAnExactFit() {
        XCTAssertEqual(
            ["Safari", "Calendar", "Mail"].joinTruncating(separator: ", ", length: 16),
            "Safari, Calendar, …",
        )
    }

    func testJoinTruncatingMarksAPartiallyIncludedElement() {
        XCTAssertEqual(
            ["Safari", "Calendar"].joinTruncating(separator: ", ", length: 15),
            "Safari, Calenda…",
        )
    }

    func testJoinTruncatingCountsFirstElementBeforeAppendingNextElement() {
        XCTAssertEqual(
            ["Safari", "Calendar"].joinTruncating(separator: ", ", length: 8),
            "Safari, …",
        )
    }

    func testJoinTruncatingTruncatesFirstElementWhenItExceedsLimit() {
        XCTAssertEqual(
            ["VeryLongName"].joinTruncating(separator: ", ", length: 4),
            "Very…",
        )
    }
}
