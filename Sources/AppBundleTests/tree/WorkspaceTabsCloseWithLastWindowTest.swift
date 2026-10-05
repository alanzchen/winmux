@testable import AppBundle
import AppKit
import Common
import XCTest

/// Tabs mode: a tab that isn't pinned closes once its last window closes, rather than staying
/// greyed, whether it's saved (renamed, grouped, made from a topic) or not, and whether its app
/// keeps running or quits.
@MainActor
final class WorkspaceTabsCloseWithLastWindowTest: XCTestCase {
    private var defaultAppIsFrontmost: (@MainActor (Window) -> Bool)?
    private var wasEnabled = true
    private var clock = savedTestNow
    private var frontmost: String?
    private let editorId = "com.test.editor"
    /// Running since long before WinMux started, so it's never armed.
    private lazy var editor = TestApp(pid: 501, bundleId: editorId, name: "Editor", launchDate: savedTestNow.addingTimeInterval(-86400))
    private let other = TestApp(pid: 600, bundleId: "com.test.other", name: "Other")
    private let third = TestApp(pid: 700, bundleId: "com.test.third", name: "Third")
    private lazy var running: [String: [SavedRunningApp]] = [
        editorId: [SavedRunningApp(pid: 501, launchDate: savedTestNow.addingTimeInterval(-86400))],
        "com.test.other": [SavedRunningApp(pid: 600, launchDate: savedTestNow.addingTimeInterval(-86400))],
        "com.test.third": [SavedRunningApp(pid: 700, launchDate: savedTestNow.addingTimeInterval(-86400))],
    ]

    override func setUp() async throws {
        defaultAppIsFrontmost = newWindowAppIsFrontmost
        wasEnabled = TrayMenuModel.shared.isEnabled
        setUpWorkspacesForTests()
        resetWorkspaceTabsForTests()
        savedWorkspaceRuntime.environment = SavedWorkspaceEnvironment(
            now: { [unowned self] in clock },
            runningApps: { [unowned self] in running },
            openApplication: { _, _ in false },
            frontmostAppBundleId: { [unowned self] in frontmost },
        )
        savedWorkspaceRuntime.runtimeReadyAt = clock.addingTimeInterval(-3600)
        workspaceSidebarOrganizationStore = .init()
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        replaceClosedWindowsCache(FrozenWorld(workspaces: [], monitors: [], windowIds: []))
        NewWindowIntentRegistry.shared.resetForTests()
        newWindowAppIsFrontmost = { _ in false }
    }

    override func tearDown() async throws {
        if let defaultAppIsFrontmost { newWindowAppIsFrontmost = defaultAppIsFrontmost }
        TrayMenuModel.shared.isEnabled = wasEnabled
        setBlockingRefreshOverridesForTests()
        setServerReadOnlyForTests(false)
        WorkspaceTabClosePolicy.waitsForAppRelaunch = false
        NewWindowIntentRegistry.shared.resetForTests()
        workspaceSidebarOrganizationStore = .init()
        setMonitorsForTests(nil)
        config = defaultConfig
    }

    /// Tabs a, b and c, in that order, with a on screen. b has the editor's window 2; a and c have
    /// another app's windows 1 and 3.
    private func threeTabs() -> (a: Workspace, b: Workspace, c: Workspace, window: Window) {
        let a = focus.workspace
        let b = Workspace.get(byName: "tab-b")
        let c = Workspace.get(byName: "tab-c")
        _ = TestWindow.new(id: 1, parent: a.rootTilingContainer, app: other)
        let window = TestWindow.new(id: 2, parent: b.rootTilingContainer, app: editor, title: "Notes")
        _ = TestWindow.new(id: 3, parent: c.rootTilingContainer, app: other)
        XCTAssertTrue(a.allLeafWindowsRecursive[0].focusWindow())
        Workspace.reconcileWorkspaceState()
        captureSavedWorkspaces(facts: facts())
        return (a, b, c, window)
    }

    private func facts(titles: [UInt32: String] = [:]) -> SavedWorkspaceCaptureFacts {
        savedTestFacts(now: clock, runningApps: running, titles: titles)
    }

    private func rename(_ tab: Workspace, _ label: String = "Notes") throws {
        try saveWorkspaceForSidebar(workspaceName: tab.name, displayName: label)
        XCTAssertEqual(config.workspaceSidebar.workspaceLabels[tab.name], label)
        XCTAssertTrue(tab.isKeptWhenEmpty)
        captureSavedWorkspaces(facts: facts())
    }

    /// The window closes, as the refresh that no longer finds it handles it, and something
    /// reconciles without listing windows again.
    private func close(_ window: Window) {
        window.removeClosedWindowFromTree()
        Workspace.reconcileWorkspaceState()
    }

    /// The windows vanish from one refresh together; `quit` are those whose app has terminated.
    private func vanishTogether(_ windows: [Window], quit: [Window] = []) {
        let closes = vanishedWindowsCloseTheirTabs(windows) { window in !quit.contains { $0 === window } }
        for window in windows { window.removeClosedWindowFromTree(closesItsTab: closes) }
        Workspace.reconcileWorkspaceState()
    }

    /// Time passes, and something reconciles without listing windows: a light session, or the
    /// start of a refresh session.
    private func later(_ seconds: TimeInterval) {
        clock = clock.addingTimeInterval(seconds)
        Workspace.reconcileWorkspaceState()
    }

    /// `seconds` later a refresh lists every window again, which takes `takes`. Windows in
    /// `returning` were found again; it registers them as it registers any window.
    private func listWindows(after seconds: TimeInterval = 0, takes: TimeInterval = 0, returning: [TestWindow] = []) async throws {
        clock = clock.addingTimeInterval(seconds)
        try await windowRefresh(takes: takes, returning: returning)
    }

    /// What a refresh session's window refresh does: lists and registers windows, then reconciles.
    private func windowRefresh(takes: TimeInterval = 0, returning: [TestWindow] = []) async throws {
        clock = clock.addingTimeInterval(takes)
        for window in returning { _ = try await restoreOrDetectNewWindow(window, isRegularWindow: true) }
        Workspace.reconcileWorkspaceState()
    }

    /// Window `id` of `app`, found again by a refresh: it shows up first on the tab on screen.
    private func foundAgain(_ id: UInt32, app: TestApp, title: String = "Notes") -> TestWindow {
        TestWindow.new(id: id, parent: focus.workspace.rootTilingContainer, app: app, title: title)
    }

    /// The editor quits.
    private func editorQuits() {
        running[editorId] = nil
    }

    private func assertClosed(_ tab: Workspace, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(Workspace.existing(byName: tab.name), "The tab closed", file: file, line: line)
        XCTAssertNil(savedWorkspaceStore.record(named: tab.name), "Its saved record went with it", file: file, line: line)
        XCTAssertNil(config.workspaceSidebar.workspaceLabels[tab.name], "and its label", file: file, line: line)
        XCTAssertNil(workspaceSidebarOrganizationStore.state.workspaces[tab.name], file: file, line: line)
        XCTAssertNil(workspaceSidebarOrganizationStore.collection(containing: tab.name), "and its place in a group",
            file: file, line: line)
    }

    private func assertStays(_ tab: Workspace, _ message: String = "The tab stays", file: StaticString = #filePath,
                             line: UInt = #line) {
        XCTAssertTrue(Workspace.existing(byName: tab.name) === tab, message, file: file, line: line)
        XCTAssertNotNil(savedWorkspaceStore.record(named: tab.name), file: file, line: line)
    }

    // MARK: It closes

    func testARenamedTabClosesWhenItsLastWindowClosesWhileItsAppKeepsRunning() async throws {
        let (_, b, _, window) = threeTabs()
        try rename(b)
        close(window)
        try await listWindows(after: 2)
        assertClosed(b)
    }

    func testAnAutomaticTabInAGroupClosesWithoutWaitingForTheClosedWindowsGrace() async throws {
        let (_, b, c, window) = threeTabs()
        let group = try workspaceSidebarOrganizationStore.create(projectId: b.projectId, workspaceNames: [])
        try assignWorkspaceToSidebarCollection(b, collectionId: group.id, keepWhenEmpty: false)
        try assignWorkspaceToSidebarCollection(c, collectionId: group.id)
        captureSavedWorkspaces(facts: facts())
        XCTAssertEqual(savedWorkspaceStore.record(named: b.name)?.layout.allSlots.count, 1)
        close(window)
        try await listWindows(after: 2)
        XCTAssertLessThan(2, SavedWorkspaceTiming.closedWindowGrace)
        assertClosed(b)
        XCTAssertEqual(workspaceSidebarOrganizationStore.state.collections.first?.workspaceNames, [c.name],
            "The group keeps its other tab")
    }

    func testATabInAGroupOfItsOwnClosesAndTheGroupFollowsItsUsualRules() async throws {
        let (_, b, _, window) = threeTabs()
        let group = try workspaceSidebarOrganizationStore.create(projectId: b.projectId, workspaceNames: [])
        try assignWorkspaceToSidebarCollection(b, collectionId: group.id)
        XCTAssertTrue(b.isKeptWhenEmpty, "Grouping saves the tab")
        close(window)
        try await listWindows(after: 2)
        assertClosed(b)
        XCTAssertEqual(workspaceSidebarOrganizationStore.state.collections.map(\.id), [group.id],
            "An empty group stays, as when its last tab is moved out")
    }

    func testATabMadeFromATopicClosesLikeAnyOther() async throws {
        let (_, b, _, window) = threeTabs()
        try ensureSavedWorkspaceRecord(b, keepWhenEmpty: true)
        close(window)
        try await listWindows(after: 2)
        assertClosed(b)
    }

    func testATabClosesWhenItsAppQuits() async throws {
        let (_, b, _, window) = threeTabs()
        try rename(b)
        editorQuits()
        vanishTogether([window], quit: [window])
        try await listWindows(after: 2)
        assertClosed(b)
    }

    func testATabWhoseOnlyWindowWasMinimizedClosesWhenItsAppQuits() async throws {
        let (_, b, _, window) = threeTabs()
        try rename(b)
        window.layoutReason = .macos(prevParentKind: .tilingContainer, prevWorkspaceName: b.name)
        window.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        try await listWindows(after: 2)
        assertStays(b)
        editorQuits()
        vanishTogether([window], quit: [window])
        try await listWindows(after: 2)
        assertClosed(b)
    }

    func testAnUnsavedTabStillClosesAtOnce() {
        let (_, b, _, window) = threeTabs()
        close(window)
        XCTAssertNil(Workspace.existing(byName: b.name), "As before: nothing of it is saved")
    }

    // MARK: Only a refresh that lists windows again closes a saved tab

    func testReconcilingWithoutListingWindowsKeepsATabNoRefreshHasCheckedYet() async throws {
        let (_, b, _, window) = threeTabs()
        try rename(b)
        close(window)
        later(5)
        assertStays(b)
        try await listWindows()
        assertClosed(b)
    }

    func testARefreshThatStartedBeforeTheMomentWasOverDoesntCloseTheTab() async throws {
        let (_, b, _, window) = threeTabs()
        try rename(b)
        close(window)
        try await listWindows(after: 0.5, takes: 2)
        assertStays(b)
        try await listWindows()
        assertClosed(b)
    }

    /// The refresh session the check schedules, which reconciles before it lists windows.
    private func runRefreshSession(returning: [TestWindow] = []) async throws {
        appForTests = TestApp.shared
        TrayMenuModel.shared.isEnabled = true
        setBlockingRefreshOverridesForTests(refresh: { [unowned self] in
            try await windowRefresh(returning: returning)
        }, normalizeLayoutReason: {})
        try await runRefreshSessionBlocking(.globalObserver("workspaceTabClose"), layoutWorkspaces: false)
    }

    func testTheRefreshSessionThatChecksATabFindsItsBackgroundWindowAgainBeforeAnythingCloses() async throws {
        let (_, b, _, window) = threeTabs()
        try rename(b)
        close(window)
        clock = clock.addingTimeInterval(2)
        try await runRefreshSession(returning: [foundAgain(2, app: editor)])
        assertStays(b)
        XCTAssertEqual(b.allLeafWindowsRecursive.map(\.windowId), [2], "Back in its tab")
        XCTAssertEqual(config.workspaceSidebar.workspaceLabels[b.name], "Notes")
    }

    func testTheRefreshSessionThatChecksATabClosesItWhenItsWindowIsStillGone() async throws {
        let (_, b, _, window) = threeTabs()
        try rename(b)
        close(window)
        clock = clock.addingTimeInterval(2)
        try await runRefreshSession()
        assertClosed(b)
    }

    // MARK: Windows that vanish together, and the lock screen

    func testTwoRealClosesInOneRefreshBothCloseOnceARefreshConfirmsThem() async throws {
        let (_, b, c, window) = threeTabs()
        try rename(b)
        try rename(c, "Mail")
        vanishTogether([window, try XCTUnwrap(c.allLeafWindowsRecursive.first)])
        try await listWindows(after: 2)
        assertStays(b, "Several running apps' windows went at once: it waits longer")
        assertStays(c)
        try await listWindows(after: 10)
        assertClosed(b)
        assertClosed(c)
    }

    func testAPopupVanishingAlongsideDoesntMakeAClosePending() async throws {
        let (_, b, _, window) = threeTabs()
        try rename(b)
        let popup = TestWindow.new(id: 9, parent: macosPopupWindowsContainer, app: other)
        vanishTogether([window, popup])
        try await listWindows(after: 2)
        assertClosed(b)
    }

    func testATabWhoseAppQuitClosesEvenWhenWindowsOfRunningAppsVanishedWithIt() async throws {
        let (_, b, c, window) = threeTabs()
        let d = Workspace.get(byName: "tab-d")
        let thirds = TestWindow.new(id: 4, parent: d.rootTilingContainer, app: third)
        Workspace.reconcileWorkspaceState()
        try rename(b)
        try rename(c, "Mail")
        try rename(d, "Music")
        editorQuits()
        vanishTogether([window, try XCTUnwrap(c.allLeafWindowsRecursive.first), thirds], quit: [window])
        try await listWindows(after: 2)
        assertClosed(b)
        assertStays(c)
        assertStays(d)
    }

    func testATabWaitingWhenTheScreenLocksClosesAfterUnlockIfItsWindowIsStillGone() async throws {
        let (_, b, _, window) = threeTabs()
        try rename(b)
        close(window)
        later(0.3)
        suspendSavedWorkspaceCapture(.screenLocked)
        try await listWindows(after: 2)
        assertStays(b)
        resumeSavedWorkspaceCapture(after: .screenLocked)
        try await listWindows(after: 0.2)
        assertStays(b, "Just unlocked: windows may not be back yet")
        try await listWindows(after: 2)
        assertClosed(b)
    }

    func testATabWaitingWhenTheScreenLocksStaysWhenItsWindowComesBackAfterUnlock() async throws {
        let (_, b, _, window) = threeTabs()
        try rename(b)
        close(window)
        later(0.3)
        suspendSavedWorkspaceCapture(.screenLocked)
        try await listWindows(after: 2)
        resumeSavedWorkspaceCapture(after: .screenLocked)
        try await listWindows(after: 0.2)
        try await listWindows(after: 0.2, returning: [foundAgain(2, app: editor)])
        try await listWindows(after: 2)
        assertStays(b)
        XCTAssertEqual(b.allLeafWindowsRecursive.map(\.windowId), [2])
    }

    func testTheLockScreenSeenByARefreshDefersTheCheckPastTheUnlock() async throws {
        let (_, b, _, window) = threeTabs()
        try rename(b)
        close(window)
        frontmost = lockScreenAppBundleId
        try await listWindows(after: 2)
        assertStays(b)
        frontmost = nil
        try await listWindows(after: 0.2)
        assertStays(b, "Just unlocked: windows may not be back yet")
        try await listWindows(after: 2)
        assertClosed(b)
    }

    // MARK: A relaunch whose windows wait for their titles

    func testAFastRelaunchsWindowsWaitingForTheirTitlesKeepTheirTabsAndGoBackToThem() async throws {
        TrayMenuModel.shared.isEnabled = true
        let a = focus.workspace
        let b = Workspace.get(byName: "tab-b")
        let d = Workspace.get(byName: "tab-d")
        _ = TestWindow.new(id: 1, parent: a.rootTilingContainer, app: other)
        let first = TestWindow.new(id: 2, parent: b.rootTilingContainer, app: editor, title: "Notes B")
        let second = TestWindow.new(id: 4, parent: d.rootTilingContainer, app: editor, title: "Notes C")
        XCTAssertTrue(a.allLeafWindowsRecursive[0].focusWindow())
        Workspace.reconcileWorkspaceState()
        try rename(b, "B")
        try rename(d, "C")
        captureSavedWorkspaces(facts: facts(titles: [2: "Notes B", 4: "Notes C"]))
        editorQuits()
        vanishTogether([first, second], quit: [first, second])

        let launched = clock
        running[editorId] = [SavedRunningApp(pid: 502, launchDate: launched)]
        let relaunched = TestApp(pid: 502, bundleId: editorId, name: "Editor", launchDate: launched)
        let windows = [TestWindow.new(id: 20, parent: a.rootTilingContainer, app: relaunched, title: ""),
                       TestWindow.new(id: 21, parent: a.rootTilingContainer, app: relaunched, title: "")]
        for window in windows { _ = try await restoreOrDetectNewWindow(window, isRegularWindow: true) }
        XCTAssertEqual(Set(savedWorkspaceRuntime.windowsAwaitingTitle.keys), [20, 21], "They wait for their titles")
        try await listWindows(after: 2)
        assertStays(b)
        assertStays(d)

        windows[0].customTitle = "Notes C"
        windows[1].customTitle = "Notes B"
        await retrySavedWorkspaceRoutingForWindowsAwaitingTitles()
        XCTAssertTrue(windows[0].nodeWorkspace === d)
        XCTAssertTrue(windows[1].nodeWorkspace === b)
        try await listWindows(after: 2)
        assertStays(b)
        assertStays(d)
        XCTAssertEqual(config.workspaceSidebar.workspaceLabels[b.name], "B")
    }

    // MARK: Focus

    func testClosingTheTabInUseMovesFocusToTheNextTabAsForAnyTab() async throws {
        let (_, b, c, window) = threeTabs()
        try rename(b)
        XCTAssertTrue(window.focusWindow())
        close(window)
        XCTAssertTrue(focus.workspace === c, "The next tab, as closing a browser tab does")
        try await listWindows(after: 2)
        assertClosed(b)
        XCTAssertTrue(c.isVisible)
    }

    func testClosingAGroupedTabMovesToTheNextTabTheSidebarShows() throws {
        let (a, b, c, _) = threeTabs()
        let group = try workspaceSidebarOrganizationStore.create(projectId: a.projectId, workspaceNames: [])
        try assignWorkspaceToSidebarCollection(a, collectionId: group.id)
        try assignWorkspaceToSidebarCollection(c, collectionId: group.id)
        XCTAssertEqual(orderedWorkspaces(in: a.projectId).map(\.name).suffix(3), [a.name, b.name, c.name])
        XCTAssertEqual(workspaceNavigationTabs(current: a).map(\.name).suffix(3), [a.name, c.name, b.name])
        let window = try XCTUnwrap(a.allLeafWindowsRecursive.first)
        XCTAssertTrue(window.focusWindow())
        close(window)
        XCTAssertTrue(focus.workspace === c, "The tab after it in the sidebar, in its group")
    }

    func testATabClosingOnAnotherDisplayGivesThatDisplayToItsNextTabWithoutTakingFocus() async throws {
        let left = SavedWorkspaceTestMonitor(id: 1, name: "Left", x: 0, isMain: true, uuid: "LEFT", isBuiltin: true)
        let right = SavedWorkspaceTestMonitor(id: 2, name: "Right", x: 1920, uuid: "RIGHT")
        setMonitorsForTests([left, right])
        let (a, b, c, window) = threeTabs()
        c.preferredMonitorPoint = right.rect.topLeftCorner
        XCTAssertTrue(right.setActiveWorkspace(b))
        XCTAssertTrue(a.allLeafWindowsRecursive[0].focusWindow())
        try rename(b)
        close(window)
        try await listWindows(after: 2)
        XCTAssertTrue(right.activeWorkspace === c, "The other display shows its next tab")
        XCTAssertTrue(focus.workspace === a, "Focus stays where it was")
        assertClosed(b)
    }

    func testTheOnlyTabOnADisplayLeavesItABlankTabAndCloses() async throws {
        let left = SavedWorkspaceTestMonitor(id: 1, name: "Left", x: 0, isMain: true, uuid: "LEFT", isBuiltin: true)
        let right = SavedWorkspaceTestMonitor(id: 2, name: "Right", x: 1920, uuid: "RIGHT")
        setMonitorsForTests([left, right])
        let (a, b, c, window) = threeTabs()
        c.preferredMonitorPoint = left.rect.topLeftCorner
        XCTAssertTrue(right.setActiveWorkspace(b))
        XCTAssertTrue(a.allLeafWindowsRecursive[0].focusWindow())
        try rename(b)
        editorQuits()
        vanishTogether([window], quit: [window])
        try await listWindows(after: 2)
        let shown = right.activeWorkspace
        XCTAssertFalse([a, b, c].contains { $0 === shown }, "A blank tab, not \(shown.name)")
        XCTAssertTrue(shown.isEffectivelyEmpty)
        XCTAssertEqual(shown.projectId, b.projectId)
        XCTAssertTrue(focus.workspace === a, "Focus stays where it was")
        assertClosed(b)

        running[editorId] = [SavedRunningApp(pid: 502, launchDate: clock)]
        let relaunched = TestApp(pid: 502, bundleId: editorId, name: "Editor", launchDate: clock)
        let next = TestWindow.new(id: 20, parent: a.rootTilingContainer, app: relaunched, title: "Notes")
        let restored = try await restoreOrDetectNewWindow(next, isRegularWindow: true)
        XCTAssertFalse(restored, "Nothing saved waits for it")
        XCTAssertNotEqual(next.nodeWorkspace?.name, b.name)
    }

    // MARK: It stays

    func testPinnedTabsStayAsTheirAppsHomes() async throws {
        let (_, b, c, window) = threeTabs()
        try setWorkspaceSidebarTabFavorite(b, true)
        try setWorkspaceSidebarTabPinScope(c, .allProjects, projectId: c.projectId)
        close(window)
        close(c.allLeafWindowsRecursive[0])
        try await listWindows(after: 2)
        assertStays(b)
        assertStays(c)
    }

    func testUnpinningAnEmptyPinLaterLeavesItAsBefore() async throws {
        let (_, b, _, window) = threeTabs()
        try setWorkspaceSidebarTabFavorite(b, true)
        close(window)
        try await listWindows(after: 2)
        try setWorkspaceSidebarTabFavorite(b, false)
        try await listWindows(after: 2)
        assertStays(b)
        XCTAssertTrue(b.isKeptWhenEmpty, "Its last window closed while it was a pin, which stays")
    }

    func testAConfiguredPersistentWorkspaceStays() async throws {
        let (_, b, _, window) = threeTabs()
        try rename(b)
        config.persistentWorkspaces = [b.name]
        close(window)
        try await listWindows(after: 2)
        assertStays(b)
    }

    func testMinimizedHiddenAndFullScreenWindowsStillCount() async throws {
        let (_, b, _, window) = threeTabs()
        try rename(b)
        window.layoutReason = .macos(prevParentKind: .tilingContainer, prevWorkspaceName: b.name)
        window.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        try await listWindows(after: 2)
        assertStays(b)
        window.bind(to: b.macOsNativeHiddenAppsWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
        try await listWindows(after: 2)
        assertStays(b)
        window.bind(to: b.macOsNativeFullscreenWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
        try await listWindows(after: 2)
        assertStays(b)
    }

    func testATabWhoseLastWindowMovedToAnotherTabStaysAsBefore() async throws {
        let (_, b, c, window) = threeTabs()
        try rename(b)
        window.bind(to: c.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        try await listWindows(after: 2)
        assertStays(b)
    }

    func testNothingClosesDuringTheStartupRestoreThenTheTabCloses() async throws {
        let (_, b, _, window) = threeTabs()
        try rename(b)
        savedWorkspaceRuntime.runtimeReadyAt = clock.addingTimeInterval(-10)
        close(window)
        try await listWindows(after: 2)
        assertStays(b)
        try await listWindows(after: SavedWorkspaceTiming.restoreWindow)
        assertClosed(b)
    }

    func testATabWaitingForAWindowItAskedForStaysUntilTheRequestEnds() async throws {
        let (_, b, _, window) = threeTabs()
        try rename(b)
        let intent = try XCTUnwrap(NewWindowIntentRegistry.shared.register(bundleId: editorId, pid: 501, targetWorkspace: b,
            preexistingWindowIds: [2], focusGeneration: 0))
        close(window)
        try await listWindows(after: 2)
        assertStays(b)
        NewWindowIntentRegistry.shared.cancel(intentId: intent.id)
        try await listWindows()
        assertClosed(b)
    }

    func testANewTabWaitingForItsFirstWindowStays() async throws {
        let (_, b, _, _) = threeTabs()
        let group = try workspaceSidebarOrganizationStore.create(projectId: b.projectId, workspaceNames: [])
        let newTab = try XCTUnwrap(newTabInSidebarCollection(group.id, monitor: b.workspaceMonitor))
        XCTAssertTrue(newTab.workspace.focusWorkspace())
        try await listWindows(after: 2)
        assertStays(newTab.workspace)
        XCTAssertTrue(focus.workspace === newTab.workspace)
    }

    func testReadOnlyModeChangesNothing() async throws {
        let (_, b, _, window) = threeTabs()
        try rename(b)
        setServerReadOnlyForTests(true)
        savedWorkspaceStore = SavedWorkspaceStore(file: savedWorkspaceStore.file, url: nil, readOnlyReason: "read-only")
        close(window)
        try await listWindows(after: 2)
        assertStays(b)
        XCTAssertEqual(config.workspaceSidebar.workspaceLabels[b.name], "Notes")
    }

    func testSidebarModeKeepsSavedWorkspaces() async throws {
        let (_, b, _, window) = threeTabs()
        config.workspaceSidebar.mode = .sidebar
        try rename(b)
        close(window)
        try await listWindows(after: 2)
        assertStays(b)
    }

    // MARK: The policy for an app that quit

    func testWithTheRelaunchPolicyOnATabWaitsForItsAppThatQuitAndGetsItsWindowBack() async throws {
        WorkspaceTabClosePolicy.waitsForAppRelaunch = true
        let (a, b, _, window) = threeTabs()
        try rename(b)
        editorQuits()
        vanishTogether([window], quit: [window])
        try await listWindows(after: SavedWorkspaceTiming.closedWindowGrace + 1)
        assertStays(b)
        let launched = clock
        running[editorId] = [SavedRunningApp(pid: 502, launchDate: launched)]
        let relaunched = TestApp(pid: 502, bundleId: editorId, name: "Editor", launchDate: launched)
        XCTAssertTrue(a.focusWorkspace())
        let next = TestWindow.new(id: 20, parent: a.rootTilingContainer, app: relaunched, title: "Notes")
        let restored = try await restoreOrDetectNewWindow(next, isRegularWindow: true)
        XCTAssertTrue(restored)
        XCTAssertTrue(next.nodeWorkspace === b, "Back in its tab, as before")
        Workspace.reconcileWorkspaceState()

        close(next)
        try await listWindows(after: 2)
        assertClosed(b)
    }

    // MARK: The sidebar

    func testATabWaitingToCloseIsntListed() async throws {
        let (_, b, _, window) = threeTabs()
        try rename(b)
        close(window)
        later(0.25)
        await updateWorkspaceSidebarModel()
        XCTAssertFalse(TrayMenuModel.shared.workspaceSidebarWorkspaces.contains { $0.name == b.name },
            "Not greyed in the list while it closes")
    }

    // MARK: Afterwards

    func testAClosedTabDoesntComeBackFromSavedState() async throws {
        let (_, b, _, window) = threeTabs()
        try rename(b)
        editorQuits()
        vanishTogether([window], quit: [window])
        try await listWindows(after: 2)
        captureSavedWorkspaces(facts: facts())
        materializeSavedWorkspaceNames()
        try await listWindows(after: SavedWorkspaceTiming.closedWindowGrace)
        assertClosed(b)
        XCTAssertFalse(savedWorkspaceStore.hasSlots(bundleId: editorId), "No saved place waits for the editor")
    }

    func testTheRelaunchedAppsWindowOpensInANewTab() async throws {
        let (a, b, _, window) = threeTabs()
        try rename(b)
        editorQuits()
        vanishTogether([window], quit: [window])
        try await listWindows(after: 2)
        let launched = clock
        running[editorId] = [SavedRunningApp(pid: 502, launchDate: launched)]
        let relaunched = TestApp(pid: 502, bundleId: editorId, name: "Editor", launchDate: launched)
        XCTAssertTrue(a.focusWorkspace())
        let next = TestWindow.new(id: 20, parent: a.rootTilingContainer, app: relaunched, title: "Notes")
        let restored = try await restoreOrDetectNewWindow(next, isRegularWindow: true)
        XCTAssertFalse(restored, "No saved place takes it")
        let tab = try XCTUnwrap(next.nodeWorkspace)
        XCTAssertFalse(tab === a || tab.name == b.name, "It opens in a new tab: \(tab.name)")
        XCTAssertEqual(tab.allLeafWindowsRecursive.map(\.windowId), [20])
    }

    func testTheRelaunchedAppsWindowGoesToItsEmptyPin() async throws {
        let (a, b, _, window) = threeTabs()
        var record = SavedWorkspaceRecord(workspaceName: "pin")
        record.launchApps = [SavedLaunchApp(bundleId: editorId)]
        savedWorkspaceStore.insert(record)
        materializeSavedWorkspaceNames()
        let pin = try XCTUnwrap(Workspace.existing(byName: "pin"))
        try setWorkspaceSidebarTabFavorite(pin, true)
        try rename(b)
        editorQuits()
        vanishTogether([window], quit: [window])
        try await listWindows(after: 2)
        assertClosed(b)
        let launched = clock
        running[editorId] = [SavedRunningApp(pid: 502, launchDate: launched)]
        let relaunched = TestApp(pid: 502, bundleId: editorId, name: "Editor", launchDate: launched)
        XCTAssertTrue(a.focusWorkspace())
        let next = TestWindow.new(id: 20, parent: a.rootTilingContainer, app: relaunched, title: "Notes")
        _ = try await restoreOrDetectNewWindow(next, isRegularWindow: true)
        XCTAssertTrue(next.nodeWorkspace === pin, "The pin is the editor's home")
    }
}
