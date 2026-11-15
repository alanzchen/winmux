@testable import AppBundle
import AppKit
import Common
import XCTest

/// Synthetic round-4 review reproducers for candidate d3a9dbe9. No live apps or personal windows.
@MainActor
final class Review4BlockReproTest: XCTestCase {
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

    // MARK: R4-1 — Row-7 drop while WindowServer lags onScreen schedules no recheck to observe offScreen

    /// Evidence table row 7 drops a hide-on-close window (`9`) when its AX element goes stale and `AXWindows`
    /// omits it while `WindowServer` still lags its `orderOut` (`sighting(9) == .onScreen`). `d3a9dbe9` puts `9`
    /// into `confirmedClosed` with `closedSeenOffScreen == []`, requiring a later committed refresh to observe
    /// `sighting(9) == .offScreen` before `9` can ever be re-admitted on reopen.
    ///
    /// However, `case .drop:` (`WindowLiveness.swift:349-350`) leaves `awaitsWindowServer` empty and
    /// `asksForConfirmation == false`, so `scheduleWindowLivenessChecks` (`layout/refresh.swift:551-555`) schedules
    /// zero follow-up refreshes. When `WindowServer` silently finishes ordering `9` out (`kCGWindowIsOnscreen = false`),
    /// no macOS notification fires and no refresh observes `.offScreen`; when the user later reopens the app and `9`
    /// returns `.onScreen`, both `mayRegister` and every subsequent barrier refresh permanently reject `9`.
    func testRow7DropWhileWindowServerShowsOnScreenSchedulesFollowUpOrReadmitsReopenedWindow() throws {
        var ledger = WindowLivenessLedger<FakeLivenessWindow>()
        var recheck = WindowLivenessRecheck()
        let live1 = FakeLivenessWindow((1, .success))

        // Refresh 1 (on close): Window 9's AX element is gone and AXWindows omits it, while WindowServer still
        // lists 9 as onScreen. Row 7 drops 9 and commits confirmedClosed = [9], closedSeenOffScreen = [].
        let closingServer = livenessWindowServer(listed: [1, 9], shown: [1, 9])
        let closeRefresh = try refreshRegisteredAxWindows(
            [1: live1, 9: FakeLivenessWindow((nil, .illegalArgument))],
            frontmostAppBundleId: nil,
            windowServer: closingServer,
            listed: { [(UInt32(1), live1)] },
            rebind: { _, fresh in fresh },
            register: { alive, id, element in alive[id] = element },
            confirmedClosed: ledger.confirmedClosed,
            closedSeenOffScreen: ledger.closedSeenOffScreen,
            RunLoopJob(),
        )
        XCTAssertEqual(Set(closeRefresh.dead.keys), [9])
        ledger.hold(closeRefresh, of: closingServer)
        _ = ledger.commit(closingServer)
        XCTAssertEqual(ledger.confirmedClosed, [9])
        XCTAssertEqual(ledger.closedSeenOffScreen, [])

        // Simulate scheduleWindowLivenessChecks: only runs follow-up refreshes that Refresh 1 actually requested.
        let followUpScheduled = closeRefresh.asksForConfirmation || recheck.next(awaiting: closeRefresh.awaitsWindowServer) != nil
        if followUpScheduled {
            // If Refresh 1 scheduled a recheck, that recheck observes WindowServer after orderOut finishes (offScreen).
            let offScreenServer = livenessWindowServer(listed: [1, 9], shown: [1], orderedOut: [9])
            let recheckRefresh = try refreshRegisteredAxWindows(
                [1: live1],
                frontmostAppBundleId: nil,
                windowServer: offScreenServer,
                listed: { [(UInt32(1), live1)] },
                rebind: { _, fresh in fresh },
                register: { alive, id, element in alive[id] = element },
                confirmedClosed: ledger.confirmedClosed,
                closedSeenOffScreen: ledger.closedSeenOffScreen,
                RunLoopJob(),
            )
            ledger.hold(recheckRefresh, of: offScreenServer)
            _ = ledger.commit(offScreenServer)
        }

        XCTAssertTrue(
            followUpScheduled,
            "Row-7 drop while WindowServer still lists 9 onScreen must schedule a recheck so closedSeenOffScreen can observe orderOut",
        )

        // Later, the user reopens the hide-on-close app: WindowServer shows 9 onScreen again and AXWindows vends a live element.
        let reopenedElement = FakeLivenessWindow((9, .success))
        let reopenedServer = livenessWindowServer(listed: [1, 9], shown: [1, 9])
        XCTAssertTrue(
            ledger.mayRegister(9, windowServer: reopenedServer),
            "Reopened hide-on-close window must be registrable on focus once WindowServer ordered it out and back in",
        )
        let reopenRefresh = try refreshRegisteredAxWindows(
            [1: live1],
            frontmostAppBundleId: nil,
            windowServer: reopenedServer,
            listed: { [(UInt32(1), live1), (UInt32(9), reopenedElement)] },
            rebind: { _, fresh in fresh },
            register: { alive, id, element in alive[id] = element },
            confirmedClosed: ledger.confirmedClosed,
            closedSeenOffScreen: ledger.closedSeenOffScreen,
            RunLoopJob(),
        )
        ledger.hold(reopenRefresh, of: reopenedServer)
        _ = ledger.commit(reopenedServer)
        XCTAssertTrue(
            reopenRefresh.alive[9] === reopenedElement,
            "Reopened hide-on-close window must be re-admitted by barrier refresh instead of locked out forever on screen",
        )
    }

    // MARK: R4-2a — Fast-path activation/focus events leave a reopened set-aside window trapped

    /// When a hide-on-close app (Telegram, WeChat, Activity Monitor) re-shows its existing `NSWindow` via
    /// Spotlight, app hotkey, Cmd-Tab, or menu bar (`makeKeyAndOrderFront` at its existing frame), macOS emits
    /// `NSWorkspace.didActivateApplicationNotification` and `kAXFocusedWindowChangedNotification` — neither of
    /// which sets `windowRefreshBarrier` or `layoutReasonNormalization`. Even though `nativeFocused` in
    /// `runRefreshSessionBlocking` is a window currently set aside in `macosNotPresentableWindowsContainer`,
    /// WinMux skips refresh and normalization, leaving the focused window trapped set aside and poisoning
    /// `lastKnownNativeFocusedWindowId`.
    func testActivatingAndFocusingReopenedSetAsideWindowRestoresAndFocusesIt() async throws {
        let main = focus.workspace
        let other = TestWindow.new(
            id: 100,
            parent: main.rootTilingContainer,
            rect: Rect(topLeftX: 0, topLeftY: 0, width: 800, height: 600),
        )
        let telegramApp = TestApp(pid: 2222, bundleId: "org.telegram.desktop", name: "Telegram")
        let telegram = TestWindow.new(
            id: 200,
            parent: main.rootTilingContainer,
            rect: Rect(topLeftX: 800, topLeftY: 0, width: 800, height: 600),
            app: telegramApp,
        )

        _ = other.focusWindow()
        appForTests = TestApp.shared
        TestApp.shared.focusedWindow = other
        try await runRefreshSessionBlocking(.ax(kAXFocusedWindowChangedNotification as String), layoutWorkspaces: false)
        XCTAssertEqual(focus.windowOrNil?.windowId, 100)

        // Telegram closes window 200 via hide-on-close (ordered out, stale AX element) -> set aside.
        var liveness: [UInt32: FakeLivenessWindow] = [
            100: .init((100, .success)),
            200: .init((nil, .illegalArgument)),
        ]
        try await refreshPresentability(
            &liveness,
            listed: [100, 200],
            shown: [100],
            orderedOut: [200],
            appLists: [(100, .init((100, .success)))],
        )
        XCTAssertTrue(telegram.parent === macosNotPresentableWindowsContainer)
        XCTAssertTrue(telegram.isNotPresentable)

        // Whenever a refresh barrier actually runs, WindowServer now reports 200 ordered in again.
        setBlockingRefreshOverridesForTests(refresh: {
            noteWindowPresentability([100: true, 200: true])
        })

        // User reopens Telegram via hotkey / Spotlight: Telegram activates and focuses existing window 200.
        appForTests = telegramApp
        telegramApp.focusedWindow = telegram
        try await runRefreshSessionBlocking(
            .globalObserver(NSWorkspace.didActivateApplicationNotification.rawValue),
            activatedAppPid: telegramApp.pid,
        )
        try await runRefreshSessionBlocking(.ax(kAXFocusedWindowChangedNotification as String))

        XCTAssertFalse(
            telegram.parent === macosNotPresentableWindowsContainer,
            "A set-aside window that becomes macOS native focus on activation/focus must not stay trapped in macosNotPresentableWindowsContainer",
        )
        XCTAssertTrue(telegram.parent === main.rootTilingContainer)
        XCTAssertEqual(focus.windowOrNil?.windowId, 200, "Reopened natively focused window must receive WinMux logical focus")
    }

    // MARK: R4-2b — Barrier refresh restoring a focused set-aside window fails to focus it and steals native focus back

    /// Even when a full barrier refresh runs while a reopened set-aside window is natively focused (for example
    /// `.globalObserverLeftMouseUp` on a Dock click), `runRefreshSessionBlocking` runs `updateFocusCache(nativeFocused)`
    /// at line 223 BEFORE `refresh()` (line 235) and `normalizeLayoutReason()` (line 245). At line 223 `telegram` is
    /// still in `macosNotPresentableWindowsContainer` (`visualWorkspace == nil`), so `focusWindow()` fails while
    /// `lastKnownNativeFocusedWindowId` is set to `200`. Then `bringBackPresentableWindows` restores `telegram` into
    /// its tab (`chat`) without updating `focus`, `layoutWorkspaces()` leaves `chat` off screen, and line 275 sees
    /// `telegram.participatesInWorkspaceFocus == true` with `logicalFocused == other` and calls `other.nativeFocus()`,
    /// stealing macOS focus away from the window the user just reopened.
    func testBarrierRefreshRestoringNativelyFocusedSetAsideWindowFocusesItsTabInsteadOfStealingFocusBack() async throws {
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

        _ = other.focusWindow()
        appForTests = TestApp.shared
        TestApp.shared.focusedWindow = other
        try await runRefreshSessionBlocking(.ax(kAXFocusedWindowChangedNotification as String), layoutWorkspaces: false)
        XCTAssertEqual(focus.windowOrNil?.windowId, 100)

        var liveness: [UInt32: FakeLivenessWindow] = [
            100: .init((100, .success)),
            200: .init((nil, .illegalArgument)),
        ]
        try await refreshPresentability(
            &liveness,
            listed: [100, 200],
            shown: [100],
            orderedOut: [200],
            appLists: [(100, .init((100, .success)))],
        )
        Workspace.reconcileWorkspaceState()
        XCTAssertTrue(telegram.parent === macosNotPresentableWindowsContainer)
        XCTAssertTrue(main.isVisible)

        let otherNativeFocusCountBefore = other.nativeFocusCount
        setBlockingRefreshOverridesForTests(refresh: {
            noteWindowPresentability([100: true, 200: true])
        })

        // Telegram orders 200 back on screen and focuses it; a full barrier refresh runs.
        appForTests = telegramApp
        telegramApp.focusedWindow = telegram
        try await runRefreshSessionBlocking(.globalObserverLeftMouseUp)

        XCTAssertTrue(telegram.parent === chat.rootTilingContainer)
        XCTAssertEqual(
            other.nativeFocusCount,
            otherNativeFocusCountBefore,
            "Restoring a natively focused set-aside window must not sync focus back to the previous window and steal macOS focus",
        )
        XCTAssertEqual(focus.windowOrNil?.windowId, 200, "Restored natively focused window must become logical focus")
        XCTAssertTrue(chat.isVisible, "Restored natively focused window's tab must be brought onto the display")
    }
}
