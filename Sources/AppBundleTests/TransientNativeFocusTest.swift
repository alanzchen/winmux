@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor
final class TransientNativeFocusTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        TrayMenuModel.shared.isEnabled = true
        appForTests = TestApp.shared
    }

    func testModalFocusLeavesLogicalFocusAndWorkspaceIntactAcrossRefreshes() async throws {
        let workspace = focus.workspace
        let browser = TestWindow.new(id: 1, parent: workspace, rect: Rect(topLeftX: 80, topLeftY: 80, width: 800, height: 600))
        _ = browser.focusWindow()
        TestApp.shared.focusedWindow = browser
        try await runRefreshSessionBlocking(.ax(kAXFocusedWindowChangedNotification as String))

        TestApp.shared.focusedWindow = nil
        TestApp.shared.hasActiveTransientNativeFocus = true
        let initialRect = try await browser.getAxRect()
        for _ in 0 ..< 3 {
            try await runRefreshSessionBlocking(.ax(kAXFocusedWindowChangedNotification as String))
            XCTAssertTrue(focus.windowOrNil === browser)
            XCTAssertTrue(focus.workspace === workspace)
            XCTAssertNil(TestApp.shared.focusedWindow, "WinMux must not replace native modal focus")
        }
        let finalRect = try await browser.getAxRect()
        XCTAssertEqual(initialRect, finalRect)

        TestApp.shared.hasActiveTransientNativeFocus = false
        TestApp.shared.focusedWindow = browser
        try await runRefreshSessionBlocking(.ax(kAXFocusedWindowChangedNotification as String))
        XCTAssertTrue(focus.windowOrNil === browser)
    }

    func testLightSessionDoesNotReactivateWindowOverNativeModalInteraction() async throws {
        let first = TestWindow.new(id: 1, parent: focus.workspace)
        let second = TestWindow.new(id: 2, parent: focus.workspace)
        _ = first.focusWindow()
        TestApp.shared.hasActiveTransientNativeFocus = true
        try await runLightSession(.ax(kAXFocusedWindowChangedNotification as String), .forceRun, shouldSchedulePostRefresh: false) {
            _ = second.focusWindow()
        }
        XCTAssertTrue(focus.windowOrNil === second)
        XCTAssertNil(TestApp.shared.focusedWindow, "Explicit model changes must not dismiss a native panel during the refresh")
    }

    func testRoutingCallbacksExcludePopupsButKeepIndependentFloatingDialogs() async throws {
        let workspace = focus.workspace
        let (parsed, errors) = parseConfig("""
        [[on-window-detected]]
        if.app-id = 'bobko.WinMux.test-app'
        if.during-winmux-startup = false
        run = ['move-node-to-workspace z']
        """)
        XCTAssertTrue(errors.isEmpty)
        config.onWindowDetected = parsed.onWindowDetected
        let popup = TestWindow.new(id: 1, parent: macosPopupWindowsContainer)
        try await tryOnWindowDetected(popup)
        XCTAssertTrue(popup.parent === macosPopupWindowsContainer)
        XCTAssertNil(Workspace.existing(byName: "z"))

        let dialog = TestWindow.new(id: 2, parent: workspace)
        try await tryOnWindowDetected(dialog)
        XCTAssertEqual(dialog.nodeWorkspace?.name, "z")
        XCTAssertTrue(dialog.isFloating)
        XCTAssertTrue(focus.workspace === workspace)
    }
}
