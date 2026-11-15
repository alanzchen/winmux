@testable import AppBundle
import AppKit
import Common
import XCTest

/// Reproducing XCTests for the 4 BLOCK findings in REVIEW-3.md on commit 6d38e167.
/// Synthetic throughout: no live apps, no personal windows, no external environment dependencies.
@MainActor
final class Review3BlockReproTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        setSavedWorkspaceTestEnvironment()
        resetWorkspaceTabsForTests()
        AuxiliaryWindowRegistry.shared.removeAll()
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        workspaceSidebarOrganizationStore = .init()
    }

    override func tearDown() async throws {
        AuxiliaryWindowRegistry.shared.removeAll()
        workspaceSidebarOrganizationStore = .init()
        setMonitorsForTests(nil)
        config = defaultConfig
    }

    // MARK: - BLOCK 1: Hiding an app (Cmd-H / Hide Others) resurrects set-aside hide-on-close ghosts

    /// WindowLiveness.swift:330 (`presentable[windowId] = appHidden || !windowServer.listsOrderedOut(windowId)`)
    /// and NotPresentableWindows.swift:25 (`&& !appHidden`) treat `appHidden == true` as positive evidence that
    /// an unbound window is presentable, instead of leaving prior `isNotPresentable` unchanged while ordering is
    /// unobservable (SLSWindowIsOrderedIn == 0 for all windows of a hidden app).
    /// When the user later presses Cmd-Opt-H (Hide Others) or Cmd-H, `bringBackPresentableWindows`
    /// (normalizeLayoutReason.swift:8, NotPresentableWindows.swift:46) rebinds the closed hide-on-close ghost back
    /// into its tab's tiling tree and resurrects its empty ordinary tab in the sidebar.
    func testBlock1aHidingAppResurrectsSetAsideHideOnCloseGhostIntoTabAndSidebar() async throws {
        let wechat = Workspace.get(byName: "wechat")
        let ghost = TestWindow.new(id: 3269, parent: wechat.rootTilingContainer)
        let other = Workspace.get(byName: "other")
        _ = TestWindow.new(id: 1, parent: other.rootTilingContainer)
        var wechatRegistry: [UInt32: FakeLivenessWindow] = [3269: .init((nil, .illegalArgument))]

        // Refresh 1: WeChat's closed window 3269 is ordered out with a stale element; it is set aside cleanly.
        try await refreshPresentability(&wechatRegistry, listed: [3269, 1], shown: [1], orderedOut: [3269], appLists: [])
        XCTAssertTrue(ghost.isNotPresentable)
        XCTAssertTrue(ghost.parent === macosNotPresentableWindowsContainer)
        XCTAssertFalse(workspaceTabIsShown(wechat))

        // Refresh 2: User presses Cmd-Opt-H ("Hide Others") while in another app, so WeChat becomes hidden.
        // Ordering is unobservable while hidden; a ghost already set aside must stay set aside.
        try await refreshPresentability(&wechatRegistry, listed: [3269, 1], shown: [1], orderedOut: [3269], appLists: [],
            appHidden: true)

        XCTAssertTrue(ghost.isNotPresentable, "Hiding an app must not clear isNotPresentable on an already set-aside ghost")
        XCTAssertTrue(ghost.parent === macosNotPresentableWindowsContainer,
            "Set-aside ghost 3269 must not be bound back into wechat.rootTilingContainer when its app hides")
        XCTAssertEqual(workspaceTabMembers(wechat).count, 0)
        XCTAssertFalse(workspaceTabIsShown(wechat), "Empty ordinary tab must stay unlisted when the ghost's app hides")
    }

    /// Same defect in an active split [Telegram 3269 | Slack 11074]: hiding Telegram (e.g. Cmd-Opt-H in Slack)
    /// puts the closed Telegram ghost back into the live split beside Slack.
    func testBlock1bHidingAppResurrectsSetAsideGhostIntoActiveSplit() async throws {
        let pin = Workspace.get(byName: "telegram")
        let telegram = TestWindow.new(id: 3269, parent: pin.rootTilingContainer)
        let split = Workspace.get(byName: "work")
        _ = TestWindow.new(id: 11074, parent: split.rootTilingContainer)
        try setWorkspaceSidebarTabsFavorite([pin], true)
        try splitPinnedTabWindowWithTab(pin, "work", placement: .left)
        try setWorkspaceSidebarTabFavorite(split, true)

        var telegramRegistry: [UInt32: FakeLivenessWindow] = [3269: .init((nil, .illegalArgument))]
        try await refreshPresentability(&telegramRegistry, listed: [3269, 11074], shown: [11074], orderedOut: [3269], appLists: [])
        XCTAssertTrue(telegram.parent === macosNotPresentableWindowsContainer)
        XCTAssertEqual(workspaceTabMembers(split).map(\.window.windowId), [11074])

        // User presses Cmd-Opt-H ("Hide Others") in Slack; Telegram is now hidden.
        try await refreshPresentability(&telegramRegistry, listed: [3269, 11074], shown: [11074], orderedOut: [3269],
            appLists: [], appHidden: true)

        XCTAssertTrue(telegram.parent === macosNotPresentableWindowsContainer,
            "Hiding Telegram must not restore closed ghost 3269 into the active split")
        XCTAssertEqual(workspaceTabMembers(split).map(\.window.windowId), [11074])
    }

    // MARK: - BLOCK 2: Tombstones bypassed during WindowServer post-close on-screen lag

    /// WindowLiveness.swift:354 and 387-389 waive `confirmedClosed` whenever
    /// `windowServer.evidence(for: windowId) == .listed(onShownSpace: true)`.
    /// Row 7 drops an on-screen window *precisely while* WindowServer still lags for seconds reporting
    /// `.listed(onShownSpace: true)`. If Slack hands out a live AX element for closed ID 9 during that lag
    /// (on focus via MacApp.swift:363 `mayRegister`, or in enumeration via WindowLiveness.swift:354),
    /// `confirmedClosed` lets 9 re-register with `ax == .alive`, erases its tombstone on commit (line 381),
    /// and Row 1 (`(.alive, _) -> .keep`) keeps the closed corpse forever even after WindowServer drops 9.
    func testBlock2TombstoneBypassedDuringWindowServerPostCloseOnScreenLag() throws {
        var ledger = WindowLivenessLedger<FakeLivenessWindow>()
        let live1 = FakeLivenessWindow((1, .success))
        let closing9 = FakeLivenessWindow((nil, .illegalArgument))

        // Refresh 1: Window 9 closed on screen; AXWindows omits 9, while WindowServer still lags (`shown: [1, 9]`).
        // Row 7 drops 9 and commits 9 into `confirmedClosed`.
        let lagSnapshot1 = livenessWindowServer(listed: [1, 9], shown: [1, 9])
        let decided1 = try refreshRegisteredAxWindows([1: live1, 9: closing9], frontmostAppBundleId: nil,
            windowServer: lagSnapshot1, listed: { [(UInt32(1), live1)] }, rebind: { _, fresh in fresh },
            register: { alive, id, element in alive[id] = element }, confirmedClosed: ledger.confirmedClosed, RunLoopJob())
        XCTAssertEqual(Set(decided1.dead.keys), [9])
        ledger.hold(decided1, of: lagSnapshot1)
        XCTAssertNotNil(ledger.commit(lagSnapshot1))
        XCTAssertEqual(ledger.confirmedClosed, [9])

        // Moments later, WindowServer still lags (`shown: [1, 9]`), and Slack hands out a live element for closed 9.
        let corpse9 = FakeLivenessWindow((9, .success))
        let lagSnapshot2 = livenessWindowServer(listed: [1, 9], shown: [1, 9])

        // 1. Focus registration gate (MacApp.swift:363): must reject closed 9 while WindowServer lags.
        XCTAssertFalse(ledger.mayRegister(9, windowServer: lagSnapshot2),
            "confirmedClosed must block focus re-registration of Row-7-closed window 9 during WindowServer on-screen lag")

        // 2. Enumeration gate (WindowLiveness.swift:354) + subsequent Row 1 immortality once WindowServer catches up.
        let decided2 = try refreshRegisteredAxWindows([1: live1], frontmostAppBundleId: nil,
            windowServer: lagSnapshot2, listed: { [(UInt32(1), live1), (UInt32(9), corpse9)] }, rebind: { _, fresh in fresh },
            register: { alive, id, element in alive[id] = element }, confirmedClosed: ledger.confirmedClosed, RunLoopJob())
        ledger.hold(decided2, of: lagSnapshot2)
        _ = ledger.commit(lagSnapshot2)

        // WindowServer finally finishes dropping 9 (`listed: [1], shown: [1]`), and AXWindows omits 9.
        let settledSnapshot = livenessWindowServer(listed: [1], shown: [1])
        let decided3 = try refreshRegisteredAxWindows(decided2.alive, frontmostAppBundleId: nil,
            windowServer: settledSnapshot, listed: { [(UInt32(1), live1)] }, rebind: { _, fresh in fresh },
            register: { alive, id, element in alive[id] = element }, confirmedClosed: ledger.confirmedClosed, RunLoopJob())
        XCTAssertNil(decided3.alive[9],
            "Closed window 9 must not survive as an immortal Row-1 zombie after WindowServer drops it")
    }

    // MARK: - BLOCK 3: Set-aside hide-on-close windows break pin reopen, recall, and drop

    /// NewWindowRequests.swift:190-192 (`runningAppHasWindows`) counts a set-aside window in
    /// `macosNotPresentableWindowsContainer` as an open window of the running app, turning `newWindowMethod`
    /// into `.unsupported` instead of `.reopen` when the user clicks an empty pinned/saved tab for WeChat,
    /// Telegram, FaceTime, Activity Monitor, or Slack; and `windowIdsBeforeReopen` (lines 178-184) puts the
    /// set-aside ID into `preexistingWindowIds`, preventing a reopen intent from claiming it.
    func testBlock3aSetAsideHideOnCloseWindowBlocksReopeningRunningAppFromPin() async throws {
        let pin = Workspace.get(byName: "telegram")
        try setWorkspaceSidebarTabsFavorite([pin], true)
        let ghost = TestWindow.new(id: 3269, parent: pin.rootTilingContainer)
        var registry: [UInt32: FakeLivenessWindow] = [3269: .init((nil, .illegalArgument))]

        try await refreshPresentability(&registry, listed: [3269, 1], shown: [1], orderedOut: [3269], appLists: [])
        XCTAssertTrue(ghost.parent === macosNotPresentableWindowsContainer)
        XCTAssertTrue(ghost.isNotPresentable)

        let hasOpenWindows = runningAppHasWindows(pid: ghost.app.pid, windows: [ghost])
        XCTAssertFalse(hasOpenWindows,
            "A running app whose only window is set aside in macosNotPresentableWindowsContainer has no open presentable window")
        XCTAssertEqual(
            newWindowMethod(bundleId: "ru.keepcoder.Telegram", isRunning: true,
                reopensWhenWindowless: !hasOpenWindows, menuFallbackEnabled: false),
            .reopen,
            "Clicking a pinned hide-on-close app's empty tile must reopen the app (.reopen), not fail (.unsupported)"
        )
        XCTAssertEqual(
            windowIdsBeforeReopen(pid: ghost.app.pid, registered: [ghost], onScreen: { _ in [] }),
            [],
            "An off-screen window the app hid on close must not be in preexistingWindowIds before reopen"
        )
    }

    /// WorkspaceSidebarPinLending.swift:114-118 (`workspaceSidebarLentWindow`), 162 (`workspaceSidebarPinSplitRole`),
    /// 684-697 (`workspaceSidebarAwayWindows`), and 705-710 (`workspaceSidebarPinRecallsWindows`) treat a set-aside
    /// not-presentable ghost as an active lent/elsewhere window:
    /// 1. The pin's view model sets `lentWindow = nil` (rendering "Open Telegram") yet `recallsWindows = true`
    ///    (bypassing `onOpenSavedApps` at WorkspaceSidebarPinnedTab.swift:151 in favor of `onRecall` -> `.nothing`).
    /// 2. `workspaceSidebarPinSplitRole(pin)` returns `.refuses` instead of `.empty`, refusing drops on an empty pin.
    /// 3. An empty pinned split whose member is set aside reports `.recalled([], elsewhere: [ghost])` ("open elsewhere").
    func testBlock3bPinAndPinnedSplitTreatSetAsideGhostAsActiveLentAndElsewhereWindow() async throws {
        let pin = Workspace.get(byName: "telegram")
        let telegram = TestWindow.new(id: 3269, parent: pin.rootTilingContainer)
        let split = Workspace.get(byName: "work")
        let slack = TestWindow.new(id: 11074, parent: split.rootTilingContainer)
        try setWorkspaceSidebarTabsFavorite([pin], true)
        try splitPinnedTabWindowWithTab(pin, "work", placement: .left)
        try setWorkspaceSidebarTabFavorite(split, true)

        var registry: [UInt32: FakeLivenessWindow] = [
            3269: .init((nil, .illegalArgument)),
            11074: .init((11074, .success)),
        ]
        try await refreshPresentability(&registry, listed: [3269, 11074], shown: [11074], orderedOut: [3269],
            appLists: [(11074, .init((11074, .success)))])
        syncWorkspaceSidebarPinCompositions()
        XCTAssertTrue(telegram.parent === macosNotPresentableWindowsContainer)

        let models = await buildWorkspaceSidebarWorkspaceViewModels(currentFocus: focus, workspaceLabels: [:],
            availableMonitors: monitors)
        let pinModel = try XCTUnwrap(models.first { $0.name == "telegram" })
        XCTAssertNil(pinModel.lentWindow)
        XCTAssertFalse(pinModel.recallsWindows,
            "Empty pin whose lent window is not presentable must not set recallsWindows=true (which bypasses onOpenSavedApps)")
        XCTAssertEqual(workspaceSidebarPinSplitRole(pin), .empty,
            "Visibly empty pin whose lent window is hidden on close should accept drops (.empty), not .refuses")

        // Now Slack closes too, leaving the pinned split `work` visibly empty while 3269 remains set aside.
        letGoOfGoneWindow(slack)
        Workspace.reconcileWorkspaceState()
        XCTAssertTrue(workspaceSidebarPinResourceWindows(split).isEmpty)
        XCTAssertFalse(workspaceSidebarPinRecallsWindows(split),
            "Empty pinned split whose only remaining window is not presentable has nothing open to recall or warn about")
        XCTAssertEqual(try recallWorkspaceSidebarPinWindows(split), .nothing,
            "Set-aside ghost must not be reported as open `elsewhere`")
    }

    // MARK: - BLOCK 4: On-screen saved/renamed/topic ordinary tab stays stuck on screen when set aside

    /// NotPresentableWindows.swift:33-40 (`setAsideNotPresentableWindow`), WorkspaceTabs.swift:118-137
    /// (`workspaceTabWasLeftEmptyIgnoringLauncher` / `leaveTabsLeftEmptyOnScreen`), and
    /// SavedWorkspaceLifecycle.swift:12-30: when the last window of an on-screen saved ordinary tab (renamed,
    /// grouped, or automatic topic-named) is set aside as not presentable, `workspaceTabIsShown(tab)` becomes
    /// `false` (hiding the tab from the sidebar), while `workspaceTabWasLeftEmpty(tab)` stays `false`, leaving
    /// the empty unlisted workspace stuck active on screen instead of switching to the neighboring tab.
    func testBlock4OnScreenSavedOrdinaryTabStaysStuckOnScreenWhenLastWindowIsSetAside() async throws {
        let other = focus.workspace
        _ = TestWindow.new(id: 1, parent: other.rootTilingContainer)
        let wechat = Workspace.get(byName: "wechat")
        let ghost = TestWindow.new(id: 3269, parent: wechat.rootTilingContainer)
        try saveWorkspaceForSidebar(workspaceName: wechat.name, displayName: "WeChat")
        XCTAssertTrue(ghost.focusWindow())
        Workspace.reconcileWorkspaceState()
        XCTAssertTrue(wechat.isVisible)

        var wechatRegistry: [UInt32: FakeLivenessWindow] = [3269: .init((nil, .illegalArgument))]
        try await refreshPresentability(&wechatRegistry, listed: [3269, 1], shown: [1], orderedOut: [3269], appLists: [])
        Workspace.reconcileWorkspaceState()

        XCTAssertFalse(workspaceTabIsShown(wechat), "Unlisted in the sidebar")
        XCTAssertFalse(wechat.isVisible,
            "An ordinary tab hidden from the sidebar because its last window was set aside must leave the screen")
        XCTAssertTrue(other.isVisible, "Neighboring tab with live window 1 must take over the display")
    }
}
