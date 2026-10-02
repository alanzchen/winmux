import AppKit
@testable import AppBundle
import Common
import XCTest

/// Tabs mode: a pin in All Projects shows in every project's sidebar, so showing it keeps the display
/// in the project it's in, rather than taking it to the pin's own. Everything that means "the
/// project the user is in" follows that display's project.
@MainActor
final class WorkspaceSidebarPinScopeActivationTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        setSavedWorkspaceTestEnvironment()
        resetWorkspaceTabsForTests()
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

    private struct Tabs {
        let a: WorkspaceProjectId
        let b: WorkspaceProjectId
        let a1, g, a2, b1, b2: Workspace
    }

    private var nextWindowId: UInt32 = 1

    private func tab(_ name: String, in projectId: WorkspaceProjectId) -> Workspace {
        let tab = Workspace.get(byName: name)
        _ = TestWindow.new(id: nextWindowId, parent: tab.rootTilingContainer)
        nextWindowId += 1
        tab.assignProject(projectId)
        return tab
    }

    /// Projects A and B with two tabs each, and A's `g` pinned in All Projects between A's tabs.
    /// B's `b1` is on screen, so the display is in B.
    private func tabs() throws -> Tabs {
        let a = createWorkspaceProject().id
        let b = createWorkspaceProject().id
        let a1 = tab("a1", in: a), g = tab("g", in: a), a2 = tab("a2", in: a)
        let b1 = tab("b1", in: b), b2 = tab("b2", in: b)
        XCTAssertTrue(a1.focusWorkspace())
        try setWorkspaceSidebarTabPinScope(g, .allProjects, projectId: a)
        XCTAssertTrue(workspaceIsPinnedInAllProjects(g))
        XCTAssertTrue(b1.focusWorkspace())
        Workspace.reconcileWorkspaceState()
        XCTAssertEqual(activeWorkspaceProjectId(for: mainMonitor), b)
        return Tabs(a: a, b: b, a1: a1, g: g, a2: a2, b1: b1, b2: b2)
    }

    private func names(_ workspaces: [Workspace]) -> [String] {
        workspaces.map(\.name).filter { ["a1", "g", "a2", "b1", "b2"].contains($0) }
    }

    private func displays() -> (left: Monitor, right: Monitor) {
        let monitors = ["Left", "Right"].enumerated().map { index, name in
            let rect = Rect(topLeftX: CGFloat(index) * 1920, topLeftY: 0, width: 1920, height: 1080)
            return WorkspaceSidebarDragTestMonitor(monitorAppKitNsScreenScreensId: index + 1, name: name, rect: rect,
                visibleRect: rect, isMain: index == 0)
        }
        setMonitorsForTests(monitors)
        Workspace.reconcileWorkspaceState()
        return (monitors[0], monitors[1])
    }

    // MARK: Showing one

    func testShowingAPinInAllProjectsKeepsTheDisplayInItsProject() async throws {
        let t = try tabs()
        XCTAssertTrue(t.g.focusWorkspace())
        XCTAssertTrue(mainMonitor.activeWorkspace === t.g)
        XCTAssertEqual(activeWorkspaceProjectId(for: mainMonitor), t.b, "Not taken to the pin's own project")
        XCTAssertEqual(workspaceContextProjectId(of: t.g), t.b)
        XCTAssertEqual(t.g.projectId, t.a, "The pin stays at home")
        await updateWorkspaceSidebarModel()
        XCTAssertEqual(TrayMenuModel.shared.workspaceSidebarActiveProjectId, t.b, "The sidebar stays in B")
        Workspace.reconcileWorkspaceState()
        XCTAssertEqual(activeWorkspaceProjectId(for: mainMonitor), t.b, "Through a refresh too")

        XCTAssertTrue(t.a1.focusWorkspace())
        XCTAssertEqual(activeWorkspaceProjectId(for: mainMonitor), t.a, "An ordinary tab still takes the display to its project")
        XCTAssertTrue(t.g.focusWorkspace())
        XCTAssertEqual(activeWorkspaceProjectId(for: mainMonitor), t.a, "and the pin then shows in that one")
    }

    func testFocusingAPinsWindowFromMacOSKeepsTheProject() throws {
        let t = try tabs()
        let window = try XCTUnwrap(t.g.allLeafWindowsRecursive.first)
        updateFocusCache(window)
        XCTAssertTrue(focus.workspace === t.g)
        XCTAssertEqual(activeWorkspaceProjectId(for: mainMonitor), t.b, "Cmd-Tab into the pin keeps B")
    }

    func testProjectPinsAndPinsOutsideTabsModeStillTakeTheDisplayToTheirProject() throws {
        let t = try tabs()
        try setWorkspaceSidebarTabFavorite(t.a2, true)
        XCTAssertTrue(t.a2.focusWorkspace())
        XCTAssertEqual(activeWorkspaceProjectId(for: mainMonitor), t.a, "A project pin is its project's, as before")

        XCTAssertTrue(t.b1.focusWorkspace())
        config.workspaceSidebar.mode = .dock
        XCTAssertFalse(workspaceIsPinnedInAllProjects(t.g), "Pins are Tabs mode's")
        XCTAssertTrue(t.g.focusWorkspace())
        XCTAssertEqual(activeWorkspaceProjectId(for: mainMonitor), t.a, "Elsewhere it's an ordinary workspace of A")
    }

    func testWithNoProjectToStayInItOpensInItsHome() throws {
        let t = try tabs()
        // As at launch: no display has been in a project yet.
        winMuxWorkspaceState.monitorViewportsById = [:]
        XCTAssertTrue(mainMonitor.setActiveWorkspace(t.g))
        XCTAssertEqual(activeWorkspaceProjectId(for: mainMonitor), t.a)
    }

    // MARK: Switching projects

    /// Alan's choice (N2): with a pin in All Projects on screen, switching project keeps it there and
    /// changes only the display's project, which the sidebar's project pins and list then show.
    func testSwitchingProjectWithAPinInAllProjectsOnScreenKeepsItThere() async throws {
        let t = try tabs()
        try setWorkspaceSidebarTabFavorite(t.a2, true)
        XCTAssertTrue(t.g.focusWorkspace())
        let window = focus.windowOrNil
        XCTAssertNotNil(window)

        // As choosing a project in the sidebar does: switch, then focus what the display shows.
        let shown = try XCTUnwrap(switchWorkspaceProject(t.a, on: mainMonitor))
        XCTAssertTrue(shown === t.g, "The pin stays on screen")
        XCTAssertTrue(shown.focusWorkspace())
        XCTAssertTrue(mainMonitor.activeWorkspace === t.g)
        XCTAssertTrue(focus.workspace === t.g)
        XCTAssertTrue(focus.windowOrNil === window, "with the same window focused")
        XCTAssertEqual(activeWorkspaceProjectId(for: mainMonitor), t.a, "Only the display's project changes")
        XCTAssertFalse(t.a1.isVisible, "A's last tab isn't brought back")
        Workspace.reconcileWorkspaceState()
        XCTAssertEqual(activeWorkspaceProjectId(for: mainMonitor), t.a)

        await updateWorkspaceSidebarModel()
        XCTAssertEqual(TrayMenuModel.shared.workspaceSidebarActiveProjectId, t.a)
        var snapshot = WorkspaceSidebarSnapshot.empty
        snapshot.workspaces = TrayMenuModel.shared.workspaceSidebarWorkspaces
        snapshot.activeProjectId = TrayMenuModel.shared.workspaceSidebarActiveProjectId
        snapshot.selectedMonitorScopeId = workspaceSidebarMonitorScopeId(for: mainMonitor)
        snapshot.targetMonitorScopeId = workspaceSidebarMonitorScopeId(for: mainMonitor)
        snapshot.focusedMonitorScopeId = TrayMenuModel.shared.workspaceSidebarFocusedMonitorScopeId
        snapshot.configuration.usesTabsList = true
        XCTAssertEqual(snapshot.tabsListedWorkspaces(for: t.a).map(\.name).filter { ["g", "a1", "a2", "b1", "b2"].contains($0) },
            ["g", "a2", "a1"], "The pin above, then A's pin and A's tabs")

        XCTAssertTrue(switchWorkspaceProject(t.b, on: mainMonitor) === t.g)
        XCTAssertEqual(activeWorkspaceProjectId(for: mainMonitor), t.b)
    }

    /// A project remembers the tab chosen while the display was in it (an implementation choice):
    /// passing through projects on a pin in All Projects changes none of their memories.
    func testKeepingThePinOnScreenLeavesEveryProjectsRememberedTab() throws {
        let t = try tabs()
        let viewportId = MonitorViewportId(mainMonitor)
        func remembered(_ projectId: WorkspaceProjectId) -> WorkspaceId? {
            winMuxWorkspaceState.monitorViewportsById[viewportId]?.lastActiveWorkspaceByProject[projectId]
        }
        XCTAssertTrue(t.g.focusWorkspace())
        XCTAssertEqual(remembered(t.b), t.g.id, "Chosen in B")
        XCTAssertTrue(switchWorkspaceProject(t.a, on: mainMonitor)?.focusWorkspace() == true)
        XCTAssertEqual(remembered(t.a), t.a1.id, "Passing through A on the pin leaves A's last tab")
        // A refresh, or an Undo, shows the display's tab again: still nothing chosen.
        XCTAssertTrue(mainMonitor.setActiveWorkspace(t.g))
        Workspace.reconcileWorkspaceState()
        XCTAssertEqual(remembered(t.a), t.a1.id)
        XCTAssertEqual(activeWorkspaceProjectId(for: mainMonitor), t.a)

        XCTAssertTrue(t.a2.focusWorkspace())
        XCTAssertEqual(remembered(t.a), t.a2.id)
        XCTAssertTrue(switchWorkspaceProject(t.b, on: mainMonitor) === t.g,
            "From an ordinary tab, B's last chosen tab comes back, as before: here the pin")
        XCTAssertEqual(activeWorkspaceProjectId(for: mainMonitor), t.b)
        XCTAssertTrue(t.b2.focusWorkspace())
        XCTAssertTrue(switchWorkspaceProject(t.a, on: mainMonitor) === t.a2, "and A's, the one chosen there")
    }

    func testSwitchingFromAnOrdinaryOrProjectPinnedTabRestoresTheDestinationsTab() throws {
        let t = try tabs()
        XCTAssertTrue(switchWorkspaceProject(t.a, on: mainMonitor) === t.a1, "From b1, A's last tab, as before")
        XCTAssertEqual(activeWorkspaceProjectId(for: mainMonitor), t.a)
        try setWorkspaceSidebarTabFavorite(t.a2, true)
        XCTAssertTrue(t.a2.focusWorkspace())
        XCTAssertTrue(switchWorkspaceProject(t.b, on: mainMonitor) === t.b1, "A project pin doesn't stay on screen")
        XCTAssertTrue(mainMonitor.activeWorkspace === t.b1)
        XCTAssertEqual(activeWorkspaceProjectId(for: mainMonitor), t.b)
    }

    func testEachDisplayKeepsItsOwnProjectAsItSwitches() throws {
        let (left, right) = displays()
        let t = try tabs()
        let c = createWorkspaceProject().id
        let c1 = tab("c1", in: c)
        c1.preferredMonitorPoint = right.rect.topLeftCorner
        XCTAssertTrue(right.setActiveWorkspace(c1))
        XCTAssertTrue(t.g.focusWorkspace())
        XCTAssertTrue(left.activeWorkspace === t.g)
        XCTAssertEqual(activeWorkspaceProjectId(for: left), t.b)

        XCTAssertTrue(switchWorkspaceProject(c, on: left) === t.g, "The pin's display keeps it")
        XCTAssertEqual(activeWorkspaceProjectId(for: left), c)
        XCTAssertTrue(right.activeWorkspace === c1, "The other display in C is untouched")

        let other = try XCTUnwrap(switchWorkspaceProject(t.a, on: right))
        XCTAssertEqual(other.projectId, t.a, "The other display, on an ordinary tab, switches as before")
        XCTAssertTrue(right.activeWorkspace === other)
        XCTAssertTrue(left.activeWorkspace === t.g)
        XCTAssertEqual(activeWorkspaceProjectId(for: left), c, "and the pin's display stays in C")
        XCTAssertEqual(activeWorkspaceProjectId(for: right), t.a)
    }

    func testUndoAroundASwitchKeepsTheProjectTheDisplayIsIn() async throws {
        let t = try tabs()
        XCTAssertTrue(t.g.focusWorkspace())
        // An edit, then a switch with the pin on screen: switching isn't an edit, and Undo leaves it.
        await handleWorkspaceSidebarOrganizationAction(.setWorkspaceFavorite(t.b2.name, true),
            targetMonitorScopeId: workspaceSidebarMonitorScopeId(for: mainMonitor))?.value
        XCTAssertEqual(WorkspaceSidebarTabUndo.shared.title, "Undo Pin Tab")
        XCTAssertTrue(switchWorkspaceProject(t.a, on: mainMonitor) === t.g)
        WorkspaceSidebarTabUndo.shared.invalidateIfChanged()
        XCTAssertEqual(WorkspaceSidebarTabUndo.shared.title, "Undo Pin Tab")
        try WorkspaceSidebarTabUndo.shared.undo()
        XCTAssertNotEqual(workspaceSidebarOrganizationStore.state.workspaces[t.b2.name]?.isFavorite, true)
        XCTAssertTrue(mainMonitor.activeWorkspace === t.g)
        XCTAssertEqual(activeWorkspaceProjectId(for: mainMonitor), t.a, "Undo doesn't take the display back to B")

        // An edit that changed the tab on screen, undone after the user came back to the pin and
        // switched: the display keeps the pin and the project it was switched to.
        let moved = TestWindow.new(id: 95, parent: t.g.rootTilingContainer)
        XCTAssertTrue(t.g.focusWorkspace())
        let before = WorkspaceSidebarTabUndoSnapshot()
        try detachWorkspaceTabWindow(moved)
        WorkspaceSidebarTabUndo.shared.record("Move to New Tab", before: before)
        XCTAssertEqual(moved.nodeWorkspace?.projectId, t.a)
        XCTAssertTrue(t.g.focusWorkspace())
        XCTAssertTrue(switchWorkspaceProject(t.b, on: mainMonitor) === t.g)
        try WorkspaceSidebarTabUndo.shared.undo()
        XCTAssertTrue(moved.nodeWorkspace === t.g, "The window is back in the pin")
        XCTAssertTrue(mainMonitor.activeWorkspace === t.g)
        XCTAssertEqual(activeWorkspaceProjectId(for: mainMonitor), t.b)
    }

    func testAProjectDoesntOpenOnAPinItNeverShowed() throws {
        let t = try tabs()
        winMuxWorkspaceState.moveWorkspace(t.g.id, relativeTo: t.a1.id, after: false)
        let viewportId = MonitorViewportId(mainMonitor)
        winMuxWorkspaceState.monitorViewportsById[viewportId]?.lastActiveWorkspaceByProject = [:]
        let shown = try XCTUnwrap(switchWorkspaceProject(t.a, on: mainMonitor))
        XCTAssertFalse(shown === t.g, "The pin is first in A's order, but it isn't where A opens")
        XCTAssertEqual(shown.projectId, t.a)
    }

    func testARememberedTabFromAnotherProjectIsntShown() throws {
        let t = try tabs()
        winMuxWorkspaceState.monitorViewportsById[MonitorViewportId(mainMonitor)]?.lastActiveWorkspaceByProject[t.b] = t.a2.id
        XCTAssertTrue(switchWorkspaceProject(t.a, on: mainMonitor) === t.a1)
        XCTAssertEqual(switchWorkspaceProject(t.b, on: mainMonitor)?.projectId, t.b)
    }

    // MARK: Tabs opened from one

    func testAWindowOpenedFromAPinInAllProjectsOpensFirstInTheDisplaysProject() throws {
        let t = try tabs()
        XCTAssertTrue(t.g.focusWorkspace())
        let homeOrder = orderedWorkspaces(in: t.a).map(\.name)
        let first = createWorkspaceForNewWindow(openedFrom: t.g, monitor: mainMonitor, now: 100)
        XCTAssertEqual(first.projectId, t.b)
        XCTAssertTrue(orderedWorkspaces(in: t.b).first === first, "First among B's tabs, just below the pins")
        let second = createWorkspaceForNewWindow(openedFrom: t.g, monitor: mainMonitor, now: 101)
        XCTAssertEqual(orderedWorkspaces(in: t.b).prefix(2).map(\.name), [first.name, second.name], "A burst lines up in order")
        XCTAssertEqual(orderedWorkspaces(in: t.a).map(\.name), homeOrder, "Nothing opens in the pin's home")
        XCTAssertTrue(second.focusWorkspace())
        XCTAssertEqual(activeWorkspaceProjectId(for: mainMonitor), t.b)
    }

    func testNewTabFromAPinInAllProjectsOpensFirstAndCancellingGoesBackToIt() throws {
        let t = try tabs()
        XCTAssertTrue(t.g.focusWorkspace())
        let newTab = newTabWorkspace(projectId: t.b, monitor: mainMonitor)
        XCTAssertTrue(newTab.isNew)
        XCTAssertEqual(newTab.workspace.projectId, t.b)
        XCTAssertTrue(orderedWorkspaces(in: t.b).first === newTab.workspace)
        XCTAssertTrue(newTab.previous === t.g)
        XCTAssertTrue(newTab.workspace.focusWorkspace())
        closeUnusedNewTab(newTab)
        XCTAssertTrue(mainMonitor.activeWorkspace === t.g, "Cancelling goes back to the pin")
        XCTAssertEqual(activeWorkspaceProjectId(for: mainMonitor), t.b)
    }

    func testWindowsTakenOutOfAPinInAllProjectsGetTabsOfTheDisplaysProject() throws {
        let t = try tabs()
        let moved = TestWindow.new(id: 90, parent: t.g.rootTilingContainer)
        _ = TestWindow.new(id: 91, parent: t.g.rootTilingContainer)
        XCTAssertTrue(t.g.focusWorkspace())
        try detachWorkspaceTabWindow(moved)
        XCTAssertEqual(moved.nodeWorkspace?.projectId, t.b, "Move to New Tab")
        XCTAssertEqual(activeWorkspaceProjectId(for: mainMonitor), t.b)

        XCTAssertTrue(t.g.focusWorkspace())
        let before = Set(t.g.allLeafWindowsRecursive.map(\.windowId))
        separateWorkspaceIntoTabs(t.g)
        let separated = before.subtracting(t.g.allLeafWindowsRecursive.map(\.windowId))
        XCTAssertFalse(separated.isEmpty)
        for id in separated { XCTAssertEqual(Window.get(byId: id)?.nodeWorkspace?.projectId, t.b, "Separate into Tabs") }
        XCTAssertTrue(workspaceIsPinnedInAllProjects(t.g), "The pin keeps its window and stays pinned")
    }

    func testClosingAnEmptyPinInAllProjectsLeavesTheDisplayInItsProject() throws {
        let t = try tabs()
        XCTAssertTrue(t.g.focusWorkspace())
        for window in t.g.allLeafWindowsRecursive { window.unbindFromParent() }
        try deleteWorkspace(t.g)
        XCTAssertNil(Workspace.existing(byName: "g"))
        XCTAssertEqual(mainMonitor.activeWorkspace.projectId, t.b, "Its place goes to a tab of B, not of its home")
        XCTAssertEqual(activeWorkspaceProjectId(for: mainMonitor), t.b)
    }

    // MARK: The project the user is in

    func testTabNavigationLeadsWithThePinsInAllProjects() throws {
        let t = try tabs()
        try setWorkspaceSidebarTabFavorite(t.b2, true)
        XCTAssertEqual(names(workspaceNavigationTabs(current: t.b1)), ["g", "b2", "b1"])
        XCTAssertTrue(t.g.focusWorkspace())
        XCTAssertEqual(names(workspaceNavigationTabs(current: t.g)), ["g", "b2", "b1"], "From the pin, B's tabs")
        XCTAssertEqual(getNextPrevWorkspace(current: t.g, isNext: true, wrapAround: false, stdin: nil)?.name, "b2")
        XCTAssertEqual(names(workspaceNavigationTabs(current: t.a1)), ["g", "a1", "a2"], "In A, A's tabs below it")
    }

    func testATabCanSplitWithAPinInAllProjectsShownWithIt() throws {
        let t = try tabs()
        let window = try XCTUnwrap(t.b1.allLeafWindowsRecursive.first)
        XCTAssertTrue(canSplitWorkspaceSidebarTabWindow(window, with: t.g))
        XCTAssertTrue(workspaceSidebarSplitDestinations(windowId: window.windowId).contains { $0 === t.g })
        XCTAssertFalse(canSplitWorkspaceSidebarTabWindow(window, with: t.a1), "Not with another project's tab")
    }

    func testTheTrayAndTheSidebarListThePinWhereItsShown() async throws {
        let t = try tabs()
        XCTAssertTrue(t.g.focusWorkspace())
        updateTrayText()
        XCTAssertTrue(TrayMenuModel.shared.workspaces.contains { $0.name == "g" })
        XCTAssertFalse(TrayMenuModel.shared.workspaces.contains { $0.name == "a1" })
        await updateWorkspaceSidebarModel()
        var snapshot = WorkspaceSidebarSnapshot.empty
        snapshot.workspaces = TrayMenuModel.shared.workspaceSidebarWorkspaces
        snapshot.activeProjectId = TrayMenuModel.shared.workspaceSidebarActiveProjectId
        snapshot.selectedMonitorScopeId = workspaceSidebarDefaultScopeId
        snapshot.targetMonitorScopeId = workspaceSidebarMonitorScopeId(for: mainMonitor)
        snapshot.focusedMonitorScopeId = TrayMenuModel.shared.workspaceSidebarFocusedMonitorScopeId
        snapshot.configuration.usesTabsList = true
        XCTAssertEqual(snapshot.tabsPinnedWorkspaces(for: t.b).map(\.name), ["g"])
    }

    // MARK: Displays

    func testBringingAPinInAllProjectsToAnotherDisplayLeavesEachDisplayInItsProject() throws {
        let (left, right) = displays()
        let t = try tabs()
        let c = createWorkspaceProject().id
        let c1 = tab("c1", in: c)
        c1.preferredMonitorPoint = right.rect.topLeftCorner
        XCTAssertTrue(right.setActiveWorkspace(c1))
        XCTAssertTrue(t.g.focusWorkspace())
        XCTAssertTrue(left.activeWorkspace === t.g)

        XCTAssertTrue(placeWorkspaceTabOnDisplay(t.g, right))
        XCTAssertTrue(right.activeWorkspace === t.g)
        XCTAssertEqual(activeWorkspaceProjectId(for: right), c, "It shows in the project the right display is in")
        XCTAssertEqual(activeWorkspaceProjectId(for: left), t.b, "and the left display stays in B")
        XCTAssertEqual(left.activeWorkspace.projectId, t.b)

        XCTAssertTrue(overrideWorkspaceOnMonitorBySwappingActiveViewports(t.g, targetMonitor: left))
        XCTAssertTrue(left.activeWorkspace === t.g)
        XCTAssertEqual(activeWorkspaceProjectId(for: left), t.b)
        XCTAssertEqual(activeWorkspaceProjectId(for: right), c, "The display it leaves stays in C")
        XCTAssertEqual(right.activeWorkspace.projectId, c)
    }

    func testRearrangingDisplaysKeepsTheProjectEachIsIn() throws {
        let (left, _) = displays()
        let t = try tabs()
        XCTAssertTrue(t.g.focusWorkspace())
        XCTAssertTrue(left.activeWorkspace === t.g)
        // The display moves: its viewport is rebuilt at the new point.
        let moved = WorkspaceSidebarDragTestMonitor(monitorAppKitNsScreenScreensId: 1, name: "Left",
            rect: Rect(topLeftX: 0, topLeftY: 200, width: 1920, height: 1080),
            visibleRect: Rect(topLeftX: 0, topLeftY: 200, width: 1920, height: 1080), isMain: true)
        setMonitorsForTests([moved])
        rearrangeWorkspacesOnMonitors()
        XCTAssertTrue(moved.activeWorkspace === t.g)
        XCTAssertEqual(activeWorkspaceProjectId(for: moved), t.b)
    }

    /// Review: showing the pin again after the displays change chooses nothing, so each project
    /// still opens on the tab chosen in it.
    func testRearrangingDisplaysKeepsWhatEachProjectRemembers() throws {
        let (left, _) = displays()
        let t = try tabs()
        XCTAssertTrue(t.g.focusWorkspace())
        XCTAssertTrue(switchWorkspaceProject(t.a, on: left) === t.g)
        let memory = winMuxWorkspaceState.monitorViewportsById[MonitorViewportId(left)]?.lastActiveWorkspaceByProject
        XCTAssertEqual(memory?[t.a], t.a1.id)
        let moved = WorkspaceSidebarDragTestMonitor(monitorAppKitNsScreenScreensId: 1, name: "Left",
            rect: Rect(topLeftX: 0, topLeftY: 200, width: 1920, height: 1080),
            visibleRect: Rect(topLeftX: 0, topLeftY: 200, width: 1920, height: 1080), isMain: true)
        setMonitorsForTests([moved])
        rearrangeWorkspacesOnMonitors()
        XCTAssertTrue(moved.activeWorkspace === t.g)
        XCTAssertEqual(activeWorkspaceProjectId(for: moved), t.a)
        XCTAssertEqual(winMuxWorkspaceState.monitorViewportsById[MonitorViewportId(moved)]?.lastActiveWorkspaceByProject, memory)
        XCTAssertTrue(t.b1.focusWorkspace())
        XCTAssertTrue(switchWorkspaceProject(t.a, on: moved) === t.a1, "A still opens on the tab chosen in it")
    }

    /// Review: a pin in All Projects pinned back in another display's project takes the display
    /// showing it there too, without changing its tab. Undo takes that display back to its project.
    func testUndoTakesBackTheProjectOfADisplayThatKeptItsTab() async throws {
        config.workspaceSidebar.sharePinnedTabs = true
        let (left, right) = displays()
        let t = try tabs()
        let c = createWorkspaceProject().id
        let c1 = tab("c1", in: c)
        c1.preferredMonitorPoint = right.rect.topLeftCorner
        XCTAssertTrue(right.setActiveWorkspace(c1))
        XCTAssertTrue(t.g.focusWorkspace())
        XCTAssertTrue(left.activeWorkspace === t.g)
        let leftBefore = winMuxWorkspaceState.monitorViewportsById[MonitorViewportId(left)]
        await handleWorkspaceSidebarOrganizationAction(.setWorkspacePinScope(t.g.name, nil, projectId: c),
            targetMonitorScopeId: workspaceSidebarMonitorScopeId(for: right))?.value
        XCTAssertEqual(t.g.projectId, c)
        XCTAssertTrue(left.activeWorkspace === t.g)
        XCTAssertEqual(activeWorkspaceProjectId(for: left), c, "The display showing it is in C with it")
        try WorkspaceSidebarTabUndo.shared.undo()
        XCTAssertTrue(workspaceIsPinnedInAllProjects(t.g))
        XCTAssertTrue(left.activeWorkspace === t.g)
        XCTAssertEqual(activeWorkspaceProjectId(for: left), t.b, "and back in B, still on the pin")
        XCTAssertEqual(winMuxWorkspaceState.monitorViewportsById[MonitorViewportId(left)]?.lastActiveWorkspaceByProject,
            leftBefore?.lastActiveWorkspaceByProject)
        XCTAssertTrue(right.activeWorkspace === c1)
        XCTAssertEqual(activeWorkspaceProjectId(for: right), c)
    }

    // MARK: Deleting projects

    func testDeletingItsHomeKeepsAPinInAllProjectsWithItsWindowsAtHomeInDefault() async throws {
        let t = try tabs()
        XCTAssertTrue(t.g.focusWorkspace())
        let windows = t.g.allLeafWindowsRecursive.map(ObjectIdentifier.init)
        XCTAssertFalse(windowsInWorkspaceProject(t.a).contains { windows.contains(ObjectIdentifier($0)) },
            "Not A's windows to close or move")
        XCTAssertFalse(windowsInWorkspaceProject(t.a).isEmpty)

        try await deleteWorkspaceProject(t.a, action: .moveWindowsToFallback)

        XCTAssertTrue(Workspace.existing(byName: "g") === t.g)
        XCTAssertEqual(t.g.projectId, workspaceProjectDefaultId)
        XCTAssertTrue(workspaceIsPinnedInAllProjects(t.g))
        XCTAssertEqual(t.g.allLeafWindowsRecursive.map(ObjectIdentifier.init), windows)
        XCTAssertEqual(savedWorkspaceStore.record(named: "g")?.projectId, workspaceProjectDefaultId)
        XCTAssertTrue(mainMonitor.activeWorkspace === t.g)
        XCTAssertEqual(activeWorkspaceProjectId(for: mainMonitor), t.b)
        XCTAssertNil(winMuxWorkspaceState.projectsById[t.a])
    }

    func testDeletingTheProjectAPinIsShownInTakesTheDisplayToTheFallback() async throws {
        let t = try tabs()
        XCTAssertTrue(t.g.focusWorkspace())
        try await deleteWorkspaceProject(t.b, action: .moveWindowsToFallback)
        XCTAssertTrue(Workspace.existing(byName: "g") === t.g, "The pin isn't B's")
        XCTAssertEqual(t.g.projectId, t.a)
        XCTAssertNotEqual(activeWorkspaceProjectId(for: mainMonitor), t.b)
        XCTAssertNotNil(winMuxWorkspaceState.projectsById[activeWorkspaceProjectId(for: mainMonitor)])
        XCTAssertNil(winMuxWorkspaceState.monitorViewportsById[MonitorViewportId(mainMonitor)]?.lastActiveWorkspaceByProject[t.b])
    }
}
