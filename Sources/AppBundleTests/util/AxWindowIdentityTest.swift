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

    func testSuccessfulNullIdIsUnknownAndCannotBeRegistered() {
        XCTAssertNil(validAxWindowId(kCGNullWindowID, error: .success))
        XCTAssertTrue(shouldKeepRegisteredAxWindow(windowId: nil, error: .success))
    }

    func testRealWindowIdRequiresSuccessfulConversion() {
        XCTAssertEqual(validAxWindowId(42, error: .success), 42)
        XCTAssertNil(validAxWindowId(42, error: .cannotComplete))
        XCTAssertNil(validAxWindowId(42, error: .invalidUIElement))
    }

    func testOnlyExplicitInvalidElementProvesWindowDeath() {
        for error: AXError in [.success, .cannotComplete, .failure, .notImplemented, .noValue] {
            XCTAssertTrue(shouldKeepRegisteredAxWindow(windowId: nil, error: error), "\(error)")
        }
        XCTAssertFalse(shouldKeepRegisteredAxWindow(windowId: nil, error: .invalidUIElement))
        XCTAssertTrue(shouldKeepRegisteredAxWindow(windowId: 42, error: .success))
    }
}
