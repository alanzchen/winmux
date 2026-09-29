@testable import AppBundle
import AppKit
import Common
import XCTest

/// Tabs mode doesn't keep empty tabs: one whose windows have gone closes, however they went.
@MainActor
final class WorkspaceTabsLeftEmptyTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        setSavedWorkspaceTestEnvironment()
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        workspaceSidebarOrganizationStore = .init()
    }

    override func tearDown() async throws {
        WorkspaceSidebarTabUndo.shared.clear()
        setMonitorsForTests(nil)
        workspaceSidebarOrganizationStore = .init()
        config = defaultConfig
    }

    /// Tabs a, b and c with windows 1 to 3, in that order, with a on screen.
    private func threeTabs() -> (a: Workspace, b: Workspace, c: Workspace) {
        let a = focus.workspace
        let b = Workspace.get(byName: "tab-b")
        let c = Workspace.get(byName: "tab-c")
        for (index, tab) in [a, b, c].enumerated() { _ = TestWindow.new(id: UInt32(index + 1), parent: tab.rootTilingContainer) }
        XCTAssertTrue(a.allLeafWindowsRecursive[0].focusWindow())
        Workspace.reconcileWorkspaceState()
        return (a, b, c)
    }

    private func settle() {
        leaveTabsLeftEmptyOnScreen()
        Workspace.reconcileWorkspaceState()
    }

    private func move(_ window: Window, to tab: Workspace) {
        window.bind(to: tab.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    }

    func testATabLeftEmptyOnScreenGivesItsDisplayToTheNextTabAndCloses() {
        let (a, b, c) = threeTabs()
        move(a.allLeafWindowsRecursive[0], to: c)
        XCTAssertTrue(workspaceTabWasLeftEmpty(a))
        settle()
        XCTAssertTrue(focus.workspace === b, "The next tab takes its place, as closing a browser tab does")
        XCTAssertNil(Workspace.existing(byName: a.name), "and the empty tab is gone")
        XCTAssertTrue(b.isVisible)
    }

    func testWithNoTabAfterItTheOneBeforeTakesItsPlace() {
        let (a, b, c) = threeTabs()
        XCTAssertTrue(c.allLeafWindowsRecursive[0].focusWindow())
        move(c.allLeafWindowsRecursive[0], to: a)
        settle()
        XCTAssertTrue(focus.workspace === b)
        XCTAssertNil(Workspace.existing(byName: c.name))
    }

    func testATabWithWindowsTakesThePlaceBeforeANearerEmptyPin() throws {
        let a = focus.workspace
        let window = TestWindow.new(id: 1, parent: a.rootTilingContainer)
        let open = Workspace.get(byName: "pinned-open")
        _ = TestWindow.new(id: 2, parent: open.rootTilingContainer)
        let empty = Workspace.get(byName: "pinned-empty")
        try setWorkspaceSidebarTabsFavorite([open, empty], true)
        XCTAssertTrue(window.focusWindow())
        Workspace.reconcileWorkspaceState()
        XCTAssertEqual(workspaceNavigationTabs(current: a).map(\.name).suffix(3), ["pinned-open", "pinned-empty", a.name])
        let other = createWorkspaceProject()
        let elsewhere = Workspace.get(byName: "elsewhere")
        elsewhere.assignProject(other.id)
        move(window, to: elsewhere)
        settle()
        XCTAssertTrue(focus.workspace === open, "The empty pin is nearer, but a tab with windows is shown first")
        XCTAssertNil(Workspace.existing(byName: a.name))
    }

    func testTheOnlyTabLeftEmptyStaysOnScreenButIsntListed() async throws {
        let a = focus.workspace
        let window = TestWindow.new(id: 1, parent: a.rootTilingContainer)
        Workspace.reconcileWorkspaceState()
        let other = createWorkspaceProject()
        let elsewhere = Workspace.get(byName: "elsewhere")
        elsewhere.assignProject(other.id)
        move(window, to: elsewhere)
        settle()
        XCTAssertTrue(a.isVisible, "A display always shows a workspace")
        XCTAssertTrue(workspaceTabWasLeftEmpty(a))
        await updateWorkspaceSidebarModel()
        let listed = TrayMenuModel.shared.workspaceSidebarWorkspaces.first { $0.name == a.name }
        XCTAssertEqual(listed?.isLeftEmpty, true)
        var snapshot = WorkspaceSidebarSnapshot.empty
        snapshot.workspaces = TrayMenuModel.shared.workspaceSidebarWorkspaces
        XCTAssertFalse(WorkspaceSidebarView(snapshot: snapshot).tabsListedWorkspaces.contains { $0.name == a.name })

        let newTab = newTabWorkspace(projectId: a.projectId, monitor: a.workspaceMonitor)
        XCTAssertTrue(newTab.workspace === a, "New Tab reuses it; the launcher lists it while it's open for it")
        XCTAssertTrue(workspaceTabWasLeftEmptyIgnoringLauncher(a))
    }

    func testANewTabClosedWithNothingInItThatCantCloseIsLeftOutOfTheList() {
        let a = focus.workspace
        XCTAssertFalse(workspaceTabWasLeftEmpty(a), "A new tab waits for its first window")
        closeUnusedNewTab(WorkspaceLauncherNewTab(workspace: a, previous: nil, isNew: false))
        XCTAssertTrue(a.isVisible, "Its display has no other tab")
        XCTAssertTrue(workspaceTabWasLeftEmpty(a), "so it stays on screen, left out of the list")
    }

    func testPinnedSavedAndNewTabsAreNotClosed() throws {
        let (a, b, _) = threeTabs()
        try setWorkspaceSidebarTabFavorite(a, true)
        move(a.allLeafWindowsRecursive[0], to: b)
        settle()
        XCTAssertTrue(focus.workspace === a, "A pinned tab stays, greyed, to open its app again")
        XCTAssertFalse(workspaceTabWasLeftEmpty(a))

        let fresh = newTabWorkspace(projectId: b.projectId, monitor: b.workspaceMonitor).workspace
        XCTAssertTrue(fresh.focusWorkspace())
        settle()
        XCTAssertTrue(focus.workspace === fresh, "A new tab waits for its first window")
        XCTAssertFalse(workspaceTabWasLeftEmpty(fresh))
    }

    func testMovingTheLastWindowOutOfTheTabOnScreenFollowsIt() {
        let (a, _, c) = threeTabs()
        let window = a.allLeafWindowsRecursive[0]
        applySidebarWorkspaceMove(sourceNode: window, sourceWindow: window, targetWorkspace: c)
        XCTAssertTrue(focus.workspace === c, "The view follows the window, not the tab next to the empty one")
        settle()
        XCTAssertNil(Workspace.existing(byName: a.name))
        XCTAssertEqual(c.allLeafWindowsRecursive.map(\.windowId), [3, 1])
    }

    func testATabLeftEmptyOnAnotherDisplayMovesOnWithoutTakingFocus() {
        let left = SavedWorkspaceTestMonitor(id: 1, name: "Left", x: 0, isMain: true, uuid: "LEFT", isBuiltin: true)
        let right = SavedWorkspaceTestMonitor(id: 2, name: "Right", x: 1920, uuid: "RIGHT")
        setMonitorsForTests([left, right])
        let (a, b, c) = threeTabs()
        // b is on the right, and so is c, behind it.
        c.preferredMonitorPoint = right.rect.topLeftCorner
        XCTAssertTrue(right.setActiveWorkspace(b))
        XCTAssertTrue(a.allLeafWindowsRecursive[0].focusWindow())
        Workspace.reconcileWorkspaceState()
        move(b.allLeafWindowsRecursive[0], to: a)
        settle()
        XCTAssertTrue(right.activeWorkspace === c, "The other display shows its next tab")
        XCTAssertTrue(focus.workspace === a, "Focus stays where it was")
        XCTAssertNil(Workspace.existing(byName: b.name))
    }

    func testAReassignedDisplayIsRepairedBeforeATabReplacesAnEmptyOne() {
        let left = SavedWorkspaceTestMonitor(id: 1, name: "Left", x: 0, isMain: true, uuid: "LEFT", isBuiltin: true)
        let right = SavedWorkspaceTestMonitor(id: 2, name: "Right", x: 1920, uuid: "RIGHT")
        setMonitorsForTests([left, right])
        let (a, b, c) = threeTabs()
        c.preferredMonitorPoint = right.rect.topLeftCorner
        XCTAssertTrue(right.setActiveWorkspace(b))
        XCTAssertTrue(a.allLeafWindowsRecursive[0].focusWindow())
        Workspace.reconcileWorkspaceState()
        let other = createWorkspaceProject()
        let elsewhere = Workspace.get(byName: "elsewhere")
        elsewhere.assignProject(other.id)
        move(a.allLeafWindowsRecursive[0], to: elsewhere)
        // A config reload now puts b and c on the left display, where a is left empty.
        config.workspaceToMonitorForceAssignment[b.name] = [.main]
        config.workspaceToMonitorForceAssignment[c.name] = [.main]
        refreshModel()
        for monitor in [left, right] {
            XCTAssertTrue(isValidAssignment(workspace: monitor.activeWorkspace, screen: monitor.rect.topLeftCorner))
        }
        XCTAssertNil(Workspace.existing(byName: a.name), "The empty tab still closes")
    }

    func testUndoRestoresWhetherATabHadHadWindows() throws {
        let (a, _, _) = threeTabs()
        let fresh = newTabWorkspace(projectId: a.projectId, monitor: a.workspaceMonitor).workspace
        XCTAssertFalse(fresh.hasHadWindows)
        let before = WorkspaceSidebarTabUndoSnapshot()
        move(a.allLeafWindowsRecursive[0], to: fresh)
        Workspace.reconcileWorkspaceState()
        XCTAssertTrue(fresh.hasHadWindows)
        WorkspaceSidebarTabUndo.shared.record("Move Tab", before: before)
        try WorkspaceSidebarTabUndo.shared.undo()
        XCTAssertFalse(fresh.hasHadWindows, "Back to a new tab, which waits for its first window")
    }

    func testASavedTabKeepsShowingItsAppsAfterItsSlotsExpireAndAcrossRestarts() throws {
        let (a, b, _) = threeTabs()
        try setWorkspaceSidebarTabFavorite(b, true)
        captureSavedWorkspaces(facts: savedTestFacts())
        let app = try XCTUnwrap(b.allLeafWindowsRecursive.first?.app.rawAppBundleId)
        XCTAssertEqual(savedWorkspaceStore.record(named: b.name)?.launchApps?.map(\.bundleId), [app])
        move(b.allLeafWindowsRecursive[0], to: a)
        XCTAssertTrue(savedWorkspaceStore.update(named: b.name) { $0.layout = .init() })
        captureSavedWorkspaces(facts: savedTestFacts())
        XCTAssertEqual(workspaceSidebarSavedApps(for: b).map(\.bundleId), [app], "The app its windows had last")

        let record = try XCTUnwrap(savedWorkspaceStore.record(named: b.name))
        let decoded = try JSONDecoder().decode(SavedWorkspaceRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded.launchApps, record.launchApps, "Saved with the tab, so it survives a restart")
        let older = try JSONDecoder().decode(SavedWorkspaceRecord.self,
            from: Data(#"{"id":"x","workspaceName":"old"}"#.utf8))
        XCTAssertNil(older.launchApps, "Records saved before it load as before")
    }

    func testPinningRecordsItsAppsAtOnceSoAWindowClosedBeforeACheckpointStillCounts() throws {
        let (a, b, _) = threeTabs()
        try setWorkspaceSidebarTabFavorite(b, true)
        let app = try XCTUnwrap(b.allLeafWindowsRecursive.first?.app.rawAppBundleId)
        XCTAssertEqual(savedWorkspaceStore.record(named: b.name)?.launchApps?.map(\.bundleId), [app], "No checkpoint needed")
        move(b.allLeafWindowsRecursive[0], to: a)
        captureSavedWorkspaces(facts: savedTestFacts())
        _ = savedWorkspaceStore.update(named: b.name) { $0.layout = .init() }
        XCTAssertEqual(workspaceSidebarSavedApps(for: b).map(\.bundleId), [app])
    }

    func testATabShowsAnAppWhoseSlotExpiredBesideOneStillWaiting() throws {
        let (_, b, _) = threeTabs()
        try setWorkspaceSidebarTabFavorite(b, true)
        XCTAssertTrue(savedWorkspaceStore.update(named: b.name) {
            $0.launchApps = [SavedLaunchApp(bundleId: "bobko.WinMux.test-app"),
                SavedLaunchApp(bundleId: "com.apple.Terminal", appName: "Terminal")]
        })
        XCTAssertEqual(workspaceSidebarSavedApps(for: b).map(\.bundleId), ["bobko.WinMux.test-app", "com.apple.Terminal"],
            "Terminal's slot expired while the other app's still waits")
    }

    func testSavingATabReturnsTheRecordWithItsApps() throws {
        let (_, b, _) = threeTabs()
        let (record, created) = try ensureSavedWorkspaceRecord(b)
        XCTAssertTrue(created)
        XCTAssertEqual(record.launchApps, savedWorkspaceStore.record(named: b.name)?.launchApps)
        XCTAssertEqual(record.launchApps?.map(\.bundleId), ["bobko.WinMux.test-app"])
    }

    func testARecordSavedBeforeItHadAppsLearnsThemFromItsSavedWindows() throws {
        let (_, b, _) = threeTabs()
        try setWorkspaceSidebarTabFavorite(b, true)
        XCTAssertTrue(savedWorkspaceStore.update(named: b.name) { $0.launchApps = nil })
        b.allLeafWindowsRecursive[0].closeAxWindow()
        captureSavedWorkspaces(facts: savedTestFacts())
        XCTAssertEqual(savedWorkspaceStore.record(named: b.name)?.launchApps?.map(\.bundleId), ["bobko.WinMux.test-app"],
            "Its app quit; the slot waiting for it says which app it was")
    }

    func testABackgroundCheckpointDoesntCancelAnUndo() throws {
        let (a, b, c) = threeTabs()
        try setWorkspaceSidebarTabFavorite(b, true)
        let terminal = TestWindow.new(id: 20, parent: c.rootTilingContainer,
            app: TestApp(pid: 42, bundleId: "com.apple.Terminal", name: "Terminal"))
        Workspace.reconcileWorkspaceState()
        let before = WorkspaceSidebarTabUndoSnapshot()
        move(terminal, to: b)
        WorkspaceSidebarTabUndo.shared.record("Move Tab", before: before)
        captureSavedWorkspaces(facts: savedTestFacts())
        XCTAssertEqual(savedWorkspaceStore.record(named: b.name)?.launchApps?.map(\.bundleId),
            ["bobko.WinMux.test-app", "com.apple.Terminal"])
        WorkspaceSidebarTabUndo.shared.invalidateIfChanged()
        XCTAssertEqual(WorkspaceSidebarTabUndo.shared.title, "Undo Move Tab", "The checkpoint isn't an edit")
        try WorkspaceSidebarTabUndo.shared.undo()
        XCTAssertEqual(savedWorkspaceStore.record(named: b.name)?.launchApps?.map(\.bundleId), ["bobko.WinMux.test-app"])
        XCTAssertTrue(terminal.nodeWorkspace === c)
        _ = a
    }

    func testAnAppOpenedFromATabWithNoWindowWaitingLandsThereNotInAnotherTabsPlace() async throws {
        let (a, b, c) = threeTabs()
        try setWorkspaceSidebarTabsFavorite([b, c], true)
        let app = try XCTUnwrap(b.allLeafWindowsRecursive.first?.app.rawAppBundleId)
        move(b.allLeafWindowsRecursive[0], to: a)
        XCTAssertTrue(savedWorkspaceStore.update(named: b.name) { $0.layout = .init() })
        c.allLeafWindowsRecursive[0].closeAxWindow()
        captureSavedWorkspaces(facts: savedTestFacts())
        XCTAssertTrue(savedWorkspaceStore.record(named: c.name)?.layout.allSlots.isEmpty == false, "c waits for its window")
        savedWorkspaceRuntime.preferRestoring(bundleId: app, into: b.name, bypassingRouting: true)
        savedWorkspaceRuntime.manualArmUntilByBundleId[app] = savedWorkspaceRuntime.now.addingTimeInterval(60)
        // The relaunched app is a new process.
        let relaunched = TestApp(pid: 77, bundleId: app)
        let first = TestWindow.new(id: 30, parent: a.rootTilingContainer, app: relaunched)
        let routedFirst = try await routeNewWindowToSavedWorkspaceIfNeeded(first, isRegularWindow: true)
        XCTAssertFalse(routedFirst, "b's window isn't sent to c's saved place")
        XCTAssertNil(savedWorkspaceRuntime.preferredRestoreWorkspace(bundleId: app))
        let second = TestWindow.new(id: 31, parent: a.rootTilingContainer, app: relaunched)
        let routedSecond = try await routeNewWindowToSavedWorkspaceIfNeeded(second, isRegularWindow: true)
        XCTAssertTrue(routedSecond, "Later windows return to their saved places as before")
        XCTAssertTrue(second.nodeWorkspace === c)
    }

    func testRelaunchingFromOneOfTwoWaitingTabsRestoresBoth() async throws {
        let (a, b, c) = threeTabs()
        try setWorkspaceSidebarTabsFavorite([b, c], true)
        let app = try XCTUnwrap(b.allLeafWindowsRecursive.first?.app.rawAppBundleId)
        for tab in [b, c] { tab.allLeafWindowsRecursive[0].closeAxWindow() }
        captureSavedWorkspaces(facts: savedTestFacts())
        savedWorkspaceRuntime.preferRestoring(bundleId: app, into: c.name)
        savedWorkspaceRuntime.manualArmUntilByBundleId[app] = savedWorkspaceRuntime.now.addingTimeInterval(60)
        let relaunched = TestApp(pid: 78, bundleId: app)
        let first = TestWindow.new(id: 40, parent: a.rootTilingContainer, app: relaunched)
        let second = TestWindow.new(id: 41, parent: a.rootTilingContainer, app: relaunched)
        _ = try await routeNewWindowToSavedWorkspaceIfNeeded(first, isRegularWindow: true)
        _ = try await routeNewWindowToSavedWorkspaceIfNeeded(second, isRegularWindow: true)
        XCTAssertTrue(first.nodeWorkspace === c, "The tab it was reopened from first")
        XCTAssertTrue(second.nodeWorkspace === b, "then the other tab's window returns too")
    }

    func testUndoingAnEditKeepsWhatCapturesLearnedAboutTabsItDidntTouch() throws {
        let (a, b, c) = threeTabs()
        try setWorkspaceSidebarTabsFavorite([b, c], true)
        // c was saved before tabs recorded their apps, and its app has quit.
        XCTAssertTrue(savedWorkspaceStore.update(named: c.name) { $0.launchApps = nil })
        c.allLeafWindowsRecursive[0].closeAxWindow()
        Workspace.reconcileWorkspaceState()
        let before = WorkspaceSidebarTabUndoSnapshot()
        move(a.allLeafWindowsRecursive[0], to: b)
        WorkspaceSidebarTabUndo.shared.record("Move Tab", before: before)
        captureSavedWorkspaces(facts: savedTestFacts())
        XCTAssertEqual(savedWorkspaceStore.record(named: c.name)?.launchApps?.map(\.bundleId), ["bobko.WinMux.test-app"])
        try WorkspaceSidebarTabUndo.shared.undo()
        XCTAssertEqual(savedWorkspaceStore.record(named: c.name)?.launchApps?.map(\.bundleId), ["bobko.WinMux.test-app"],
            "The move didn't touch c")
    }

    func testUndoRestoresWhichAppsASavedTabShows() throws {
        let (a, b, _) = threeTabs()
        try setWorkspaceSidebarTabFavorite(b, true)
        captureSavedWorkspaces(facts: savedTestFacts())
        let before = WorkspaceSidebarTabUndoSnapshot()
        move(b.allLeafWindowsRecursive[0], to: a)
        XCTAssertTrue(savedWorkspaceStore.update(named: b.name) {
            $0.launchApps = [SavedLaunchApp(bundleId: "com.apple.Terminal", bundlePath: nil, appName: "Terminal")]
        })
        WorkspaceSidebarTabUndo.shared.record("Move Tab", before: before)
        try WorkspaceSidebarTabUndo.shared.undo()
        XCTAssertEqual(savedWorkspaceStore.record(named: b.name)?.launchApps?.map(\.bundleId), ["bobko.WinMux.test-app"])
    }

    func testReopeningASavedTabRelaunchesItsAppIntoItOrAsksARunningAppForAWindowThere() throws {
        let (a, b, c) = threeTabs()
        try setWorkspaceSidebarTabsFavorite([b, c], true)
        Workspace.reconcileWorkspaceState()
        captureSavedWorkspaces(facts: savedTestFacts())
        let app = try XCTUnwrap(b.allLeafWindowsRecursive.first?.app.rawAppBundleId)
        // Their app quit: the windows are gone, their saved slots wait for them.
        for tab in [b, c] { tab.allLeafWindowsRecursive[0].closeAxWindow() }
        var requested: [(String, String)] = []
        setSavedWorkspaceTestEnvironment(runningApps: [:])
        openSavedTabApps(c) { target, tab in requested.append((target.bundleId, tab.name)) }
        XCTAssertTrue(requested.isEmpty, "Not running: it relaunches")
        XCTAssertEqual(savedWorkspaceRuntime.preferredRestoreWorkspace(bundleId: app), c.name)
        let waiting = waitingSavedSlots(bundleId: app, routingWindow: TestWindow.new(id: 9, parent: a.rootTilingContainer))
        XCTAssertEqual(waiting.first?.workspaceName, c.name, "The tab it was reopened from takes its windows first")

        setSavedWorkspaceTestEnvironment(runningApps: [app: [SavedRunningApp(pid: 1, launchDate: nil)]])
        openSavedTabApps(b) { target, tab in requested.append((target.bundleId, tab.name)) }
        XCTAssertEqual(requested.map(\.0), [app], "Running: it's asked for a window in the tab")
        XCTAssertEqual(requested.map(\.1), [b.name])

        setSavedWorkspaceTestEnvironment(runningApps: [:])
        captureSavedWorkspaces(facts: savedTestFacts())
        XCTAssertTrue(savedWorkspaceStore.update(named: c.name) { $0.layout = .init() })
        requested = []
        openSavedTabApps(c) { target, tab in requested.append((target.bundleId, tab.name)) }
        XCTAssertEqual(requested.map(\.1), [c.name],
            "Its saved window expired: the app is opened for a window here instead of relaunched into slots")
    }

    func testOnlyAClickThatActivatesAGreyedTabOpensItsApps() {
        var sent: [WorkspaceSidebarAction] = []
        let refused = WorkspaceSidebarTabActivation(allowsActivation: false, isInUseOnOtherDisplay: false, requestOverride: {})
        refused.select(.openSavedTab("pin"), send: { sent.append($0) })
        XCTAssertTrue(sent.isEmpty)
        var asked = false
        let elsewhere = WorkspaceSidebarTabActivation(allowsActivation: true, isInUseOnOtherDisplay: true,
            requestOverride: { asked = true })
        elsewhere.select(.openSavedTab("pin"), send: { sent.append($0) })
        XCTAssertTrue(asked, "In use on another display, it asks first")
        XCTAssertFalse(sent.contains { if case .openSavedTab = $0 { true } else { false } })
    }

    func testOtherModesKeepTheEmptyWorkspaceOnScreen() {
        let (a, _, c) = threeTabs()
        config.workspaceSidebar.mode = .sidebar
        move(a.allLeafWindowsRecursive[0], to: c)
        settle()
        XCTAssertTrue(focus.workspace === a)
        XCTAssertFalse(workspaceTabWasLeftEmpty(a))
    }
}
