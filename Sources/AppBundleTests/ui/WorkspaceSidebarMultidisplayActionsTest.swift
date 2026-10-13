import AppKit
@testable import AppBundle
import Common
import SwiftUI
import XCTest

/// Moving a display's tabs to another display from the Tabs footer, and clicking a shared pin
/// that's on another display: shown there by default, brought here by ⌘-click or the other
/// setting. Everything here runs on the model, with WinMux's sessions off, so no panel, window,
/// notice or pointer move ever reaches the screen; the footer renders in a window-less view.
@MainActor
final class WorkspaceSidebarMultidisplayActionsTest: XCTestCase {
    private var wasEnabled = true
    private var notices: [WinMuxToastNotice] = []
    /// `on-focused-monitor-changed` as it would run, by the focused tab, and whether it keeps the pointer.
    private var monitorHooks: [MonitorHook] = []
    private var selections: [BrowserTabSelection] = []
    private let saved = MultidisplaySeams()

    override func setUp() async throws {
        setUpWorkspacesForTests()
        workspaceSidebarOrganizationStore = .init()
        // No session runs, so no sidebar refresh can frame a panel on a display.
        wasEnabled = TrayMenuModel.shared.isEnabled
        TrayMenuModel.shared.isEnabled = false
        notices = []
        monitorHooks = []
        selections = []
        showWorkspaceSidebarNotice = { [unowned self] in notices.append($0) }
        runFocusedMonitorChangedCommands = { [unowned self] focus, keepsPointer in
            monitorHooks.append(.init(focus.workspace.name, keepsPointer: keepsPointer))
        }
        postMoveMouseEvent = { _ in XCTFail("No real pointer move"); return false }
        selectWorkspaceSidebarBrowserTab = { [unowned self] in selections.append(.init($0, $1, keepsPointer: $2)) }
        workspaceSidebarBrowserTabIsListed = { _ in true }
        WorkspaceSidebarTabSelection.shared.clear()
    }

    override func tearDown() async throws {
        saved.restore()
        try await activateMode(mainModeId)
        WorkspaceSidebarTabSelection.shared.clear()
        WorkspaceSidebarTabUndo.shared.clear()
        workspaceSidebarOrganizationStore = .init()
        setMonitorsForTests(nil)
        config = defaultConfig
        TrayMenuModel.shared.isEnabled = wasEnabled
        try await super.tearDown()
    }

    // MARK: Moving a display's tabs

    func testMovesEveryTabOfTheListInItsOrderAfterTheOtherDisplaysTabs() throws {
        let (monitors, tabs) = try displays(2, hidden: [0: ["a0", "b0"], 1: ["c1"]])
        let (left, right) = (monitors[0], monitors[1])
        let projectId = tabs["shown0"]!.projectId
        let pinOrder = workspacePinnedTabs(in: projectId).map(\.name)
        let windows = Set(Workspace.all.flatMap { $0.allLeafWindowsRecursive.map(\.windowId) })
        let before = WorkspaceSidebarTabUndoSnapshot()
        let orderBefore = projectWorkspaces(projectId: projectId).map(\.name)
        XCTAssertEqual(listed(on: right, projectId), ["shown1", "c1"])

        let outcome = moveWorkspaceTabsToDisplay(projectId: projectId, from: scope(left), to: scope(right))
        XCTAssertEqual(outcome.moved, ["pin0", "shown0", "a0", "b0"], "In the list's order, pins first")
        XCTAssertEqual(outcome.staying, [])
        XCTAssertEqual(outcome.notice, "Moved 4 tabs to “Right”.")
        for name in ["pin0", "shown0", "a0", "b0"] {
            XCTAssertEqual(tabs[name]!.workspaceMonitor.rect, right.rect, "\(name) is on the other display")
        }
        XCTAssertEqual(listed(on: right, projectId), ["shown1", "c1", "shown0", "a0", "b0"], "After its own, in their order")
        XCTAssertEqual(workspacePinnedTabs(in: projectId).map(\.name), pinOrder, "Pins keep their order")
        XCTAssertTrue(right.activeWorkspace === tabs["shown0"], "The tab on screen is on screen there")
        XCTAssertTrue(focus.workspace === tabs["shown0"], "Focus goes with it")
        checkOnFocusChangedCallbacks()
        XCTAssertEqual(monitorHooks, [.init("shown0", keepsPointer: true)], "Its hooks run; the pointer stays where it is")
        for name in ["pin0", "a0", "b0", "shown1"] { XCTAssertFalse(tabs[name]!.isVisible, "\(name) isn't activated") }
        XCTAssertFalse(workspaceTabIsShown(left.activeWorkspace), "The display left shows no new listed tab")
        XCTAssertEqual(listed(on: left, projectId), [])
        XCTAssertEqual(Set(Workspace.all.flatMap { $0.allLeafWindowsRecursive.map(\.windowId) }), windows, "The same windows")

        // One Undo puts it all back.
        WorkspaceSidebarTabUndo.shared.record("Move Tabs", before: before)
        XCTAssertEqual(WorkspaceSidebarTabUndo.shared.title, "Undo Move Tabs")
        try WorkspaceSidebarTabUndo.shared.undo()
        for name in ["pin0", "shown0", "a0", "b0"] { XCTAssertEqual(tabs[name]!.workspaceMonitor.rect, left.rect, name) }
        XCTAssertTrue(left.activeWorkspace === tabs["shown0"])
        XCTAssertTrue(right.activeWorkspace === tabs["shown1"])
        XCTAssertEqual(projectWorkspaces(projectId: projectId).map(\.name), orderBefore)
        XCTAssertTrue(focus.workspace === tabs["shown0"])
    }

    func testTabsThatCantMoveStayAndTheNoticeSaysWhy() async throws {
        let (monitors, tabs) = try displays(2, hidden: [0: ["a0", "b0"]])
        let (left, right) = (monitors[0], monitors[1])
        config.workspaceSidebar.sharePinnedTabs = true
        let projectId = tabs["shown0"]!.projectId
        config.workspaceToMonitorForceAssignment["a0"] = [.main]
        let fullScreen = TestWindow.new(id: 90, parent: tabs["b0"]!.macOsNativeFullscreenWindowsContainer)
        let unopened = Workspace.get(byName: "unopened")
        unopened.preferredMonitorPoint = left.rect.topLeftCorner
        try setWorkspaceSidebarTabFavorite(unopened, true)
        // The button counts what the move takes, from the sidebar's own list.
        let list = await snapshot(listing: left)
        let move = try XCTUnwrap(list.displayMove)
        XCTAssertEqual(move.targets.map(\.selection.moving), [["pin0", "shown0"]])
        XCTAssertEqual(move.help, "Move 2 Tabs to “Right”")

        let outcome = moveWorkspaceTabsToDisplay(projectId: projectId, from: scope(left), to: scope(right))
        XCTAssertEqual(outcome.moved, ["pin0", "shown0"], "pin1, shared from the other display, isn't this display's")
        XCTAssertEqual(outcome.staying.map(\.name), ["unopened", "a0", "b0"])
        XCTAssertEqual(outcome.staying.map(\.reason), [.noWindows, .kept, .fullScreen])
        XCTAssertEqual(outcome.notice, "Moved 2 tabs to “Right”. “a0” stayed: it’s kept on its display. "
            + "“b0” stayed: it’s in full screen. 1 tab with no windows to move stayed.")
        XCTAssertEqual(tabs["a0"]!.workspaceMonitor.rect, left.rect)
        XCTAssertEqual(tabs["b0"]!.workspaceMonitor.rect, left.rect)
        XCTAssertTrue(fullScreen.nodeWorkspace === tabs["b0"], "Not taken out of full screen")
        XCTAssertEqual(unopened.workspaceMonitor.rect, left.rect, "Nothing is opened for it")
        XCTAssertEqual(tabs["pin1"]!.workspaceMonitor.rect, right.rect)
        XCTAssertEqual(listed(on: left, projectId), ["a0", "b0"], "The display keeps what stayed")
    }

    func testAForegroundThatStaysKeepsBothDisplaysAsTheyWere() throws {
        let (monitors, tabs) = try displays(2, hidden: [0: ["a0"]])
        let (left, right) = (monitors[0], monitors[1])
        _ = TestWindow.new(id: 90, parent: tabs["shown0"]!.macOsNativeFullscreenWindowsContainer)
        let outcome = moveWorkspaceTabsToDisplay(projectId: tabs["shown0"]!.projectId, from: scope(left), to: scope(right))
        XCTAssertEqual(outcome.moved, ["pin0", "a0"])
        XCTAssertEqual(outcome.staying.map(\.name), ["shown0"])
        XCTAssertTrue(left.activeWorkspace === tabs["shown0"])
        XCTAssertTrue(right.activeWorkspace === tabs["shown1"], "The other display keeps its tab")
        XCTAssertTrue(focus.workspace === tabs["shown0"], "Focus stays")
        checkOnFocusChangedCallbacks()
        XCTAssertEqual(monitorHooks, [], "No display change")
    }

    /// F4: the source shows project P with G, a pin in All Projects from another project, in front;
    /// the target shows project Q. G goes on screen there in P, so P's tabs that came with it are
    /// listed with it; G keeps its own project and pin; one Undo puts both displays back.
    func testAMovedPinInAllProjectsTakesTheListsProjectToTheOtherDisplay() throws {
        let (monitors, _) = try displays(2)
        let (left, right) = (monitors[0], monitors[1])
        let home = createWorkspaceProject().id, p = createWorkspaceProject().id, q = createWorkspaceProject().id
        var windowId: UInt32 = 100
        func tab(_ name: String, in project: WorkspaceProjectId, on monitor: Monitor) -> Workspace {
            let tab = Workspace.get(byName: name)
            _ = TestWindow.new(id: windowId, parent: tab.rootTilingContainer)
            windowId += 1
            tab.assignProject(project)
            tab.preferredMonitorPoint = monitor.rect.topLeftCorner
            return tab
        }
        let g = tab("g", in: home, on: left)
        try setWorkspaceSidebarTabPinScope(g, .allProjects, projectId: home)
        let p1 = tab("p1", in: p, on: left), p2 = tab("p2", in: p, on: left)
        let q1 = tab("q1", in: q, on: right)
        XCTAssertTrue(left.setActiveWorkspace(g, contextProjectId: p))
        XCTAssertTrue(right.setActiveWorkspace(q1))
        XCTAssertTrue(g.focusWorkspace())
        checkOnFocusChangedCallbacks()
        monitorHooks = []
        XCTAssertEqual(activeWorkspaceProjectId(for: left), p)
        XCTAssertEqual(activeWorkspaceProjectId(for: right), q)
        let pins = workspacePinnedTabsInAllProjects().map(\.name)
        func viewports() -> [String] {
            winMuxWorkspaceState.monitorViewportsById.values.map {
                "\($0.id) active=\(String(describing: $0.activeWorkspaceId)) context=\(String(describing: $0.contextProjectId)) "
                    + "remembers=\($0.lastActiveWorkspaceByProject.sorted { "\($0.key)" < "\($1.key)" }.map { "\($0.key)=\($0.value)" })"
            }.sorted()
        }
        let viewportsBefore = viewports()
        let before = WorkspaceSidebarTabUndoSnapshot()

        let outcome = moveWorkspaceTabsToDisplay(projectId: p, from: scope(left), to: scope(right))
        XCTAssertEqual(Set(outcome.moved), ["g", "p1", "p2"])
        XCTAssertTrue(right.activeWorkspace === g)
        XCTAssertEqual(activeWorkspaceProjectId(for: right), p, "The other display is in the list's project")
        XCTAssertEqual(winMuxWorkspaceState.monitorViewportsById[MonitorViewportId(right)]?.lastActiveWorkspaceByProject[p], g.id)
        XCTAssertEqual(listed(on: right, p), ["p1", "p2"], "P's tabs are listed with it there")
        XCTAssertEqual(g.projectId, home, "G keeps its own project")
        XCTAssertTrue(workspaceIsPinnedInAllProjects(g))
        XCTAssertEqual(workspacePinnedTabsInAllProjects().map(\.name), pins)
        XCTAssertEqual(activeWorkspaceProjectId(for: left), p, "The display left stays in P")
        XCTAssertTrue(focus.workspace === g)
        XCTAssertEqual(q1.workspaceMonitor.rect, right.rect)

        WorkspaceSidebarTabUndo.shared.record("Move Tabs", before: before)
        try WorkspaceSidebarTabUndo.shared.undo()
        XCTAssertTrue(left.activeWorkspace === g)
        XCTAssertTrue(right.activeWorkspace === q1)
        XCTAssertEqual(activeWorkspaceProjectId(for: left), p)
        XCTAssertEqual(activeWorkspaceProjectId(for: right), q)
        XCTAssertEqual(viewports(), viewportsBefore, "Both contexts and what they remember")
        for tab in [g, p1, p2] { XCTAssertEqual(tab.workspaceMonitor.rect, left.rect, tab.name) }
        XCTAssertEqual(g.projectId, home)

        // Its foreground skipped, the other display keeps its project.
        _ = TestWindow.new(id: 200, parent: g.macOsNativeFullscreenWindowsContainer)
        let skipped = moveWorkspaceTabsToDisplay(projectId: p, from: scope(left), to: scope(right))
        XCTAssertEqual(skipped.staying.map(\.name), ["g"])
        XCTAssertTrue(right.activeWorkspace === q1)
        XCTAssertEqual(activeWorkspaceProjectId(for: right), q)
        XCTAssertEqual(activeWorkspaceProjectId(for: left), p)
    }

    func testADisplayGoneBeforeTheMoveMovesNothing() throws {
        let (monitors, tabs) = try displays(3)
        let projectId = tabs["shown0"]!.projectId
        setMonitorsForTests(Array(monitors.prefix(2)))
        let gone = moveWorkspaceTabsToDisplay(projectId: projectId, from: scope(monitors[0]), to: scope(monitors[2]))
        XCTAssertEqual(gone, .init(targetName: nil))
        XCTAssertEqual(gone.notice, "That display is no longer connected. No tabs moved.")
        let sourceGone = moveWorkspaceTabsToDisplay(projectId: projectId, from: scope(monitors[2]), to: scope(monitors[0]))
        XCTAssertTrue(sourceGone.sourceIsGone)
        XCTAssertEqual(sourceGone.moved, [])
        XCTAssertEqual(sourceGone.notice, "The tabs’ display is no longer connected. No tabs moved.")
        XCTAssertTrue(monitors[0].activeWorkspace === tabs["shown0"])
        XCTAssertTrue(monitors[1].activeWorkspace === tabs["shown1"])
        XCTAssertEqual(tabs["pin0"]!.workspaceMonitor.rect, monitors[0].rect)
        // Run again with nothing left to move, as a second click would: nothing to say.
        _ = moveWorkspaceTabsToDisplay(projectId: projectId, from: scope(monitors[0]), to: scope(monitors[1]))
        XCTAssertNil(moveWorkspaceTabsToDisplay(projectId: projectId, from: scope(monitors[0]), to: scope(monitors[1])).notice)
    }

    func testSplitsGroupsAndSharedPinsMoveWholeAndOnce() async throws {
        let (monitors, tabs) = try displays(2, hidden: [0: ["a0", "b0"]])
        let (left, right) = (monitors[0], monitors[1])
        config.workspaceSidebar.sharePinnedTabs = true
        let split = tabs["shown0"]!
        let second = TestWindow.new(id: 80, parent: split.rootTilingContainer)
        let group = try workspaceSidebarOrganizationStore.create(projectId: split.projectId, workspaceNames: [])
        try assignWorkspaceToSidebarCollection(tabs["a0"]!, collectionId: group.id)
        try assignWorkspaceToSidebarCollection(tabs["b0"]!, collectionId: group.id)
        let names = Workspace.all.map(\.name)
        let shared = await snapshot(listing: right)
        XCTAssertEqual(shared.tabsPinnedWorkspaces(for: split.projectId).map(\.name), ["pin0", "pin1"], "pin0 is shared, listed on both")

        let outcome = moveWorkspaceTabsToDisplay(projectId: split.projectId, from: scope(left), to: scope(right))
        XCTAssertEqual(outcome.moved, ["pin0", "shown0", "a0", "b0"])
        XCTAssertEqual(split.allLeafWindowsRecursive.map(\.windowId), [1, 80], "The split moved whole")
        XCTAssertTrue(second.nodeWorkspace === split)
        XCTAssertEqual(workspaceSidebarOrganizationStore.collection(containing: "a0")?.id, group.id)
        XCTAssertEqual(workspaceSidebarOrganizationStore.collection(containing: "b0")?.id, group.id)
        let after = Workspace.all.map(\.name)
        XCTAssertEqual(after.count, Set(after).count, "No tab is copied")
        XCTAssertTrue(Set(after).isSubset(of: Set(names + [left.activeWorkspace.name])), "Only the display left gets an empty one")
        XCTAssertFalse(workspaceTabIsShown(left.activeWorkspace))
        let pins = await snapshot(listing: right).tabsPinnedWorkspaces(for: split.projectId).map(\.name)
        XCTAssertEqual(pins, ["pin0", "pin1"], "Listed once, in its place")
    }

    func testTheButtonShowsForOneDisplaysListWithAnotherConnected() async throws {
        let (single, _) = try displays(1)
        let alone = await snapshot(listing: single[0])
        XCTAssertNil(alone.displayMove, "One display")

        let (monitors, tabs) = try displays(3, hidden: [0: ["a0"]])
        var list = await snapshot(listing: monitors[0])
        let move = try XCTUnwrap(list.displayMove)
        XCTAssertEqual(move.source, scope(monitors[0]))
        XCTAssertEqual(move.targets.map(\.displayName), ["Right", "Far"], "Every other display, every time")
        XCTAssertEqual(move.targets.map(\.count), [3, 3])
        XCTAssertEqual(move.help, "Move Tabs to Another Display")
        XCTAssertEqual(move.targets.map(\.title), ["Move 3 Tabs to “Right”", "Move 3 Tabs to “Far”"])
        // What it counts is what the move takes.
        let plan = workspaceSidebarDisplayMovePlan(projectId: tabs["shown0"]!.projectId, source: monitors[0], target: monitors[1])
        XCTAssertEqual(Set(move.targets[0].selection.moving), Set(plan.tabs.map(\.name)))

        // Another display's list, shown on this one, moves that display's tabs.
        let other = await snapshot(listing: monitors[1], on: monitors[0])
        XCTAssertEqual(other.displayMove?.source, scope(monitors[1]))
        XCTAssertEqual(other.displayMove?.targets.map(\.displayName), ["Left", "Far"])

        // On screen here but held to one display, a tab counts only for that one. (A hidden one
        // held elsewhere is listed there already.)
        config.workspaceToMonitorForceAssignment["shown0"] = [.sequenceNumber(3)]
        list = await snapshot(listing: monitors[0])
        XCTAssertEqual(list.displayMove?.targets.map(\.count), [2, 3])
        XCTAssertEqual(workspaceSidebarDisplayMovePlan(projectId: tabs["shown0"]!.projectId, source: monitors[0],
            target: monitors[1]).staying.map(\.name), ["shown0"])

        for scopeId in [workspaceSidebarDefaultScopeId, workspaceSidebarFocusedScopeId] {
            list.selectedMonitorScopeId = scopeId
            XCTAssertNil(list.displayMove, "\(scopeId): no one display's list")
        }
        var empty = await snapshot(listing: monitors[2])
        empty.workspaces = empty.workspaces.filter { $0.monitorScopeId != scope(monitors[2]) || $0.appearance.isFavorite }
        empty.workspaces = empty.workspaces.map { var tab = $0; tab.displayMoveBlock = .noWindows; return tab }
        XCTAssertEqual(empty.displayMove?.isEnabled, false)
        XCTAssertEqual(empty.displayMove?.help, "No tabs to move to another display")
    }

    func testTheNoticeNamesWhatStayedAndWhy() {
        func stays(_ names: [String], _ reason: WorkspaceSidebarTabStays) -> [WorkspaceSidebarStayingTab] {
            names.map { .init(name: $0, displayName: $0, reason: reason) }
        }
        var outcome = WorkspaceSidebarDisplayMoveOutcome(targetName: "Right", moved: ["a"])
        XCTAssertEqual(outcome.notice, "Moved 1 tab to “Right”.")
        outcome.moved = []
        outcome.staying = stays(["A", "B", "C", "D"], .kept) + stays(["E"], .failed) + stays(["F", "G"], .noWindows)
        XCTAssertEqual(outcome.notice, "No tabs moved to “Right”. “A”, “B” and 2 more stayed: they’re kept on their displays. "
            + "“E” couldn’t be moved. 2 tabs with no windows to move stayed.")
        outcome = .init(targetName: "Right", moved: ["a", "b"], stoppedEarly: true)
        XCTAssertEqual(outcome.notice, "Moved 2 tabs to “Right”. A display was disconnected, so the other tabs stayed.")
        XCTAssertEqual(workspaceSidebarNoticeNameList(["A", "B", "C"]), "“A”, “B” and “C”")
    }

    /// F1: only the very change an action made keeps the pointer: not a change before it's seen,
    /// not the next one, not one an action noted without moving focus to another display.
    func testOnlyTheActionsOwnFocusChangeKeepsThePointer() throws {
        let (_, tabs) = try displays(2)
        XCTAssertTrue(tabs["shown1"]!.focusWorkspace())
        noteFocusKeepsPointer()
        checkOnFocusChangedCallbacks()
        XCTAssertEqual(monitorHooks, [.init("shown1", keepsPointer: true)])
        XCTAssertTrue(tabs["shown0"]!.focusWorkspace())
        checkOnFocusChangedCallbacks()
        XCTAssertEqual(monitorHooks.last, .init("shown0", keepsPointer: false), "The next change, as always")

        // Noted, then focus goes elsewhere before it's seen: that other change is as always.
        monitorHooks = []
        XCTAssertTrue(tabs["shown1"]!.focusWorkspace())
        noteFocusKeepsPointer()
        XCTAssertTrue(tabs["pin0"]!.focusWorkspace())
        checkOnFocusChangedCallbacks()
        XCTAssertEqual(monitorHooks, [], "Back on the same display: no change")
        XCTAssertTrue(tabs["shown1"]!.focusWorkspace())
        checkOnFocusChangedCallbacks()
        XCTAssertEqual(monitorHooks, [.init("shown1", keepsPointer: false)], "Not kept for a later change")

        // Noted without a display change: nothing is kept for the next one.
        monitorHooks = []
        noteFocusKeepsPointer()
        checkOnFocusChangedCallbacks()
        XCTAssertTrue(tabs["shown0"]!.focusWorkspace())
        checkOnFocusChangedCallbacks()
        XCTAssertEqual(monitorHooks, [.init("shown0", keepsPointer: false)])
    }

    /// F1, through the production hook runner with real commands: for the action's change the
    /// non-pointer hook still runs and only `move-mouse` leaves the pointer; the next change moves it.
    /// The sidebar is off here, so the sessions refresh no panel; the pointer move is injected.
    func testTheMonitorHooksStillRunAndOnlyTheirPointerMoveIsSkipped() async throws {
        let (monitors, tabs) = try displays(2)
        let parsed = parseConfig("""
            on-focused-monitor-changed = ['move-mouse monitor-force-center', 'mode probe']
            [mode.main.binding]
            [mode.probe.binding]
            """)
        XCTAssertEqual(parsed.errors.descriptions, [])
        config.onFocusedMonitorChanged = parsed.config.onFocusedMonitorChanged
        config.modes["probe"] = parsed.config.modes["probe"]
        config.workspaceSidebar.enabled = false
        TrayMenuModel.shared.isEnabled = true
        saved.restoreMonitorCommands()
        var moves: [CGPoint] = []
        postMoveMouseEvent = { moves.append($0); return true }

        XCTAssertTrue(tabs["shown1"]!.focusWorkspace())
        noteFocusKeepsPointer()
        checkOnFocusChangedCallbacks()
        try await waitUntil { activeMode == "probe" }
        XCTAssertEqual(moves, [], "The pointer stays; the other hook ran")

        try await activateMode(mainModeId)
        XCTAssertTrue(tabs["shown0"]!.focusWorkspace())
        checkOnFocusChangedCallbacks()
        try await waitUntil { activeMode == "probe" }
        XCTAssertEqual(moves, [monitors[0].rect.center], "The next change moves it, as always")
    }

    // MARK: Clicking a pin from another display

    func testAPlainClickShowsARemotePinOnItsOwnDisplayByDefault() throws {
        XCTAssertEqual(defaultConfig.workspaceSidebar.remotePinClick, .showOnItsDisplay)
        XCTAssertEqual(WorkspaceSidebarConfig().remotePinClick, .showOnItsDisplay, "An absent setting is the new default")
        let (monitors, tabs) = try sharedPins(2)
        let (left, right) = (monitors[0], monitors[1])
        let pin = tabs["pin1"]!
        XCTAssertEqual(workspaceSidebarSharedPinClickPlan(pin, targetMonitorScopeId: scope(left), click: .plain),
            .showThere(monitorScopeId: scope(right)))
        XCTAssertTrue(try performSharedPinClick(pin, windowId: nil, targetMonitorScopeId: scope(left), click: .plain))
        XCTAssertTrue(right.activeWorkspace === pin, "Shown on its own display")
        XCTAssertTrue(left.activeWorkspace === tabs["shown0"], "Nothing comes to the display clicked")
        XCTAssertEqual(pin.preferredMonitorPoint, right.rect.topLeftCorner, "It keeps its display")
        XCTAssertTrue(focus.workspace === pin, "Focus stays there")

        // On screen there, with a window clicked: that window, there.
        let shown = tabs["shown1"]!
        try setWorkspaceSidebarTabFavorite(shown, true)
        XCTAssertTrue(right.setActiveWorkspace(shown))
        let window = try XCTUnwrap(shown.anyLeafWindowRecursive)
        XCTAssertTrue(workspaceSidebarSharedPinClicked(windowId: window.windowId, targetMonitorScopeId: scope(left)) === shown)
        XCTAssertTrue(try performSharedPinClick(shown, windowId: window.windowId, targetMonitorScopeId: scope(left), click: .plain))
        XCTAssertTrue(right.activeWorkspace === shown)
        XCTAssertTrue(focus.windowOrNil === window)
        XCTAssertTrue(left.activeWorkspace === tabs["shown0"])
    }

    func testCommandClickBringsTheSamePinHereWhateverTheSetting() throws {
        for setting in WorkspaceSidebarRemotePinClick.allCases {
            let (monitors, tabs) = try sharedPins(2)
            config.workspaceSidebar.remotePinClick = setting
            let (left, right) = (monitors[0], monitors[1])
            let pin = tabs["pin1"]!
            let windows = pin.allLeafWindowsRecursive.map(\.windowId)
            XCTAssertEqual(workspaceSidebarSharedPinClickPlan(pin, targetMonitorScopeId: scope(left), click: .command),
                .bringHere(monitorScopeId: scope(left)), "\(setting)")
            XCTAssertTrue(try performSharedPinClick(pin, windowId: nil, targetMonitorScopeId: scope(left), click: .command))
            XCTAssertTrue(left.activeWorkspace === pin, "\(setting): here")
            XCTAssertTrue(right.activeWorkspace === tabs["shown1"])
            XCTAssertEqual(pin.preferredMonitorPoint, left.rect.topLeftCorner, "Its new display is recorded")
            XCTAssertEqual(pin.allLeafWindowsRecursive.map(\.windowId), windows, "The same windows, none reopened")
            XCTAssertEqual(Workspace.all.filter { $0.name == pin.name }.count, 1)
            XCTAssertEqual(pin.workspaceMonitor.rect, focus.workspace.workspaceMonitor.rect)
            checkOnFocusChangedCallbacks()
            XCTAssertEqual(monitorHooks, [], "Focus stays on this display")
        }
    }

    func testTheOtherSettingBringsItOnAPlainClick() throws {
        let (monitors, tabs) = try sharedPins(3)
        config.workspaceSidebar.remotePinClick = .bringToThisDisplay
        let pin = tabs["pin2"]!
        XCTAssertEqual(workspaceSidebarSharedPinClickPlan(pin, targetMonitorScopeId: scope(monitors[0]), click: .plain),
            .bringHere(monitorScopeId: scope(monitors[0])))
        XCTAssertTrue(try performSharedPinClick(pin, windowId: nil, targetMonitorScopeId: scope(monitors[0]), click: .plain))
        XCTAssertTrue(monitors[0].activeWorkspace === pin)
    }

    /// F2: a pin that can't come is shown on its display by the default plain click; asked to come,
    /// by ⌘-click or by `bring-to-this-display`, it stays, says why, and nothing else is focused.
    func testAPinThatCantComeIsShownThereOrRefusedWhenAskedToCome() throws {
        for setting in WorkspaceSidebarRemotePinClick.allCases {
            for click in [WorkspaceSidebarSharedPinClick.plain, .command] {
                let (monitors, tabs) = try sharedPins(2)
                config.workspaceSidebar.remotePinClick = setting
                let (left, right) = (monitors[0], monitors[1])
                let held = tabs["shown1"]!
                try setWorkspaceSidebarTabFavorite(held, true)
                config.workspaceToMonitorForceAssignment[held.name] = [.secondary]
                _ = TestWindow.new(id: 90, parent: tabs["pin1"]!.macOsNativeFullscreenWindowsContainer)
                let asked = click == .command || setting == .bringToThisDisplay
                let name = "\(setting), \(click)"
                for (pin, refusal) in [
                    (held, "“shown1” is kept on “Right”, so it stays there."),
                    (tabs["pin1"]!, "“pin1” is in full screen on “Right”, so it stays there. Exit full screen to move it."),
                ] {
                    XCTAssertNil(workspaceSidebarSharedPinClickDestination(pin, targetMonitorScopeId: scope(left)))
                    let plan = workspaceSidebarSharedPinClickPlan(pin, targetMonitorScopeId: scope(left), click: click)
                    XCTAssertEqual(plan, asked ? .refused(message: refusal) : .showThere(monitorScopeId: scope(right)), name)
                    guard asked else { continue }
                    notices = []
                    XCTAssertFalse(try performSharedPinClick(pin, windowId: nil, targetMonitorScopeId: scope(left), click: click))
                    XCTAssertEqual(notices, [.init(title: "Pinned Tab", body: refusal, monitorScopeId: scope(left))], name)
                    XCTAssertTrue(right.activeWorkspace === held, "\(name): nothing moved")
                    XCTAssertEqual(pin.workspaceMonitor.rect, right.rect)
                    XCTAssertTrue(left.activeWorkspace === tabs["shown0"])
                    XCTAssertTrue(focus.workspace === tabs["shown0"], "\(name): nor is it focused there instead")
                }
                checkOnFocusChangedCallbacks()
                XCTAssertEqual(monitorHooks, [], name)
            }
        }
    }

    /// F2: the browser row of a pin that can't come, asked to come by the setting, chooses nothing,
    /// anywhere, and says why; by default it's chosen where it is, the pointer kept.
    func testABrowserTabOfAPinThatCantComeIsNotChosenWhenAskedToCome() throws {
        for setting in WorkspaceSidebarRemotePinClick.allCases {
            let (monitors, tabs) = try sharedPins(2)
            config.workspaceSidebar.remotePinClick = setting
            let held = tabs["shown1"]!
            try setWorkspaceSidebarTabFavorite(held, true)
            config.workspaceToMonitorForceAssignment[held.name] = [.secondary]
            let target = try browserTab(in: held)
            selections = []
            notices = []
            // Browser tabs are chosen only with WinMux on; neither route here starts a session.
            TrayMenuModel.shared.isEnabled = true
            defer { TrayMenuModel.shared.isEnabled = false }
            handleWorkspaceSidebarAction(.selectBrowserTab(target), targetMonitorScopeId: scope(monitors[0]))
            if setting == .showOnItsDisplay {
                XCTAssertEqual(selections, [.init(target, scope(monitors[1]), keepsPointer: true)])
                XCTAssertEqual(notices, [])
            } else {
                XCTAssertEqual(selections, [], "Not chosen anywhere")
                XCTAssertEqual(notices.map(\.body), ["“shown1” is kept on “Right”, so it stays there."])
            }
            XCTAssertTrue(monitors[1].activeWorkspace === held)
            XCTAssertTrue(monitors[0].activeWorkspace === tabs["shown0"])
        }
    }

    /// F1: showing a pin on its own display, and bringing one to a display other than the focused
    /// one, keep the pointer for that change only; a refused or failed click keeps nothing.
    func testShowingOrBringingAPinKeepsThePointerForItsOwnChangeOnly() throws {
        let (monitors, tabs) = try sharedPins(3)
        XCTAssertTrue(try performSharedPinClick(tabs["pin1"]!, windowId: nil, targetMonitorScopeId: scope(monitors[0]), click: .plain))
        checkOnFocusChangedCallbacks()
        XCTAssertEqual(monitorHooks, [.init("pin1", keepsPointer: true)], "Shown on Right, from Left")

        // Focus on Far; a pin of Right brought to Left, whose sidebar was clicked.
        XCTAssertTrue(tabs["shown2"]!.focusWorkspace())
        checkOnFocusChangedCallbacks()
        monitorHooks = []
        XCTAssertTrue(try performSharedPinClick(tabs["pin2"]!, windowId: nil, targetMonitorScopeId: scope(monitors[0]), click: .command))
        XCTAssertTrue(monitors[0].activeWorkspace === tabs["pin2"])
        checkOnFocusChangedCallbacks()
        XCTAssertEqual(monitorHooks, [.init("pin2", keepsPointer: true)], "Brought to Left, from Far")

        // A click whose display has gone, and a refused one: nothing kept for the next change.
        monitorHooks = []
        XCTAssertFalse(try performSharedPinClick(tabs["pin1"]!, windowId: nil, targetMonitorScopeId: scope(monitors[0]),
            click: .plain, remoteScopeId: .some("monitor:99999,0")))
        config.workspaceToMonitorForceAssignment["pin1"] = [.sequenceNumber(2)]
        XCTAssertFalse(try performSharedPinClick(tabs["pin1"]!, windowId: nil, targetMonitorScopeId: scope(monitors[0]), click: .command))
        XCTAssertEqual(notices.map(\.body), ["“pin1” is kept on “Right”, so it stays there."])
        XCTAssertTrue(tabs["shown2"]!.focusWorkspace())
        checkOnFocusChangedCallbacks()
        XCTAssertEqual(monitorHooks, [.init("shown2", keepsPointer: false)])
    }

    /// F1: a browser tab of a pin shown on its own display is chosen asking to keep the pointer, and
    /// the deferred focus of its window, once chosen, keeps it; a window gone by then keeps nothing.
    func testTheDeferredFocusOfAChosenBrowserTabKeepsThePointer() throws {
        let (monitors, tabs) = try sharedPins(2)
        let shown = tabs["shown1"]!
        try setWorkspaceSidebarTabFavorite(shown, true)
        let target = try browserTab(in: shown)
        // Browser tabs are chosen only with WinMux on; this route starts no session.
        TrayMenuModel.shared.isEnabled = true
        handleWorkspaceSidebarAction(.selectBrowserTab(target), targetMonitorScopeId: scope(monitors[0]))
        TrayMenuModel.shared.isEnabled = false
        XCTAssertEqual(selections, [.init(target, scope(monitors[1]), keepsPointer: true)])
        // What the browser model's select does once the tab is chosen.
        focusWindowFromSidebarNow(target.windowId, targetMonitorScopeId: scope(monitors[1]), keepsPointer: true)
        checkOnFocusChangedCallbacks()
        XCTAssertEqual(monitorHooks, [.init("shown1", keepsPointer: true)])
        // Stale by then: nothing kept.
        monitorHooks = []
        focusWindowFromSidebarNow(99_999, targetMonitorScopeId: scope(monitors[0]), keepsPointer: true)
        XCTAssertTrue(tabs["shown0"]!.focusWorkspace())
        checkOnFocusChangedCallbacks()
        XCTAssertEqual(monitorHooks, [.init("shown0", keepsPointer: false)])
    }

    func testLocalAndUnopenedPinsAreAsBefore() throws {
        let (monitors, tabs) = try sharedPins(2)
        let (left, right) = (monitors[0], monitors[1])
        for click in [WorkspaceSidebarSharedPinClick.plain, .command] {
            XCTAssertEqual(workspaceSidebarSharedPinClickPlan(tabs["pin0"]!, targetMonitorScopeId: scope(left), click: click), .here)
        }
        // A pin that isn't open anywhere yet comes to the display clicked, as before.
        let unopened = Workspace.get(byName: "unopened")
        unopened.preferredMonitorPoint = right.rect.topLeftCorner
        try setWorkspaceSidebarTabFavorite(unopened, true)
        XCTAssertNil(workspaceSidebarSharedPinRemoteScopeId(unopened, targetMonitorScopeId: scope(left)))
        XCTAssertEqual(workspaceSidebarSharedPinClickPlan(unopened, targetMonitorScopeId: scope(left), click: .plain),
            .bringHere(monitorScopeId: scope(left)))
        // Without sharing, no pin is another display's.
        config.workspaceSidebar.sharePinnedTabs = false
        XCTAssertNil(workspaceSidebarSharedPinRemoteScopeId(tabs["pin1"]!, targetMonitorScopeId: scope(left)))
        XCTAssertNil(workspaceSidebarSharedPinClicked("pin1", targetMonitorScopeId: scope(left)))
    }

    /// What a click treats as another display's pin is what has the badge saying so.
    func testAClickTreatsAPinAsAnotherDisplaysExactlyWhenItsBadgeSaysSo() async throws {
        let (monitors, tabs) = try sharedPins(2)
        let (left, right) = (monitors[0], monitors[1])
        func pin(_ name: String, _ windows: (Workspace) -> Void) throws {
            let tab = Workspace.get(byName: name)
            tab.preferredMonitorPoint = right.rect.topLeftCorner
            windows(tab)
            try setWorkspaceSidebarTabFavorite(tab, true)
        }
        try pin("appHidden") { _ = TestWindow.new(id: 70, parent: $0.macOsNativeHiddenAppsWindowsContainer) }
        try pin("fullScreenOnly") { _ = TestWindow.new(id: 71, parent: $0.macOsNativeFullscreenWindowsContainer) }
        try pin("unopened") { _ in }
        let list = await snapshot(listing: left)
        var badged: [String] = []
        for name in ["pin0", "pin1", "appHidden", "fullScreenOnly", "unopened"] {
            let vm = try XCTUnwrap(list.workspaces.first { $0.name == name }, name)
            let remote = workspaceSidebarSharedPinRemoteScopeId(Workspace.existing(byName: name)!, targetMonitorScopeId: scope(left))
            XCTAssertEqual(remote != nil, list.sharedPinLocation(of: vm) != nil, name)
            if remote != nil { badged.append(name) }
        }
        XCTAssertEqual(badged, ["pin1", "fullScreenOnly"])
        XCTAssertEqual(workspaceSidebarSharedPinClickPlan(Workspace.existing(byName: "fullScreenOnly")!,
            targetMonitorScopeId: scope(left), click: .plain), .showThere(monitorScopeId: scope(right)), "Never brought out of full screen")
        XCTAssertTrue(tabs["pin1"]!.workspaceMonitor.rect == right.rect)
    }

    /// A click that first brings back windows a pin lent decides where the pin is before they come.
    func testWhereAPinIsCanBeDecidedBeforeItsWindowsComeBack() throws {
        let (monitors, tabs) = try sharedPins(2)
        let pin = tabs["pin1"]!
        XCTAssertEqual(workspaceSidebarSharedPinClickPlan(pin, targetMonitorScopeId: scope(monitors[0]), click: .plain,
            remoteScopeId: .some(nil)), .bringHere(monitorScopeId: scope(monitors[0])), "No badge before: brought, as before")
        XCTAssertEqual(workspaceSidebarSharedPinClickPlan(pin, targetMonitorScopeId: scope(monitors[0]), click: .plain,
            remoteScopeId: .some(scope(monitors[1]))), .showThere(monitorScopeId: scope(monitors[1])))
    }

    func testCommandClickOnARemotePinBringsItAndOtherwiseSelectsAsBefore() throws {
        _ = try sharedPins(2)
        var sent: [WorkspaceSidebarAction] = []
        let send: @MainActor (WorkspaceSidebarAction) -> Void = { sent.append($0) }
        func activation(remote: Bool, activates: Bool = true) -> WorkspaceSidebarTabActivation {
            WorkspaceSidebarTabActivation(allowsActivation: activates, isInUseOnOtherDisplay: false, requestOverride: {},
                tabName: "pin1", selectionContext: { (["pin0", "pin1", "shown0"], "shown0") }, isRemotePin: remote)
        }
        let target = BrowserTabTarget(windowId: 4, pid: 1, windowSession: UUID(), tabId: UUID())
        let cases: [(WorkspaceSidebarAction, WorkspaceSidebarAction)] = [
            (.selectWorkspace("pin1"), .bringPinnedTabHere("pin1", windowId: nil, recalls: false)),
            (.selectWindow(4), .bringPinnedTabHere("pin1", windowId: 4, recalls: false)),
            (.selectBrowserTab(target), .bringBrowserTabHere("pin1", target)),
            (.recallPinWindows("pin1", focusing: 4), .bringPinnedTabHere("pin1", windowId: 4, recalls: true)),
        ]
        for (action, bring) in cases {
            sent = []
            activation(remote: true).select(action, modifiers: .command, send: send)
            XCTAssertEqual(sent, [bring])
            XCTAssertEqual(WorkspaceSidebarTabSelection.shared.names, [], "Not added to a selection")
        }
        sent = []
        activation(remote: true).select(.selectWorkspace("pin1"), modifiers: [], send: send)
        XCTAssertEqual(sent, [.selectWorkspace("pin1")], "A plain click goes as before")
        sent = []
        activation(remote: true).select(.selectWorkspace("pin1"), modifiers: [.command, .shift], send: send)
        XCTAssertEqual(sent, [], "Shift still chooses a range")
        XCTAssertEqual(WorkspaceSidebarTabSelection.shared.names, ["pin1", "shown0"])
        WorkspaceSidebarTabSelection.shared.clear()
        activation(remote: false).select(.selectWorkspace("pin1"), modifiers: .command, send: send)
        XCTAssertEqual(sent, [], "A pin on this display is chosen with ⌘, as before")
        XCTAssertEqual(WorkspaceSidebarTabSelection.shared.names, ["pin1", "shown0"])
        WorkspaceSidebarTabSelection.shared.clear()
        activation(remote: true, activates: false).select(.selectWorkspace("pin1"), modifiers: .command, send: send)
        XCTAssertEqual(sent, [], "Where rows don't activate, ⌘ only chooses")
        XCTAssertEqual(WorkspaceSidebarTabSelection.shared.names, ["pin1", "shown0"])
    }

    func testTheSidebarAsksAndExplainsAsTheSettingSays() async throws {
        let (monitors, tabs) = try sharedPins(2)
        let held = tabs["shown1"]!
        try setWorkspaceSidebarTabFavorite(held, true)
        config.workspaceToMonitorForceAssignment[held.name] = [.secondary]
        for (setting, heldHelp, pinHelp) in [
            (WorkspaceSidebarRemotePinClick.showOnItsDisplay,
             "On “Right” · Click to show it there · Kept on that display, so it can’t move here",
             "Assigned to “Right” · Click to show it there · ⌘-click to move it here"),
            (.bringToThisDisplay, "On “Right” · Kept on that display, so it can’t move here",
             "Assigned to “Right” · Click to move to this display"),
        ] {
            config.workspaceSidebar.remotePinClick = setting
            let list = await snapshot(listing: monitors[0])
            let view = WorkspaceSidebarView(snapshot: list)
            let heldTab = try XCTUnwrap(list.workspaces.first { $0.name == held.name })
            let (activation, _) = view.tabActivation(heldTab, isPinned: false, pageAllowsActivation: true)
            XCTAssertTrue(activation.isRemotePin)
            XCTAssertFalse(activation.isInUseOnOtherDisplay, "\(setting): no In Use prompt; the click shows, brings or says why")
            XCTAssertEqual(list.sharedPinLocation(of: heldTab)?.help(), heldHelp)
            let pin = try XCTUnwrap(list.workspaces.first { $0.name == "pin1" })
            XCTAssertEqual(list.sharedPinLocation(of: pin)?.help(), pinHelp)
            XCTAssertEqual(list.sharedPinLocation(of: pin)?.help(clickMovesHere: false), "Assigned to “Right”")
            let local = try XCTUnwrap(list.workspaces.first { $0.name == "pin0" })
            XCTAssertFalse(view.tabActivation(local, isPinned: false, pageAllowsActivation: true).0.isRemotePin)
        }
    }

    func testTheSettingParsesDefaultsAndIsATabsSetting() {
        for value in WorkspaceSidebarRemotePinClick.allCases {
            let (parsed, errors) = parseConfig("[workspace-sidebar]\nmode = 'tabs'\nremote-pin-click = '\(value.rawValue)'\n")
            XCTAssertEqual(errors.descriptions, [])
            XCTAssertEqual(parsed.workspaceSidebar.remotePinClick, value)
            XCTAssertEqual(workspaceSidebarConfiguration(parsed).remotePinClick, value)
        }
        XCTAssertEqual(parseConfig("[workspace-sidebar]\nmode = 'tabs'\n").config.workspaceSidebar.remotePinClick,
            .showOnItsDisplay, "Absent, the default")
        XCTAssertFalse(parseConfig("[workspace-sidebar]\nremote-pin-click = 'teleport'\n").errors.isEmpty)

        let field = SettingsCatalog.field("workspace-sidebar.remote-pin-click")
        XCTAssertEqual(field.modes, [.tabs])
        let content = SettingsPanelLayout.sections(.tabs).first { $0.id == SettingsPanelLayout.tabsContentSection }
        XCTAssertEqual(content?.fields.prefix(2), ["workspace-sidebar.share-pinned-tabs", field.id])
        var configuration = defaultConfig
        field.project?(&configuration, .text("bring-to-this-display"))
        XCTAssertEqual(configuration.workspaceSidebar.remotePinClick, .bringToThisDisplay)
        let text = updateSettingsScalarConfig(in: "[workspace-sidebar]\nmode = 'tabs'\n", section: "workspace-sidebar",
            key: "remote-pin-click", renderedValue: "'bring-to-this-display'")
        XCTAssertEqual(parseConfig(text).config.workspaceSidebar.remotePinClick, .bringToThisDisplay, text)
    }

    // MARK: The footer, rendered in a window-less view

    func testTheFooterButtonRendersWithTwoAndThreeDisplays() async throws {
        _ = NSApplication.shared
        var renders: [String: Data] = [:]
        for count in [1, 2, 3] {
            let (monitors, _) = try displays(count, hidden: [0: ["a0"]])
            var list = await snapshot(listing: monitors[0])
            list.visibleWidth = 300
            list.configuration.expandedWidth = 300
            list.configuration.alwaysExpanded = true
            renders["\(count)"] = try render(list, name: "footer-\(count)-displays")
        }
        XCTAssertNotEqual(renders["2"], renders["1"], "The button draws in the footer")
        XCTAssertNotEqual(renders["3"], renders["1"])
    }

    // MARK: Fixtures

    private func displays(_ count: Int, hidden: [Int: [String]] = [:]) throws -> ([Monitor], [String: Workspace]) {
        let result = try multidisplayFixture(count, hidden: hidden)
        monitorHooks = []
        return result
    }

    private func sharedPins(_ count: Int) throws -> ([Monitor], [String: Workspace]) {
        let result = try displays(count)
        config.workspaceSidebar.sharePinnedTabs = true
        return result
    }

    private func listed(on monitor: Monitor, _ projectId: WorkspaceProjectId) -> [String] {
        multidisplayListed(on: monitor, projectId)
    }

    private func snapshot(listing monitor: Monitor, on panel: Monitor? = nil) async -> WorkspaceSidebarSnapshot {
        await multidisplaySnapshot(listing: monitor, on: panel)
    }

    private func scope(_ monitor: Monitor) -> String { workspaceSidebarMonitorScopeId(for: monitor) }

    private func browserTab(in tab: Workspace) throws -> BrowserTabTarget {
        let window = try XCTUnwrap(tab.anyLeafWindowRecursive)
        return BrowserTabTarget(windowId: window.windowId, pid: window.app.pid, windowSession: UUID(), tabId: UUID())
    }

    private func waitUntil(_ condition: () -> Bool, timeout: Duration = .seconds(3)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The bottom of the sidebar, drawn in a view with no window; a PNG too when WINMUX_RENDER_DIR is set.
    private func render(_ snapshot: WorkspaceSidebarSnapshot, name: String) throws -> Data {
        let height: CGFloat = 640
        let view = WorkspaceSidebarView(snapshot: snapshot, reduceMotionOverride: true, reduceTransparencyOverride: true,
            browserTabsModel: BrowserTabsModel(snapshots: [:]))
        let host = NSHostingView(rootView: view.frame(width: 300, height: height).transaction { $0.animation = nil })
        host.frame = CGRect(x: 0, y: 0, width: 300, height: height)
        host.appearance = NSAppearance(named: .aqua)
        XCTAssertNil(host.window)
        for _ in 0 ..< 4 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        let footer = CGRect(x: 0, y: host.isFlipped ? height - 56 : 0, width: 300, height: 56)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: footer))
        host.cacheDisplay(in: footer, to: bitmap)
        if let dir = ProcessInfo.processInfo.environment["WINMUX_RENDER_DIR"] {
            let full = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: full)
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try XCTUnwrap(full.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}

/// The same clicks through the sidebar's real routes: the tab's activation, the action handler and
/// the WinMux session it runs. Sessions refresh the sidebar, so blank synthetic test panels may
/// show briefly; no real browser, pointer move or notice is involved, and all are hidden after.
@MainActor
final class WorkspaceSidebarRemotePinRoutingTest: XCTestCase {
    private var wasEnabled = true
    private var notices: [WinMuxToastNotice] = []
    private var monitorHooks: [MonitorHook] = []
    private var selections: [BrowserTabSelection] = []
    private var listedTabs: Set<BrowserTabTarget>? = nil
    private let saved = MultidisplaySeams()

    override func setUp() async throws {
        setUpWorkspacesForTests()
        workspaceSidebarOrganizationStore = .init()
        wasEnabled = TrayMenuModel.shared.isEnabled
        TrayMenuModel.shared.isEnabled = true
        notices = []
        monitorHooks = []
        selections = []
        listedTabs = nil
        showWorkspaceSidebarNotice = { [unowned self] in notices.append($0) }
        runFocusedMonitorChangedCommands = { [unowned self] focus, keepsPointer in
            monitorHooks.append(.init(focus.workspace.name, keepsPointer: keepsPointer))
        }
        postMoveMouseEvent = { _ in XCTFail("No real pointer move"); return false }
        selectWorkspaceSidebarBrowserTab = { [unowned self] in selections.append(.init($0, $1, keepsPointer: $2)) }
        workspaceSidebarBrowserTabIsListed = { [unowned self] in listedTabs?.contains($0) ?? true }
        WorkspaceSidebarTabSelection.shared.clear()
    }

    override func tearDown() async throws {
        try await Task.sleep(for: .milliseconds(100))
        saved.restore()
        // Hide any test panel the sessions framed.
        config.workspaceSidebar.enabled = false
        WorkspaceSidebarPanel.refreshAll()
        WorkspaceSidebarTabSelection.shared.clear()
        WorkspaceSidebarTabUndo.shared.clear()
        workspaceSidebarOrganizationStore = .init()
        setMonitorsForTests(nil)
        config = defaultConfig
        TrayMenuModel.shared.isEnabled = wasEnabled
        try await super.tearDown()
    }

    /// F2: from the tab's own activation, under both settings, with a plain click and ⌘: a held pin
    /// hidden there, a held pin on screen there (which used to ask In Use), and one in full screen.
    /// Asked to come, each stays, nothing is focused instead, and the notice says why; by default
    /// a plain click shows it there, keeping the pointer.
    func testEveryRouteRefusesAPinThatCantComeWhenAskedAndShowsItThereByDefault() async throws {
        let cases: [(name: String, pin: String, why: String, setUp: @MainActor ([String: Workspace]) throws -> Void)] = [
            ("hidden, held", "pin1", "“pin1” is kept on “Right”, so it stays there.", { _ in
                config.workspaceToMonitorForceAssignment["pin1"] = [.secondary]
            }),
            ("on screen, held", "shown1", "“shown1” is kept on “Right”, so it stays there.", { tabs in
                try setWorkspaceSidebarTabFavorite(tabs["shown1"]!, true)
                config.workspaceToMonitorForceAssignment["shown1"] = [.secondary]
            }),
            ("full screen", "pin1", "“pin1” is in full screen on “Right”, so it stays there. Exit full screen to move it.", { tabs in
                _ = TestWindow.new(id: 90, parent: tabs["pin1"]!.macOsNativeFullscreenWindowsContainer)
            }),
        ]
        for (name, pinName, why, setUpCase) in cases {
            for setting in WorkspaceSidebarRemotePinClick.allCases {
                for modifiers in [NSEvent.ModifierFlags(), .command] {
                    let label = "\(name), \(setting), \(modifiers.contains(.command) ? "⌘" : "plain")"
                    let (monitors, tabs) = try multidisplayFixture(2)
                    config.workspaceSidebar.sharePinnedTabs = true
                    config.workspaceSidebar.remotePinClick = setting
                    try setUpCase(tabs)
                    let (left, right) = (monitors[0], monitors[1])
                    let pin = tabs[pinName]!
                    let rightBefore = right.activeWorkspace
                    notices = []
                    monitorHooks = []
                    let activation = try await click(pinName, .selectWorkspace(pinName), modifiers, on: left)
                    XCTAssertFalse(activation.isInUseOnOtherDisplay, "\(label): no In Use prompt")
                    if modifiers.contains(.command) || setting == .bringToThisDisplay {
                        try await waitUntil { !notices.isEmpty }
                        try await Task.sleep(for: .milliseconds(150))
                        XCTAssertEqual(notices, [.init(title: "Pinned Tab", body: why, monitorScopeId: scope(left))], label)
                        XCTAssertEqual(pin.workspaceMonitor.rect, right.rect, label)
                        XCTAssertTrue(right.activeWorkspace === rightBefore, label)
                        XCTAssertTrue(left.activeWorkspace === tabs["shown0"], label)
                        XCTAssertTrue(focus.workspace === tabs["shown0"], "\(label): nothing focused instead")
                        XCTAssertEqual(monitorHooks, [], label)
                    } else {
                        try await waitUntil { focus.workspace === pin && !monitorHooks.isEmpty }
                        XCTAssertTrue(right.activeWorkspace === pin, label)
                        XCTAssertTrue(left.activeWorkspace === tabs["shown0"], label)
                        XCTAssertEqual(monitorHooks, [.init(pinName, keepsPointer: true)], label)
                        XCTAssertEqual(notices, [], label)
                    }
                }
            }
        }
    }

    /// F2: an In Use prompt answered for a shared pin from another display asks it to come, as ⌘-click
    /// does; an ordinary tab's prompt still shows it here, as before.
    func testTheInUseOverrideAsksAPinToComeAndStillShowsAnOrdinaryTabHere() async throws {
        var (monitors, tabs) = try multidisplayFixture(2)
        config.workspaceSidebar.sharePinnedTabs = true
        config.workspaceSidebar.remotePinClick = .bringToThisDisplay
        try setWorkspaceSidebarTabFavorite(tabs["shown1"]!, true)
        config.workspaceToMonitorForceAssignment["shown1"] = [.secondary]
        handleWorkspaceSidebarAction(.overrideWorkspaceInUse("shown1"), targetMonitorScopeId: scope(monitors[0]))
        try await waitUntil { !notices.isEmpty }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(notices.map(\.body), ["“shown1” is kept on “Right”, so it stays there."])
        XCTAssertTrue(monitors[1].activeWorkspace === tabs["shown1"], "Not swapped here")
        XCTAssertTrue(monitors[0].activeWorkspace === tabs["shown0"])
        XCTAssertTrue(focus.workspace === tabs["shown0"], "Nor focused there")

        // A pin that may come: it comes, the same tab.
        (monitors, tabs) = try multidisplayFixture(2)
        config.workspaceSidebar.sharePinnedTabs = true
        try setWorkspaceSidebarTabFavorite(tabs["shown1"]!, true)
        handleWorkspaceSidebarAction(.overrideWorkspaceInUse("shown1"), targetMonitorScopeId: scope(monitors[0]))
        try await waitUntil { monitors[0].activeWorkspace === tabs["shown1"] }
        XCTAssertEqual(tabs["shown1"]!.preferredMonitorPoint, monitors[0].rect.topLeftCorner)

        // An ordinary tab on screen on the other display: swapped here, as the prompt always has.
        (monitors, tabs) = try multidisplayFixture(2)
        handleWorkspaceSidebarAction(.overrideWorkspaceInUse("shown1"), targetMonitorScopeId: scope(monitors[0]))
        try await waitUntil { monitors[0].activeWorkspace === tabs["shown1"] }
        XCTAssertFalse(monitors[1].activeWorkspace === tabs["shown1"], "The other display shows another tab")
        XCTAssertEqual(notices.count, 1, "No notice for these")
    }

    /// F3: ⌘-click on a browser tab of a pin from another display brings that pin here, the same
    /// window, then chooses that very tab here; a plain click chooses it where it is.
    func testCommandClickOnABrowserTabBringsItsPinThenChoosesThatVeryTab() async throws {
        var (monitors, tabs) = try sharedShown1()
        let window = try XCTUnwrap(tabs["shown1"]!.anyLeafWindowRecursive)
        let target = BrowserTabTarget(windowId: window.windowId, pid: window.app.pid, windowSession: UUID(), tabId: UUID())
        listedTabs = [target]
        _ = try await click("shown1", .selectBrowserTab(target), .command, on: monitors[0])
        try await waitUntil { !selections.isEmpty }
        XCTAssertEqual(selections, [.init(target, scope(monitors[0]), keepsPointer: true)], "That tab, here")
        XCTAssertTrue(monitors[0].activeWorkspace === tabs["shown1"])
        XCTAssertTrue(focus.windowOrNil === window, "The same window")

        (monitors, tabs) = try sharedShown1()
        let other = try XCTUnwrap(tabs["shown1"]!.anyLeafWindowRecursive)
        let there = BrowserTabTarget(windowId: other.windowId, pid: other.app.pid, windowSession: UUID(), tabId: UUID())
        listedTabs = [there]
        selections = []
        _ = try await click("shown1", .selectBrowserTab(there), [], on: monitors[0])
        XCTAssertEqual(selections, [.init(there, scope(monitors[1]), keepsPointer: true)], "Chosen where it is")
        XCTAssertTrue(monitors[1].activeWorkspace === tabs["shown1"])
    }

    /// F3: a ⌘-click overtaken or stale by the time its session runs, or refused, moves nothing and
    /// chooses nothing, anywhere.
    func testAStaleOrRefusedCommandClickOnABrowserTabMovesAndChoosesNothing() async throws {
        // Each change comes after the click, before its session runs, or before the click.
        let cases: [(name: String, afterClick: Bool, change: @MainActor (Workspace, AppBundle.Window) -> Void)] = [
            ("a newer choice", true, { _, _ in _ = noteWorkspaceSidebarBrowserTabChoice() }),
            ("the tab no longer listed", true, { [unowned self] _, _ in listedTabs = [] }),
            ("browser tabs off", true, { _, _ in config.workspaceSidebar.browserTabs = false }),
            ("another window with its id", true, { pin, window in
                window.unbindFromParent()
                _ = TestWindow.new(id: window.windowId, parent: pin.rootTilingContainer)
            }),
            ("not listed when clicked", false, { [unowned self] _, _ in listedTabs = [] }),
            ("held to its display", false, { _, _ in config.workspaceToMonitorForceAssignment["shown1"] = [.secondary] }),
        ]
        for (name, afterClick, change) in cases {
            let (monitors, tabs) = try sharedShown1()
            let pin = tabs["shown1"]!
            let window = try XCTUnwrap(pin.anyLeafWindowRecursive)
            let target = BrowserTabTarget(windowId: window.windowId, pid: window.app.pid, windowSession: UUID(), tabId: UUID())
            listedTabs = [target]
            selections = []
            notices = []
            if !afterClick { change(pin, window) }
            let activation = try await click("shown1", .selectBrowserTab(target), .command, on: monitors[0],
                deferred: afterClick ? { change(pin, window) } : nil)
            XCTAssertTrue(activation.isRemotePin, name)
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(selections, [], "\(name): nothing chosen")
            XCTAssertTrue(monitors[1].activeWorkspace === pin, "\(name): nothing moved")
            XCTAssertTrue(monitors[0].activeWorkspace === tabs["shown0"], name)
            XCTAssertEqual(notices.map(\.body), name == "held to its display" ? ["“shown1” is kept on “Right”, so it stays there."] : [],
                name)
        }

        // A ⌘-click naming another pin than the window's: nothing.
        let (monitors, tabs) = try sharedShown1()
        let window = try XCTUnwrap(tabs["shown1"]!.anyLeafWindowRecursive)
        let target = BrowserTabTarget(windowId: window.windowId, pid: window.app.pid, windowSession: UUID(), tabId: UUID())
        selections = []
        handleWorkspaceSidebarAction(.bringBrowserTabHere("pin0", target), targetMonitorScopeId: scope(monitors[0]))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(selections, [])
        XCTAssertTrue(monitors[1].activeWorkspace === tabs["shown1"])
    }

    // MARK: Helpers

    /// Two displays with shared pins and `shown1`, on screen on Right, pinned.
    private func sharedShown1() throws -> ([Monitor], [String: Workspace]) {
        let result = try multidisplayFixture(2)
        config.workspaceSidebar.sharePinnedTabs = true
        try setWorkspaceSidebarTabFavorite(result.1["shown1"]!, true)
        return result
    }

    /// Clicks `name`'s row in the sidebar of `monitor`, as its activation sends `action` to the
    /// handler; `deferred` runs right after, before the session the click started.
    @discardableResult
    private func click(_ name: String, _ action: WorkspaceSidebarAction, _ modifiers: NSEvent.ModifierFlags, on monitor: Monitor,
                       deferred: (() throws -> Void)? = nil) async throws -> WorkspaceSidebarTabActivation {
        let list = await multidisplaySnapshot(listing: monitor)
        let tab = try XCTUnwrap(list.workspaces.first { $0.name == name }, name)
        let (activation, _) = WorkspaceSidebarView(snapshot: list).tabActivation(tab, isPinned: false, pageAllowsActivation: true)
        activation.select(action, modifiers: modifiers) { handleWorkspaceSidebarAction($0, targetMonitorScopeId: scope(monitor)) }
        try deferred?()
        return activation
    }

    private func scope(_ monitor: Monitor) -> String { workspaceSidebarMonitorScopeId(for: monitor) }

    private func waitUntil(_ condition: () -> Bool, timeout: Duration = .seconds(3)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

// MARK: Fixtures shared by both suites

/// An `on-focused-monitor-changed` run, as the runner was asked for it.
struct MonitorHook: Equatable {
    let workspaceName: String
    let keepsPointer: Bool

    init(_ workspaceName: String, keepsPointer: Bool) {
        self.workspaceName = workspaceName
        self.keepsPointer = keepsPointer
    }
}

/// A browser tab the sidebar asked to choose.
struct BrowserTabSelection: Equatable {
    let target: BrowserTabTarget
    let monitorScopeId: String?
    let keepsPointer: Bool

    init(_ target: BrowserTabTarget, _ monitorScopeId: String?, keepsPointer: Bool) {
        self.target = target
        self.monitorScopeId = monitorScopeId
        self.keepsPointer = keepsPointer
    }
}

/// The seams these tests replace, as they were, to put back.
@MainActor
final class MultidisplaySeams {
    let notice = showWorkspaceSidebarNotice
    let monitorCommands = runFocusedMonitorChangedCommands
    let mouseMove = postMoveMouseEvent
    let selectBrowserTab = selectWorkspaceSidebarBrowserTab
    let isListed = workspaceSidebarBrowserTabIsListed

    func restoreMonitorCommands() { runFocusedMonitorChangedCommands = monitorCommands }

    func restore() {
        showWorkspaceSidebarNotice = notice
        runFocusedMonitorChangedCommands = monitorCommands
        postMoveMouseEvent = mouseMove
        selectWorkspaceSidebarBrowserTab = selectBrowserTab
        workspaceSidebarBrowserTabIsListed = isListed
    }
}

/// Displays left to right, each showing `shown<i>`, with `pin<i>` pinned and hidden on it, and
/// `hidden[i]`'s tabs hidden on it, each with one window.
@MainActor
fileprivate func multidisplayFixture(_ count: Int, hidden: [Int: [String]] = [:]) throws -> ([Monitor], [String: Workspace]) {
    setUpWorkspacesForTests()
    workspaceSidebarOrganizationStore = .init()
    config.workspaceSidebar.enabled = true
    config.workspaceSidebar.mode = .tabs
    let names = ["Left", "Right", "Far"]
    let monitors: [Monitor] = (0 ..< count).map { index in
        let rect = Rect(topLeftX: CGFloat(index) * 1920, topLeftY: 0, width: 1920, height: 1080)
        return WorkspaceSidebarDragTestMonitor(monitorAppKitNsScreenScreensId: index + 1, name: names[index],
            rect: rect, visibleRect: rect, isMain: index == 0)
    }
    setMonitorsForTests(monitors)
    Workspace.reconcileWorkspaceState()
    var tabs: [String: Workspace] = [:]
    var windowId: UInt32 = 1
    func tab(_ name: String, on monitor: Monitor) {
        let tab = Workspace.get(byName: name)
        _ = TestWindow.new(id: windowId, parent: tab.rootTilingContainer)
        windowId += 1
        tab.preferredMonitorPoint = monitor.rect.topLeftCorner
        tabs[name] = tab
    }
    for (index, monitor) in monitors.enumerated() {
        tab("shown\(index)", on: monitor)
        tab("pin\(index)", on: monitor)
        XCTAssertTrue(monitor.setActiveWorkspace(tabs["shown\(index)"]!))
    }
    for (index, monitor) in monitors.enumerated() {
        for name in hidden[index] ?? [] { tab(name, on: monitor) }
    }
    XCTAssertTrue(tabs["shown0"]!.focusWorkspace())
    try setWorkspaceSidebarTabsFavorite(monitors.indices.map { tabs["pin\($0)"]! }, true)
    // Focus changes from here on are seen against this one.
    checkOnFocusChangedCallbacks()
    return (monitors, tabs)
}

/// The ordinary tabs of `projectId` the list of `monitor` shows, in order.
@MainActor
fileprivate func multidisplayListed(on monitor: Monitor, _ projectId: WorkspaceProjectId) -> [String] {
    orderedWorkspaces(in: projectId).filter {
        workspaceSidebarOrganizationStore.state.workspaces[$0.name]?.isFavorite != true && workspaceTabIsShown($0)
            && $0.workspaceMonitor.rect == monitor.rect
    }.map(\.name)
}

/// What the sidebar on `panel` shows listing `monitor`'s tabs, built from the model as a
/// panel's would be, without any panel.
@MainActor
fileprivate func multidisplaySnapshot(listing monitor: Monitor, on panel: Monitor? = nil) async -> WorkspaceSidebarSnapshot {
    let state = await buildWorkspaceSidebarModelState()
    var snapshot = WorkspaceSidebarSnapshot.empty
    snapshot.workspaces = state.workspaces
    snapshot.monitorScopes = state.monitorScopes
    snapshot.projects = state.projects
    snapshot.selectedMonitorScopeId = workspaceSidebarMonitorScopeId(for: monitor)
    snapshot.targetMonitorScopeId = workspaceSidebarMonitorScopeId(for: panel ?? monitor)
    snapshot.focusedMonitorScopeId = state.focusedMonitorScopeId
    snapshot.activeProjectId = activeWorkspaceProjectId(for: monitor)
    snapshot.visibleWidth = 280
    snapshot.configuration.usesTabsList = true
    snapshot.configuration.tabCollections = workspaceSidebarOrganizationStore.state.collections
    snapshot.configuration.sharesPinnedTabs = config.workspaceSidebar.sharePinnedTabs
    snapshot.configuration.remotePinClick = config.workspaceSidebar.remotePinClick
    return snapshot
}
