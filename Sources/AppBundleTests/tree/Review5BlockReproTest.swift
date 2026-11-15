@testable import AppBundle
import AppKit
import Common
import XCTest

/// Synthetic round-5 review reproducer for candidate a269fd0b. No live apps or personal windows.
@MainActor
final class Review5BlockReproTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        resetFocusCacheForTests()
        TrayMenuModel.shared.isEnabled = true
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        workspaceSidebarOrganizationStore = .init()
        appForTests = TestApp.shared
        TestApp.shared.focusedWindow = nil
    }

    override func tearDown() async throws {
        setBlockingRefreshOverridesForTests()
        resetFocusCacheForTests()
        TestApp.shared.focusedWindow = nil
        appForTests = nil
        workspaceSidebarOrganizationStore = .init()
        config = defaultConfig
    }

    /// Remaining focus-steal path in R4-2 (`focusCache.swift:20-27`, `NotPresentableWindows.swift:61-83`,
    /// `layout/refresh.swift:257-260, 281-287`):
    ///
    /// When the user closes a hide-on-close window (`telegram`, ID `200`) while it IS the focused window,
    /// `lastKnownNativeFocusedWindowId` is `200`. If the refresh session that sets `200` aside still observes
    /// `200` at session entry (for example `.globalObserverLeftMouseUp` on its close button before `orderOut:`
    /// clears `kAXFocusedWindow`, or `MacApp.getFocusedWindow()` falling back to `lastNativeFocusedWindow()` on
    /// its 0.25 s timeout), `200` is moved to `macosNotPresentableWindowsContainer`, `leaveTabsLeftEmptyOnScreen()`
    /// moves logical `focus` and the display to `main` (`other`, ID `100`), `shouldSyncFocusBackToMacOs` returns
    /// `false` (`200.isSetAsideAsNotPresentable == true`), and `lastKnownNativeFocusedWindowId` stays `200`.
    ///
    /// When the user then reopens `telegram` (`200`), `focusedSetAside` forces `refresh()` and
    /// `normalizeLayoutReason()`, restoring `200` to `chat`, and calls `updateFocusCache(telegram)` at
    /// `layout/refresh.swift:258`. Because `lastKnownNativeFocusedWindowId` is STILL `200`, `200 != 200` is
    /// `false`, `telegram.focusWindow()` is skipped, `chat` stays off screen, and line `286` calls
    /// `other.nativeFocus()` — stealing macOS focus back to `other` on both session runs.
    func testReopeningWindowSetAsideWhileFocusedDoesNotSkipFocusOrStealNativeFocusBack() async throws {
        let main = focus.workspace
        let other = TestWindow.new(
            id: 100,
            parent: main.rootTilingContainer,
            rect: Rect(topLeftX: 0, topLeftY: 0, width: 800, height: 600),
        )
        let chat = Workspace.get(byName: "chat")
        let telegramApp = TestApp(pid: 2222, bundleId: "org.telegram.desktop", name: "Telegram")
        let telegram = TestWindow.new(
            id: 200,
            parent: chat.rootTilingContainer,
            rect: Rect(topLeftX: 100, topLeftY: 100, width: 800, height: 600),
            app: telegramApp,
        )

        // 1. User is working in Telegram (window 200 in tab "chat"), so lastKnownNativeFocusedWindowId == 200.
        _ = telegram.focusWindow()
        appForTests = telegramApp
        telegramApp.focusedWindow = telegram
        try await runHeavyCompleteRefreshSession(.ax(kAXFocusedWindowChangedNotification as String))
        XCTAssertEqual(focus.windowOrNil?.windowId, 200)
        XCTAssertTrue(chat.isVisible)

        // 2. User clicks Telegram's close button: leftMouseUp session observes 200 at entry, refresh() sees 200
        //    ordered out, normalizeLayoutReason() sets 200 aside, and leaveTabsLeftEmptyOnScreen() hands the
        //    display and logical focus to "main" (window 100) while lastKnownNativeFocusedWindowId remains 200.
        setBlockingRefreshOverridesForTests(refresh: {
            noteWindowPresentability([100: true, 200: false])
        })
        try await runHeavyCompleteRefreshSession(.globalObserverLeftMouseUp)
        XCTAssertTrue(telegram.parent === macosNotPresentableWindowsContainer)
        XCTAssertTrue(main.isVisible)
        XCTAssertEqual(focus.windowOrNil?.windowId, 100)

        // 3. User reopens Telegram (hotkey / Spotlight / Dock): 200 is ordered back in and natively focused.
        let otherNativeFocusCountBefore = other.nativeFocusCount
        setBlockingRefreshOverridesForTests(refresh: {
            noteWindowPresentability([100: true, 200: true])
        })
        appForTests = telegramApp
        telegramApp.focusedWindow = telegram
        try await runHeavyCompleteRefreshSession(
            .globalObserver(NSWorkspace.didActivateApplicationNotification.rawValue),
            activatedAppPid: telegramApp.pid,
        )

        XCTAssertTrue(telegram.parent === chat.rootTilingContainer)
        XCTAssertEqual(
            other.nativeFocusCount,
            otherNativeFocusCountBefore,
            "Restoring a set-aside window that was focused when closed must not steal macOS focus back to the neighbor tab's window",
        )
        XCTAssertEqual(
            focus.windowOrNil?.windowId,
            200,
            "Restored natively focused window must regain logical focus even when lastKnownNativeFocusedWindowId still held 200",
        )
        XCTAssertTrue(chat.isVisible, "Restored natively focused window's tab must come back on screen")
    }
}
