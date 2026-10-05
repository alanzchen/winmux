@testable import AppBundle
import AppKit
import Common
import XCTest

/// Tabs mode: a tab that isn't pinned closes once its last window closes, rather than staying
/// greyed, whether it's saved (renamed, grouped, made from a topic) or not, and whether its app
/// keeps running or quits. It leaves the screen and the list at once; a saved one's identity goes
/// once its saved places have run out their grace.
@MainActor
final class WorkspaceTabsCloseWithLastWindowTest: XCTestCase {
    private var defaultAppIsFrontmost: (@MainActor (Window) -> Bool)?
    private var wasEnabled = true
    private var previousApp: (any AbstractApp)?
    private var clock = savedTestNow
    private let editorId = "com.test.editor"
    /// Running since long before WinMux started, so it's never armed.
    private lazy var editor = TestApp(pid: 501, bundleId: editorId, name: "Editor", launchDate: savedTestNow.addingTimeInterval(-86400))
    private let other = TestApp(pid: 600, bundleId: "com.test.other", name: "Other")
    private lazy var running: [String: [SavedRunningApp]] = [
        editorId: [SavedRunningApp(pid: 501, launchDate: savedTestNow.addingTimeInterval(-86400))],
        "com.test.other": [SavedRunningApp(pid: 600, launchDate: savedTestNow.addingTimeInterval(-86400))],
    ]

    override func setUp() async throws {
        defaultAppIsFrontmost = newWindowAppIsFrontmost
        wasEnabled = TrayMenuModel.shared.isEnabled
        previousApp = appForTests
        setUpWorkspacesForTests()
        resetWorkspaceTabsForTests()
        savedWorkspaceRuntime.environment = SavedWorkspaceEnvironment(
            now: { [unowned self] in clock },
            runningApps: { [unowned self] in running },
            openApplication: { _, _ in false },
            frontmostAppBundleId: { nil },
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
        appForTests = previousApp
        setBlockingRefreshOverridesForTests()
        setServerReadOnlyForTests(false)
        WorkspaceTabClosePolicy.waitsForAppRelaunch = false
        NewWindowIntentRegistry.shared.resetForTests()
        replaceClosedWindowsCache(FrozenWorld(workspaces: [], monitors: [], windowIds: []))
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

    /// The windows close: the refresh that no longer finds them takes them out of the tree, then
    /// reconciles.
    private func close(_ windows: Window...) {
        for window in windows { window.removeClosedWindowFromTree() }
        Workspace.reconcileWorkspaceState()
    }

    /// Time passes, and something reconciles.
    private func later(_ seconds: TimeInterval) {
        clock = clock.addingTimeInterval(seconds)
        Workspace.reconcileWorkspaceState()
    }

    /// Time passes, a checkpoint captures saved workspaces, and something reconciles.
    private func checkpoint(after seconds: TimeInterval) {
        clock = clock.addingTimeInterval(seconds)
        captureSavedWorkspaces(facts: facts())
        Workspace.reconcileWorkspaceState()
    }

    /// Past the grace a closed window's saved place keeps.
    private func afterTheGrace() {
        checkpoint(after: SavedWorkspaceTiming.closedWindowGrace + 1)
    }

    /// The editor quits.
    private func editorQuits() {
        running[editorId] = nil
    }

    /// The editor opens again, as a new process, and shows window `id`.
    private func editorRelaunchesWithWindow(_ id: UInt32, title: String = "Notes", in tab: Workspace) -> TestWindow {
        running[editorId] = [SavedRunningApp(pid: 502, launchDate: clock)]
        let relaunched = TestApp(pid: 502, bundleId: editorId, name: "Editor", launchDate: clock)
        return TestWindow.new(id: id, parent: tab.rootTilingContainer, app: relaunched, title: title)
    }

    /// Whether the Tabs list shows the tab.
    private func isListed(_ tab: Workspace) async -> Bool {
        await updateWorkspaceSidebarModel()
        return TrayMenuModel.shared.workspaceSidebarWorkspaces.contains { $0.name == tab.name && !$0.isLeftEmpty }
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

    func testARenamedTabLeavesTheListAtOnceAndItsIdentityGoesAfterTheGrace() async throws {
        let (_, b, _, window) = threeTabs()
        try rename(b)
        close(window)
        let listed = await isListed(b)
        XCTAssertFalse(listed, "Never shown greyed")
        assertStays(b, "Its identity waits out the grace, out of sight")
        afterTheGrace()
        assertClosed(b)
    }

    func testAnAutomaticTabInAGroupClosesAfterTheGrace() throws {
        let (_, b, c, window) = threeTabs()
        let group = try workspaceSidebarOrganizationStore.create(projectId: b.projectId, workspaceNames: [])
        try assignWorkspaceToSidebarCollection(b, collectionId: group.id, keepWhenEmpty: false)
        try assignWorkspaceToSidebarCollection(c, collectionId: group.id)
        captureSavedWorkspaces(facts: facts())
        XCTAssertEqual(savedWorkspaceStore.record(named: b.name)?.layout.allSlots.count, 1)
        close(window)
        afterTheGrace()
        assertClosed(b)
        XCTAssertEqual(workspaceSidebarOrganizationStore.state.collections.first?.workspaceNames, [c.name],
            "The group keeps its other tab")
    }

    func testATabInAGroupOfItsOwnClosesAndTheGroupFollowsItsUsualRules() throws {
        let (_, b, _, window) = threeTabs()
        let group = try workspaceSidebarOrganizationStore.create(projectId: b.projectId, workspaceNames: [])
        try assignWorkspaceToSidebarCollection(b, collectionId: group.id)
        XCTAssertTrue(b.isKeptWhenEmpty, "Grouping saves the tab")
        close(window)
        afterTheGrace()
        assertClosed(b)
        XCTAssertEqual(workspaceSidebarOrganizationStore.state.collections.map(\.id), [group.id],
            "An empty group stays, as when its last tab is moved out")
    }

    func testATabMadeFromATopicClosesLikeAnyOther() throws {
        let (_, b, _, window) = threeTabs()
        try ensureSavedWorkspaceRecord(b, keepWhenEmpty: true)
        close(window)
        afterTheGrace()
        assertClosed(b)
    }

    func testATabClosesAfterTheGraceWhenItsAppQuitsRatherThanWaitingForItToOpenAgain() throws {
        let (_, b, _, window) = threeTabs()
        try rename(b)
        editorQuits()
        close(window)
        checkpoint(after: 5)
        assertStays(b)
        afterTheGrace()
        assertClosed(b)
    }

    func testATabWhoseOnlyWindowWasMinimizedClosesWhenItsAppQuits() throws {
        let (_, b, _, window) = threeTabs()
        try rename(b)
        window.layoutReason = .macos(prevParentKind: .tilingContainer, prevWorkspaceName: b.name)
        window.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        afterTheGrace()
        assertStays(b)
        editorQuits()
        close(window)
        afterTheGrace()
        assertClosed(b)
    }

    func testAnUnsavedTabStillClosesAtOnce() {
        let (_, b, _, window) = threeTabs()
        close(window)
        XCTAssertNil(Workspace.existing(byName: b.name), "As before: nothing of it is saved")
    }

    // MARK: Production ordering

    /// A refresh session: it reconciles, then lists windows, finding `foundAgain` again and
    /// registering it as it registers any window, then reconciles again.
    private func runRefreshSession(findingAgain foundAgain: (id: UInt32, app: TestApp)? = nil) async throws {
        appForTests = TestApp.shared
        TrayMenuModel.shared.isEnabled = true
        setBlockingRefreshOverridesForTests(refresh: {
            if let foundAgain {
                // Made only now: before the listing, the window is nowhere.
                let window = TestWindow.new(id: foundAgain.id, parent: focus.workspace.rootTilingContainer, app: foundAgain.app,
                    title: "Notes")
                _ = try await restoreOrDetectNewWindow(window, isRegularWindow: true)
            }
            Workspace.reconcileWorkspaceState()
        }, normalizeLayoutReason: {})
        try await runRefreshSessionBlocking(.ax(kAXUIElementDestroyedNotification as String), layoutWorkspaces: false)
    }

    func testAWindowFoundAgainByALaterRefreshSessionGoesBackToItsTab() async throws {
        let (_, b, _, window) = threeTabs()
        try rename(b)
        close(window)
        clock = clock.addingTimeInterval(10)
        try await runRefreshSession(findingAgain: (2, editor))
        assertStays(b)
        XCTAssertEqual(b.allLeafWindowsRecursive.map(\.windowId), [2], "Back in its tab")
        XCTAssertEqual(config.workspaceSidebar.workspaceLabels[b.name], "Notes")
        let listed = await isListed(b)
        XCTAssertTrue(listed)
    }

    func testARefreshSessionThatDoesntFindTheWindowClosesItsTabOnceTheGraceIsOver() async throws {
        let (_, b, _, window) = threeTabs()
        try rename(b)
        close(window)
        clock = clock.addingTimeInterval(10)
        try await runRefreshSession()
        assertStays(b)
        clock = clock.addingTimeInterval(SavedWorkspaceTiming.closedWindowGrace)
        try await runRefreshSession()
        assertClosed(b)
    }

    func testALightSessionNeverDeletesATabWithinItsGrace() async throws {
        let (_, b, _, window) = threeTabs()
        try rename(b)
        close(window)
        clock = clock.addingTimeInterval(10)
        appForTests = TestApp.shared
        try await runLightSession(.hotkeyBinding, .forceRun, shouldSchedulePostRefresh: false) {}
        assertStays(b)
        afterTheGrace()
        assertClosed(b)
    }

    func testWindowsOfTwoAppsGoingTogetherThenALateLockKeepBothTabsForTheirReturn() async throws {
        let (_, b, c, window) = threeTabs()
        try rename(b)
        try rename(c, "Mail")
        let world = snapshotCurrentFrozenWorld()
        let mail = try XCTUnwrap(c.allLeafWindowsRecursive.first)
        close(window, mail)
        later(3)
        savedWorkspaceRuntime.suspensions.insert(.screenLocked)
        later(20)
        resumeSavedWorkspaceCapture(after: .screenLocked)
        later(1)
        assertStays(b)
        assertStays(c)
        // The windows come back by id, as the lock screen's blank never closed them.
        replaceClosedWindowsCache(world)
        for (id, app) in [(UInt32(2), editor), (3, other)] {
            _ = try await restoreOrDetectNewWindow(TestWindow.new(id: id, parent: focus.workspace.rootTilingContainer, app: app),
                isRegularWindow: true)
        }
        afterTheGrace()
        assertStays(b)
        assertStays(c)
        XCTAssertEqual(b.allLeafWindowsRecursive.map(\.windowId), [2])
        XCTAssertEqual(c.allLeafWindowsRecursive.map(\.windowId), [3])
        XCTAssertEqual(config.workspaceSidebar.workspaceLabels[c.name], "Mail")
    }

    func testWindowsOfTwoAppsClosingTogetherCloseBothTabs() throws {
        let (_, b, c, window) = threeTabs()
        try rename(b)
        try rename(c, "Mail")
        close(window, try XCTUnwrap(c.allLeafWindowsRecursive.first))
        afterTheGrace()
        assertClosed(b)
        assertClosed(c)
    }

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
        close(first, second)

        later(2)
        let windows = [editorRelaunchesWithWindow(20, title: "", in: a), editorRelaunchesWithWindow(21, title: "", in: a)]
        for window in windows { _ = try await restoreOrDetectNewWindow(window, isRegularWindow: true) }
        XCTAssertEqual(Set(savedWorkspaceRuntime.windowsAwaitingTitle.keys), [20, 21], "They wait for their titles")
        afterTheGrace()
        assertStays(b)
        assertStays(d)

        windows[0].customTitle = "Notes C"
        windows[1].customTitle = "Notes B"
        await retrySavedWorkspaceRoutingForWindowsAwaitingTitles()
        XCTAssertTrue(windows[0].nodeWorkspace === d)
        XCTAssertTrue(windows[1].nodeWorkspace === b)
        afterTheGrace()
        assertStays(b)
        assertStays(d)
        XCTAssertEqual(config.workspaceSidebar.workspaceLabels[b.name], "B")
    }

    func testTheOnlyTabOnADisplayIsntListedThenLeavesItABlankTabOnceItsSavedPlacesAreGone() async throws {
        let left = SavedWorkspaceTestMonitor(id: 1, name: "Left", x: 0, isMain: true, uuid: "LEFT", isBuiltin: true)
        let right = SavedWorkspaceTestMonitor(id: 2, name: "Right", x: 1920, uuid: "RIGHT")
        setMonitorsForTests([left, right])
        let (a, b, c, window) = threeTabs()
        c.preferredMonitorPoint = left.rect.topLeftCorner
        XCTAssertTrue(right.setActiveWorkspace(b))
        XCTAssertTrue(a.allLeafWindowsRecursive[0].focusWindow())
        try rename(b)
        editorQuits()
        close(window)
        let listed = await isListed(b)
        XCTAssertFalse(listed, "Left on screen, as the only tab there, and not listed")
        assertStays(b)

        afterTheGrace()
        let shown = right.activeWorkspace
        XCTAssertFalse([a, b, c].contains { $0 === shown }, "A blank tab, not \(shown.name)")
        XCTAssertTrue(shown.isEffectivelyEmpty)
        XCTAssertEqual(shown.projectId, b.projectId)
        XCTAssertTrue(focus.workspace === a, "Focus stays where it was")
        assertClosed(b)

        let next = editorRelaunchesWithWindow(20, in: a)
        let restored = try await restoreOrDetectNewWindow(next, isRegularWindow: true)
        XCTAssertFalse(restored, "Nothing saved waits for it")
        XCTAssertNotEqual(next.nodeWorkspace?.name, b.name)
    }

    // MARK: Focus and replacement

    func testClosingTheTabInUseMovesFocusToTheNextTabAsForAnyTab() throws {
        let (_, b, c, window) = threeTabs()
        try rename(b)
        XCTAssertTrue(window.focusWindow())
        close(window)
        XCTAssertTrue(focus.workspace === c, "The next tab, as closing a browser tab does")
        afterTheGrace()
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

    /// Raw order a, b, c, d: a on the right display, the rest on the left; a and c grouped, so the
    /// left sidebar shows b, c, d.
    private func groupSpanningTwoDisplays() throws -> (left: Monitor, right: Monitor, a: Workspace, b: Workspace,
                                                         c: Workspace, d: Workspace) {
        let left = SavedWorkspaceTestMonitor(id: 1, name: "Left", x: 0, isMain: true, uuid: "LEFT", isBuiltin: true)
        let right = SavedWorkspaceTestMonitor(id: 2, name: "Right", x: 1920, uuid: "RIGHT")
        setMonitorsForTests([left, right])
        let a = focus.workspace
        let b = Workspace.get(byName: "tab-b")
        let c = Workspace.get(byName: "tab-c")
        let d = Workspace.get(byName: "tab-d")
        for (index, tab) in [a, b, c, d].enumerated() {
            _ = TestWindow.new(id: UInt32(index + 1), parent: tab.rootTilingContainer, app: other)
        }
        for tab in [b, c, d] { tab.preferredMonitorPoint = left.rect.topLeftCorner }
        a.preferredMonitorPoint = right.rect.topLeftCorner
        XCTAssertTrue(left.setActiveWorkspace(b))
        XCTAssertTrue(right.setActiveWorkspace(a))
        let group = try workspaceSidebarOrganizationStore.create(projectId: a.projectId, workspaceNames: [])
        try assignWorkspaceToSidebarCollection(a, collectionId: group.id)
        try assignWorkspaceToSidebarCollection(c, collectionId: group.id)
        Workspace.reconcileWorkspaceState()
        XCTAssertEqual(orderedWorkspaces(in: a.projectId).map(\.name).suffix(4), [a.name, b.name, c.name, d.name])
        return (left, right, a, b, c, d)
    }

    func testClosingATabMovesToTheNextTabItsDisplaysSidebarShowsWhenAGroupSpansTwoDisplays() throws {
        let (left, _, _, b, c, _) = try groupSpanningTwoDisplays()
        let window = try XCTUnwrap(b.allLeafWindowsRecursive.first)
        XCTAssertTrue(window.focusWindow())
        close(window)
        XCTAssertTrue(focus.workspace === c, "The left sidebar shows b, c, d")
        XCTAssertTrue(left.activeWorkspace === c)
    }

    func testATabClosingInTheBackgroundGivesItsDisplayToTheNextTabItsSidebarShows() throws {
        let (left, right, a, b, c, _) = try groupSpanningTwoDisplays()
        XCTAssertTrue(try XCTUnwrap(a.allLeafWindowsRecursive.first).focusWindow())
        close(try XCTUnwrap(b.allLeafWindowsRecursive.first))
        XCTAssertTrue(left.activeWorkspace === c, "The left sidebar shows b, c, d")
        XCTAssertTrue(right.activeWorkspace === a)
        XCTAssertTrue(focus.workspace === a)
    }

    func testATabClosingOnAnotherDisplayLeavesItAtOnceWithoutTakingFocus() async throws {
        let left = SavedWorkspaceTestMonitor(id: 1, name: "Left", x: 0, isMain: true, uuid: "LEFT", isBuiltin: true)
        let right = SavedWorkspaceTestMonitor(id: 2, name: "Right", x: 1920, uuid: "RIGHT")
        setMonitorsForTests([left, right])
        let (a, b, c, window) = threeTabs()
        c.preferredMonitorPoint = right.rect.topLeftCorner
        XCTAssertTrue(right.setActiveWorkspace(b))
        XCTAssertTrue(a.allLeafWindowsRecursive[0].focusWindow())
        try rename(b)
        close(window)
        XCTAssertTrue(right.activeWorkspace === c, "The other display shows its next tab at once")
        XCTAssertTrue(focus.workspace === a, "Focus stays where it was")
        let listed = await isListed(b)
        XCTAssertFalse(listed)
        afterTheGrace()
        assertClosed(b)
    }

    // MARK: It stays

    func testPinnedTabsStayAsTheirAppsHomes() throws {
        let (_, b, c, window) = threeTabs()
        try setWorkspaceSidebarTabFavorite(b, true)
        try setWorkspaceSidebarTabPinScope(c, .allProjects, projectId: c.projectId)
        close(window, c.allLeafWindowsRecursive[0])
        afterTheGrace()
        assertStays(b)
        assertStays(c)
    }

    func testUnpinningAnEmptyPinLaterLeavesItAsBefore() throws {
        let (_, b, _, window) = threeTabs()
        try setWorkspaceSidebarTabFavorite(b, true)
        close(window)
        afterTheGrace()
        try setWorkspaceSidebarTabFavorite(b, false)
        afterTheGrace()
        assertStays(b)
        XCTAssertTrue(b.isKeptWhenEmpty, "Its last window closed while it was a pin, which stays")
    }

    func testAConfiguredPersistentWorkspaceStays() throws {
        let (_, b, _, window) = threeTabs()
        try rename(b)
        config.persistentWorkspaces = [b.name]
        close(window)
        afterTheGrace()
        assertStays(b)
    }

    func testMinimizedHiddenAndFullScreenWindowsStillCount() throws {
        let (_, b, _, window) = threeTabs()
        try rename(b)
        window.layoutReason = .macos(prevParentKind: .tilingContainer, prevWorkspaceName: b.name)
        window.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        afterTheGrace()
        assertStays(b)
        window.bind(to: b.macOsNativeHiddenAppsWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
        afterTheGrace()
        assertStays(b)
        window.bind(to: b.macOsNativeFullscreenWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
        afterTheGrace()
        assertStays(b)
    }

    func testATabWhoseLastWindowMovedToAnotherTabStaysAsBefore() throws {
        let (_, b, c, window) = threeTabs()
        try rename(b)
        window.bind(to: c.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        afterTheGrace()
        assertStays(b)
    }

    func testNothingClosesDuringTheStartupRestoreThenTheTabCloses() throws {
        let (_, b, _, window) = threeTabs()
        try rename(b)
        savedWorkspaceRuntime.runtimeReadyAt = clock.addingTimeInterval(-10)
        close(window)
        checkpoint(after: 20)
        assertStays(b)
        XCTAssertTrue(b.isKeptWhenEmpty, "Still a saved tab while windows come back")
        checkpoint(after: SavedWorkspaceTiming.restoreWindow)
        afterTheGrace()
        assertClosed(b)
    }

    func testATabWaitingForAWindowItAskedForStaysUntilTheRequestEnds() throws {
        let (_, b, _, window) = threeTabs()
        try rename(b)
        let intent = try XCTUnwrap(NewWindowIntentRegistry.shared.register(bundleId: editorId, pid: 501, targetWorkspace: b,
            preexistingWindowIds: [2], focusGeneration: 0))
        close(window)
        afterTheGrace()
        assertStays(b)
        NewWindowIntentRegistry.shared.cancel(intentId: intent.id)
        checkpoint(after: 0)
        assertClosed(b)
    }

    func testANewTabWaitingForItsFirstWindowStays() throws {
        let (_, b, _, _) = threeTabs()
        let group = try workspaceSidebarOrganizationStore.create(projectId: b.projectId, workspaceNames: [])
        let newTab = try XCTUnwrap(newTabInSidebarCollection(group.id, monitor: b.workspaceMonitor))
        XCTAssertTrue(newTab.workspace.focusWorkspace())
        afterTheGrace()
        assertStays(newTab.workspace)
        XCTAssertTrue(focus.workspace === newTab.workspace)
    }

    func testReadOnlyModeChangesNothing() throws {
        let (_, b, _, window) = threeTabs()
        try rename(b)
        setServerReadOnlyForTests(true)
        savedWorkspaceStore = SavedWorkspaceStore(file: savedWorkspaceStore.file, url: nil, readOnlyReason: "read-only")
        close(window)
        afterTheGrace()
        assertStays(b)
        XCTAssertEqual(config.workspaceSidebar.workspaceLabels[b.name], "Notes")
    }

    func testSidebarModeKeepsSavedWorkspaces() throws {
        let (_, b, _, window) = threeTabs()
        config.workspaceSidebar.mode = .sidebar
        try rename(b)
        close(window)
        afterTheGrace()
        assertStays(b)
    }

    // MARK: The policy for an app that quit

    func testWithTheRelaunchPolicyOnATabWaitsForItsAppThatQuitAndGetsItsWindowBack() async throws {
        WorkspaceTabClosePolicy.waitsForAppRelaunch = true
        let (a, b, _, window) = threeTabs()
        try rename(b)
        editorQuits()
        close(window)
        afterTheGrace()
        assertStays(b)
        XCTAssertTrue(a.focusWorkspace())
        let next = editorRelaunchesWithWindow(20, in: a)
        let restored = try await restoreOrDetectNewWindow(next, isRegularWindow: true)
        XCTAssertTrue(restored)
        XCTAssertTrue(next.nodeWorkspace === b, "Back in its tab, as before")
        Workspace.reconcileWorkspaceState()

        close(next)
        afterTheGrace()
        assertStays(b, "Its app opened moments ago: its saved place waits while it's armed")
        checkpoint(after: SavedWorkspaceTiming.restoreWindow)
        afterTheGrace()
        assertClosed(b)
    }

    // MARK: Afterwards

    func testAClosedTabDoesntComeBackFromSavedState() throws {
        let (_, b, _, window) = threeTabs()
        try rename(b)
        editorQuits()
        close(window)
        afterTheGrace()
        materializeSavedWorkspaceNames()
        afterTheGrace()
        assertClosed(b)
        XCTAssertFalse(savedWorkspaceStore.hasSlots(bundleId: editorId), "No saved place waits for the editor")
    }

    func testARelaunchAfterTheGraceOpensItsWindowInANewTab() async throws {
        let (a, b, _, window) = threeTabs()
        try rename(b)
        editorQuits()
        close(window)
        afterTheGrace()
        XCTAssertTrue(a.focusWorkspace())
        let next = editorRelaunchesWithWindow(20, in: a)
        let restored = try await restoreOrDetectNewWindow(next, isRegularWindow: true)
        XCTAssertFalse(restored, "No saved place takes it")
        let tab = try XCTUnwrap(next.nodeWorkspace)
        XCTAssertFalse(tab === a || tab.name == b.name, "It opens in a new tab: \(tab.name)")
        XCTAssertEqual(tab.allLeafWindowsRecursive.map(\.windowId), [20])
    }

    func testARelaunchAfterTheGraceOpensItsWindowInItsEmptyPin() async throws {
        let (a, b, _, window) = threeTabs()
        var record = SavedWorkspaceRecord(workspaceName: "pin")
        record.launchApps = [SavedLaunchApp(bundleId: editorId)]
        savedWorkspaceStore.insert(record)
        materializeSavedWorkspaceNames()
        let pin = try XCTUnwrap(Workspace.existing(byName: "pin"))
        try setWorkspaceSidebarTabFavorite(pin, true)
        try rename(b)
        editorQuits()
        close(window)
        afterTheGrace()
        assertClosed(b)
        XCTAssertTrue(a.focusWorkspace())
        let next = editorRelaunchesWithWindow(20, in: a)
        _ = try await restoreOrDetectNewWindow(next, isRegularWindow: true)
        XCTAssertTrue(next.nodeWorkspace === pin, "The pin is the editor's home")
    }

    func testARelaunchWithinTheGraceBringsTheTabBack() async throws {
        let (a, b, _, window) = threeTabs()
        try rename(b)
        editorQuits()
        close(window)
        checkpoint(after: 5)
        let next = editorRelaunchesWithWindow(20, in: a)
        let restored = try await restoreOrDetectNewWindow(next, isRegularWindow: true)
        XCTAssertTrue(restored, "Its saved place still waits")
        XCTAssertTrue(next.nodeWorkspace === b)
        afterTheGrace()
        assertStays(b)
        XCTAssertEqual(config.workspaceSidebar.workspaceLabels[b.name], "Notes")
    }
}
