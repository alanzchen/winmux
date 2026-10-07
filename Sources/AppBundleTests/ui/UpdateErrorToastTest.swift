import AppKit
@testable import SparkleSupport
import XCTest

@MainActor
final class UpdateErrorToastTest: XCTestCase {
    func testFailedUpdateReportsOnceAndAcknowledgesWithoutShowingItsOriginalAlert() {
        let driver = WinMuxUpdateUserDriver(hostBundle: .main, delegate: nil)
        let key = NSApp.keyWindow
        var reports: [(String, String)] = []
        var details: (() -> Void)?
        var acknowledgements = 0
        driver.reportError = { title, body, original in
            reports.append((title, body))
            details = original
        }
        let error = NSError(domain: "neutral.update.fixture", code: 42, userInfo: [
            NSLocalizedDescriptionKey: "The download failed.",
            NSLocalizedRecoverySuggestionErrorKey: "Try again when the connection returns.",
        ])
        driver.showUpdaterError(error) { acknowledgements += 1 }
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.0, error.localizedDescription)
        XCTAssertEqual(reports.first?.1, error.localizedRecoverySuggestion)
        XCTAssertNotNil(details, "The standard diagnostic is retained for an explicit action")
        XCTAssertEqual(acknowledgements, 1, "Only the failed session is acknowledged")
        XCTAssertTrue(NSApp.keyWindow === key)
    }
}
