@testable import AppBundle
import AppKit
import XCTest

@MainActor
final class AxWindowIdentityTest: XCTestCase {
    func testRegistryRejectsNullIdBeforeInspectingNativeWindow() throws {
        var windows: [UInt32: AxWindow] = [:]
        let registered = try windows.getOrRegisterAxWindow(
            windowId: kCGNullWindowID,
            AXUIElementCreateSystemWide(),
            NSRunningApplication.current,
            RunLoopJob(),
        )
        XCTAssertNil(registered)
        XCTAssertTrue(windows.isEmpty)
    }

    /// Upstream AeroSpace 0f6b2e78: kCGNullWindowID is "a guaranteed invalid window ID". A registered window that
    /// answers with it is gone (until 2026-11-14 it was kept as unknown, and closed windows stayed listed).
    func testSuccessfulNullIdCannotBeRegisteredAndIsNoWindow() {
        XCTAssertNil(validAxWindowId(kCGNullWindowID, error: .success))
        XCTAssertEqual(registeredAxWindowAnswer(windowId: nil, error: .success), .gone)
    }

    func testRealWindowIdRequiresSuccessfulConversion() {
        XCTAssertEqual(validAxWindowId(42, error: .success), 42)
        XCTAssertNil(validAxWindowId(42, error: .cannotComplete))
        XCTAssertNil(validAxWindowId(42, error: .invalidUIElement))
    }

    /// A timeout is a busy app; every other failure is an element that answers for nothing, as upstream AeroSpace tells
    /// them. Neither alone lets a window go (`windowLivenessVerdict`).
    func testOnlyATimeoutIsABusyApp() {
        for error: AXError in [.success, .failure, .notImplemented, .noValue, .attributeUnsupported, .illegalArgument,
                               .invalidUIElement] {
            XCTAssertEqual(registeredAxWindowAnswer(windowId: nil, error: error), .gone, "\(error)")
        }
        XCTAssertEqual(registeredAxWindowAnswer(windowId: nil, error: .cannotComplete), .busy)
        XCTAssertEqual(registeredAxWindowAnswer(windowId: 42, error: .success), .alive)
    }
}
