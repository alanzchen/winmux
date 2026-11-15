@testable import AppBundle
import XCTest

/// Carbon's S2-C2 reproducer (REVIEW-upstream-s2.md), method body verbatim.
final class CarbonS2EofReproTest: XCTestCase {
    @MainActor
    func testIncompleteBareTokenAtEofDoesNotCrashParseConfig() {
        for input in ["width = -", "width = +", "enabled = n", "enabled = na", "mode = i", "mode = in"] {
            XCTAssertFalse(parseConfig(input).errors.isEmpty, input)
        }
    }
}
