import AppKit
@testable import AppBundle
import XCTest

@MainActor
final class WindowMiddleClickCloseTest: XCTestCase {
    override func tearDown() {
        config = defaultConfig
        super.tearDown()
    }

    func testCatcherTakesOnlyMiddleButtonEventsSoTabsKeepTheirClicks() {
        for type in [NSEvent.EventType.otherMouseDown, .otherMouseDragged, .otherMouseUp] {
            XCTAssertTrue(windowMiddleClickCapturesEvent(type, buttonNumber: 2, enabled: true), "\(type)")
            XCTAssertFalse(windowMiddleClickCapturesEvent(type, buttonNumber: 3, enabled: true),
                "Back and forward buttons reach the control underneath")
            XCTAssertFalse(windowMiddleClickCapturesEvent(type, buttonNumber: 2, enabled: false),
                "With the setting off, middle clicks are left alone")
        }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown,
                     .rightMouseUp, .mouseMoved, .scrollWheel] {
            XCTAssertFalse(windowMiddleClickCapturesEvent(type, buttonNumber: 0, enabled: true), "\(type) must reach the SwiftUI tab")
        }
        XCTAssertFalse(windowMiddleClickCapturesEvent(nil, buttonNumber: nil, enabled: true))
    }

    func testOnlyAMiddleClickReleasedOverTheSameTabCloses() {
        XCTAssertTrue(shouldCloseWindowOnMouseUp(buttonNumber: 2, pressedButtonNumber: 2, isInside: true, enabled: true))
        XCTAssertFalse(shouldCloseWindowOnMouseUp(buttonNumber: 2, pressedButtonNumber: 2, isInside: false, enabled: true),
            "Dragging off the tab cancels, like a browser tab")
        XCTAssertFalse(shouldCloseWindowOnMouseUp(buttonNumber: 2, pressedButtonNumber: nil, isInside: true, enabled: true),
            "A press that started elsewhere does not close this tab")
        XCTAssertFalse(shouldCloseWindowOnMouseUp(buttonNumber: 3, pressedButtonNumber: 3, isInside: true, enabled: true),
            "Back and forward buttons do not close windows")
        XCTAssertFalse(shouldCloseWindowOnMouseUp(buttonNumber: 2, pressedButtonNumber: 2, isInside: true, enabled: false))
    }

    func testCatcherViewClosesOnMiddleClickAndHonorsTheSetting() {
        let view = WindowMiddleClickView(frame: CGRect(x: 0, y: 0, width: 120, height: 24))
        var closes = 0
        view.update(windowId: 7) { closes += 1 }
        func click(_ button: Int, releasedAt point: CGPoint = CGPoint(x: 60, y: 12)) {
            view.pressButton(button)
            view.releaseButton(button, at: point)
        }

        click(2)
        XCTAssertEqual(closes, 1)
        click(3)
        XCTAssertEqual(closes, 1)
        click(2, releasedAt: CGPoint(x: 200, y: 12))
        XCTAssertEqual(closes, 1)
        view.releaseButton(2, at: CGPoint(x: 60, y: 12))
        XCTAssertEqual(closes, 1, "A release without its press is ignored")

        config.middleClickClosesWindows = false
        click(2)
        XCTAssertEqual(closes, 1)
    }

    func testReusedCatcherNeverClosesAWindowItWasNotPressedOn() {
        let view = WindowMiddleClickView(frame: CGRect(x: 0, y: 0, width: 120, height: 24))
        var closed: [UInt32] = []
        view.update(windowId: 7) { closed.append(7) }
        view.pressButton(2)
        // SwiftUI hands the view to another tab while the button is down.
        view.update(windowId: 8) { closed.append(8) }
        view.releaseButton(2, at: CGPoint(x: 60, y: 12))
        XCTAssertEqual(closed, [])

        view.update(windowId: 8) { closed.append(8) }
        view.pressButton(2)
        view.update(windowId: 8) { closed.append(8) }
        view.releaseButton(2, at: CGPoint(x: 60, y: 12))
        XCTAssertEqual(closed, [8], "Refreshing the same tab keeps the press")
    }

    func testOnlyBackgroundTabsAndHiddenWorkspacesCountAsHidden() {
        setUpWorkspacesForTests()
        let workspace = Workspace.get(byName: "middle-click")
        _ = workspace.focusWorkspace()
        let root = workspace.rootTilingContainer
        let tile = TestWindow.new(id: 1, parent: root)
        let group = TilingContainer.newVTiles(parent: root, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        group.layout = .tabGroup
        let background = TestWindow.new(id: 2, parent: group)
        let active = TestWindow.new(id: 3, parent: group)
        active.markAsMostRecentChild()

        XCTAssertFalse(windowIsHiddenFromView(tile))
        XCTAssertFalse(windowIsHiddenFromView(active))
        XCTAssertTrue(windowIsHiddenFromView(background), "A save prompt on a parked tab would be off screen")

        _ = Workspace.get(byName: "other").focusWorkspace()
        XCTAssertTrue(windowIsHiddenFromView(tile))
    }

    func testMiddleClickSettingDefaultsOnAndParses() {
        XCTAssertTrue(defaultConfig.middleClickClosesWindows)
        let (parsed, errors) = parseConfig("middle-click-closes-windows = false")
        XCTAssertEqual(errors.descriptions, [])
        XCTAssertFalse(parsed.middleClickClosesWindows)
    }
}
