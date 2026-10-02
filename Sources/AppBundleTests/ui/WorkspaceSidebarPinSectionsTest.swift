import AppKit
@testable import AppBundle
import Common
import SwiftUI
import XCTest

/// Tabs mode: the pinned tiles in two sections, pins in All Projects above the project's own.
/// Dragging a pin to the other section moves it there, still pinned, with its tab and windows, in
/// one Undo; a pin coming back from All Projects comes to the project the sidebar shows.
@MainActor
final class WorkspaceSidebarPinSectionsTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        setSavedWorkspaceTestEnvironment()
        workspaceSidebarOrganizationStore = .init()
        TrayMenuModel.shared.isEnabled = true
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        WorkspaceSidebarTabSelection.shared.clear()
    }

    override func tearDown() async throws {
        cancelActiveSidebarPinnedTabDrag()
        WorkspaceSidebarTabSplitHoverController.shared.reset()
        WorkspaceSidebarTabUndo.shared.clear()
        WorkspaceSidebarTabDragState.shared.set(false)
        WorkspaceSidebarTabSelection.shared.clear()
        clearWorkspaceSidebarDropPreview()
        workspaceSidebarOrganizationStore = .init()
        setMonitorsForTests(nil)
        config = defaultConfig
        try await super.tearDown()
    }

    private struct Tabs {
        let a: WorkspaceProjectId
        let b: WorkspaceProjectId
        /// A's, pinned in All Projects.
        let g: Workspace
        /// B's own pin.
        let q: Workspace
        let b1: Workspace
        let b2: Workspace
    }

    private var nextWindowId: UInt32 = 1

    private func tab(_ name: String, in projectId: WorkspaceProjectId) -> Workspace {
        let tab = Workspace.get(byName: name)
        _ = TestWindow.new(id: nextWindowId, parent: tab.rootTilingContainer)
        nextWindowId += 1
        tab.assignProject(projectId)
        return tab
    }

    /// Projects A and B. A's `g` is pinned in All Projects; B has its own pin `q` and tabs `b1` and
    /// `b2`. The display shows `b1`, so it's in B.
    private func tabs() throws -> Tabs {
        let a = createWorkspaceProject().id
        let b = createWorkspaceProject().id
        let g = tab("g", in: a), q = tab("q", in: b), b1 = tab("b1", in: b), b2 = tab("b2", in: b)
        XCTAssertTrue(g.focusWorkspace())
        try setWorkspaceSidebarTabPinScope(g, .allProjects, projectId: a)
        try setWorkspaceSidebarTabFavorite(q, true)
        XCTAssertTrue(b1.focusWorkspace())
        Workspace.reconcileWorkspaceState()
        XCTAssertEqual(activeWorkspaceProjectId(for: mainMonitor), b)
        return Tabs(a: a, b: b, g: g, q: q, b1: b1, b2: b2)
    }

    private var scope: String { workspaceSidebarMonitorScopeId(for: mainMonitor) }

    private func appearance(_ tab: Workspace) -> WorkspaceSidebarItemAppearance? {
        workspaceSidebarOrganizationStore.state.workspaces[tab.name]
    }

    private func pinTarget(_ projectId: WorkspaceProjectId, beside tab: Workspace?, after: Bool = false,
                           section: WorkspaceSidebarPinSection) -> WorkspaceSidebarDropTarget {
        .init(kind: .pinnedTabs(projectId: projectId, gap: tab.map { .init(workspaceName: $0.name, isAfter: after) },
            monitorScopeId: scope, section: section), rect: Rect(topLeftX: 0, topLeftY: 0, width: 200, height: 60))
    }

    private func drop(_ tab: Workspace, _ target: WorkspaceSidebarDropTarget) -> WorkspaceSidebarPinnedTabDrop? {
        workspaceSidebarPinnedTabDrop(tab, target: target, point: CGPoint(x: 100, y: 30))
    }

    /// The real drag of `pin` released on `target`, through its session and Undo.
    private func drag(_ pin: Workspace, onto target: WorkspaceSidebarDropTarget) async throws {
        let surface = PinSectionSurface(target: target, scope: scope)
        WorkspaceSidebarTemporaryDropSurfaces.shared.register(surface)
        defer { WorkspaceSidebarTemporaryDropSurfaces.shared.unregister(surface) }
        let pointer = CGPoint(x: 100, y: 30)
        WorkspaceSidebarDragSessions.shared.noteLeftMouseDown()
        updateSidebarPinnedTabDrag(pin.name, pointer: pointer)
        let preview = TrayMenuModel.shared.workspaceSidebarDropPreview
        XCTAssertNotNil(preview, "The drop is shown before it's made")
        lastPreview = preview
        finishSidebarPinnedTabDrag(pin.name, pointer: pointer)
        try await waitUntil { WorkspaceSidebarTabUndo.shared.title != nil }
    }

    private var lastPreview: WorkspaceSidebarDropPreviewViewModel?

    private func waitUntil(_ condition: () -> Bool, timeout: Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: The two sections, as the sidebar lays them out

    /// The real Tabs sidebar for the display, without a window, with where it laid out its drop targets.
    private func sidebarTargets(dragging: Bool = false) async -> [WorkspaceSidebarDropTargetFrame] {
        await updateWorkspaceSidebarModel()
        var snapshot = WorkspaceSidebarSnapshot.empty
        snapshot.workspaces = TrayMenuModel.shared.workspaceSidebarWorkspaces
        snapshot.projects = TrayMenuModel.shared.workspaceSidebarProjects
        snapshot.activeProjectId = activeWorkspaceProjectId(for: mainMonitor)
        snapshot.selectedMonitorScopeId = scope
        snapshot.targetMonitorScopeId = scope
        snapshot.focusedMonitorScopeId = TrayMenuModel.shared.workspaceSidebarFocusedMonitorScopeId
        snapshot.configuration.usesTabsList = true
        snapshot.configuration.expandedWidth = 280
        snapshot.configuration.collapsedWidth = 44
        snapshot.visibleWidth = 280
        WorkspaceSidebarTabDragState.shared.set(dragging)
        defer { WorkspaceSidebarTabDragState.shared.set(false) }
        var targets: [WorkspaceSidebarDropTargetFrame] = []
        let host = NSHostingView(rootView: WorkspaceSidebarView(snapshot: snapshot, actions: .init(setDropTargets: { targets = $0 }),
            reduceMotionOverride: true, reduceTransparencyOverride: true, browserTabsModel: BrowserTabsModel(snapshots: [:]))
            .frame(width: 280, height: 600))
        host.frame = CGRect(x: 0, y: 0, width: 280, height: 600)
        host.layoutSubtreeIfNeeded()
        letTheViewSettle()
        return targets
    }

    /// The hosted view lays out and publishes its targets on the run loop's next passes.
    private func letTheViewSettle() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
    }

    private func tile(_ name: String, in targets: [WorkspaceSidebarDropTargetFrame]) -> WorkspaceSidebarDropTargetFrame? {
        targets.first { $0.kind == .workspace(name) && $0.tabReorderDestination?.arrangesPins == true }
    }

    private func zone(_ section: WorkspaceSidebarPinSection, in targets: [WorkspaceSidebarDropTargetFrame]) -> CGRect? {
        targets.first { isZone($0, section) }?.frame
    }

    private func isZone(_ target: WorkspaceSidebarDropTargetFrame, _ section: WorkspaceSidebarPinSection) -> Bool {
        if case .pinnedTabs(_, nil, _, section) = target.kind { true } else { false }
    }

    func testTheSidebarShowsPinsInAllProjectsAboveTheProjectsOwn() async throws {
        let t = try tabs()
        let targets = await sidebarTargets()
        let everywhere = try XCTUnwrap(tile("g", in: targets), "A's pin in All Projects shows in B's sidebar")
        let own = try XCTUnwrap(tile("q", in: targets))
        XCTAssertEqual(everywhere.tabReorderDestination?.pinSection, .allProjects)
        XCTAssertEqual(own.tabReorderDestination?.pinSection, .project)
        XCTAssertEqual(everywhere.tabReorderDestination?.projectId, t.b, "Its tile takes drops for the project shown")
        XCTAssertLessThan(everywhere.frame.maxY, own.frame.minY, "Above the project's own pins")
        XCTAssertGreaterThan(own.frame.minY - everywhere.frame.maxY, workspaceSidebarPinnedGridSpacing,
            "Apart from them, past the room between tiles: the divider")
        XCTAssertEqual(everywhere.frame.width, own.frame.width, accuracy: 0.5, "The two sections' tiles line up")
        XCTAssertNil(tile("b1", in: targets), "Tabs aren't tiles")
        XCTAssertNil(zone(.allProjects, in: targets), "No drop places while nothing is dragged")
        XCTAssertNil(zone(.project, in: targets))
    }

    func testAnEmptySectionTakesADropOnlyWhileDraggingWithoutMovingAnything() async throws {
        let t = try tabs()
        try setWorkspaceSidebarTabPinScope(t.g, nil, projectId: t.a)
        // B has only its own pin q: no pins in All Projects.
        let resting = await sidebarTargets()
        let dragging = await sidebarTargets(dragging: true)
        XCTAssertNil(zone(.allProjects, in: resting))
        let place = try XCTUnwrap(zone(.allProjects, in: dragging), "A place to pin in All Projects, while dragging")
        let q = try XCTUnwrap(tile("q", in: dragging))
        XCTAssertLessThanOrEqual(place.maxY, q.frame.minY, "Above where those pins go, over the header")
        XCTAssertEqual(dragging.filter { !isZone($0, .allProjects) }, resting, "Offering it moves nothing")

        // Only pins in All Projects: the project's place to pin is over the search row.
        try setWorkspaceSidebarTabPinScope(t.q, .allProjects, projectId: t.b)
        let onlyEverywhere = await sidebarTargets(dragging: true)
        let projectPlace = try XCTUnwrap(zone(.project, in: onlyEverywhere))
        let topTile = try XCTUnwrap(tile("q", in: onlyEverywhere))
        XCTAssertGreaterThanOrEqual(projectPlace.minY, topTile.frame.maxY, "Below the pins in All Projects")
        XCTAssertNil(zone(.allProjects, in: onlyEverywhere), "That section has pins")
    }

    // MARK: Dragging between them

    func testDraggingAProjectsPinUpPinsItInAllProjectsWithOneUndo() async throws {
        let t = try tabs()
        let windows = t.q.allLeafWindowsRecursive.map(ObjectIdentifier.init)
        try await drag(t.q, onto: pinTarget(t.b, beside: t.g, section: .allProjects))
        XCTAssertEqual(lastPreview?.targetPinSection, .allProjects)
        XCTAssertEqual(lastPreview?.changesPinScope, true, "The section says where it goes")
        XCTAssertEqual(lastPreview?.targetProjectId, t.b)
        XCTAssertTrue(workspaceIsPinnedInAllProjects(t.q))
        XCTAssertEqual(t.q.projectId, t.b, "Its home stays")
        XCTAssertEqual(workspacePinnedTabsInAllProjects().map(\.name), ["q", "g"], "Where it was dropped")
        XCTAssertEqual(t.q.allLeafWindowsRecursive.map(ObjectIdentifier.init), windows, "Same tab, same windows")
        XCTAssertEqual(WorkspaceSidebarTabUndo.shared.title, "Undo Pin to All Projects")
        try WorkspaceSidebarTabUndo.shared.undo()
        XCTAssertFalse(workspaceIsPinnedInAllProjects(t.q))
        XCTAssertEqual(appearance(t.q)?.isFavorite, true, "Back among B's pins")
    }

    func testDraggingAPinInAllProjectsDownBringsItToTheProjectShownWithOneUndo() async throws {
        let t = try tabs()
        let windows = t.g.allLeafWindowsRecursive.map(ObjectIdentifier.init)
        try await drag(t.g, onto: pinTarget(t.b, beside: t.q, after: true, section: .project))
        XCTAssertEqual(lastPreview?.targetPinSection, .project)
        XCTAssertEqual(lastPreview?.changesPinScope, true)
        XCTAssertFalse(workspaceIsPinnedInAllProjects(t.g))
        XCTAssertEqual(appearance(t.g)?.isFavorite, true, "Moving between sections isn't unpinning")
        XCTAssertEqual(t.g.projectId, t.b, "It's the project shown's now")
        XCTAssertEqual(savedWorkspaceStore.record(named: "g")?.projectId, t.b)
        XCTAssertEqual(workspacePinnedTabs(in: t.b).map(\.name), ["q", "g"])
        XCTAssertEqual(t.g.allLeafWindowsRecursive.map(ObjectIdentifier.init), windows)
        XCTAssertEqual(WorkspaceSidebarTabUndo.shared.title, "Undo Pin to This Project")
        captureSavedWorkspaces(facts: savedTestFacts())
        WorkspaceSidebarTabUndo.shared.invalidateIfChanged()
        try WorkspaceSidebarTabUndo.shared.undo()
        XCTAssertTrue(workspaceIsPinnedInAllProjects(t.g), "One Undo puts it back in All Projects")
        XCTAssertEqual(t.g.projectId, t.a, "at home in A")
    }

    func testAnEmptySectionsPlaceTakesThePin() throws {
        let t = try tabs()
        XCTAssertEqual(drop(t.g, pinTarget(t.b, beside: nil, section: .project)),
            .rearrange(nil, monitorScopeId: scope, move: .init(to: .project, in: t.b)))
        let promote = try XCTUnwrap(drop(t.q, pinTarget(t.b, beside: nil, section: .allProjects)))
        try applyWorkspaceSidebarPinnedTabDrop(t.q, promote)
        XCTAssertEqual(workspacePinnedTabsInAllProjects().map(\.name), ["g", "q"], "After the pins there")
    }

    func testRearrangingWithinASectionIsAsBefore() throws {
        let t = try tabs()
        let q2 = tab("q2", in: t.b)
        try setWorkspaceSidebarTabFavorite(q2, true)
        XCTAssertEqual(drop(q2, pinTarget(t.b, beside: t.q, section: .project)),
            .rearrange(.init(workspaceName: "q", isAfter: false), monitorScopeId: scope))
        let g2 = tab("g2", in: t.a)
        try setWorkspaceSidebarTabPinScope(g2, .allProjects, projectId: t.a)
        // In B's sidebar, though both are A's.
        let rearrange = try XCTUnwrap(drop(g2, pinTarget(t.b, beside: t.g, section: .allProjects)))
        XCTAssertEqual(rearrange, .rearrange(.init(workspaceName: "g", isAfter: false), monitorScopeId: scope))
        XCTAssertEqual(workspaceSidebarPinnedTabDropUndoTitle(rearrange), "Move Tab")
        try applyWorkspaceSidebarPinnedTabDrop(g2, rearrange)
        XCTAssertEqual(workspacePinnedTabsInAllProjects().map(\.name), ["g2", "g"])
        XCTAssertEqual(workspacePinnedTabs(in: t.b).map(\.name), ["q", "q2"], "B's own pins untouched")
        XCTAssertNil(drop(t.g, pinTarget(t.b, beside: t.g, section: .allProjects)), "Beside itself, nothing")
    }

    // MARK: Leaving the pins, joining one

    func testAPinInAllProjectsLeavesThePinsOnlyIntoTheProjectShown() async throws {
        let t = try tabs()
        let rowRect = Rect(topLeftX: 0, topLeftY: 100, width: 200, height: 36)
        let gap = WorkspaceSidebarTabGap(workspaceName: "b2", isAfter: true)
        let list = try XCTUnwrap(drop(t.g, .init(kind: .tabGap(projectId: t.b, monitorScopeId: scope, gap: gap), rect: rowRect)))
        try applyWorkspaceSidebarPinnedTabDrop(t.g, list)
        XCTAssertEqual(appearance(t.g)?.isFavorite, false)
        XCTAssertEqual(t.g.projectId, t.b, "Unpinned into the list, it's a tab of that list's project")

        try setWorkspaceSidebarTabPinScope(t.g, .allProjects, projectId: t.b)
        t.g.assignProject(t.a)
        let newTab = try XCTUnwrap(drop(t.g, .init(kind: .newWorkspace(projectId: t.b, monitorScopeId: scope), rect: rowRect)))
        XCTAssertEqual(newTab, .unpin(monitorScopeId: scope, projectId: t.b))
        try applyWorkspaceSidebarPinnedTabDrop(t.g, newTab)
        XCTAssertEqual(t.g.projectId, t.b, "On New Tab too")
        XCTAssertEqual(appearance(t.g)?.isFavorite, false)

        try setWorkspaceSidebarTabPinScope(t.g, .allProjects, projectId: t.b)
        t.g.assignProject(t.a)
        let group = try workspaceSidebarOrganizationStore.create(projectId: t.b, workspaceNames: ["b2"])
        let intoGroup = try XCTUnwrap(drop(t.g, .init(kind: .tabCollection(group.id, monitorScopeId: scope), rect: rowRect)))
        try applyWorkspaceSidebarPinnedTabDrop(t.g, intoGroup)
        XCTAssertEqual(t.g.projectId, t.b, "Into one of its groups too")
        XCTAssertEqual(workspaceSidebarOrganizationStore.collection(containing: "g")?.id, group.id)

        // D6: over a tab, before a pause, nothing: it never comes down through a row.
        try setWorkspaceSidebarTabPinScope(t.b1, .allProjects, projectId: t.b)
        let row = WorkspaceSidebarDropTarget(kind: .workspace("b2"), rect: rowRect, acceptsSides: true,
            tabReorderDestination: .init(projectId: t.b, monitorScopeId: scope, collectionId: nil))
        XCTAssertNil(workspaceSidebarPinnedTabDrop(t.b1, target: row, point: CGPoint(x: 150, y: 110)))
    }

    func testATabTiledIntoAPinInAllProjectsTakesItsScope() async throws {
        let t = try tabs()
        let rowRect = Rect(topLeftX: 0, topLeftY: 100, width: 200, height: 36)
        let row = WorkspaceSidebarDropTarget(kind: .workspace("b2"), rect: rowRect, acceptsSides: true,
            tabReorderDestination: .init(projectId: t.b, monitorScopeId: scope, collectionId: nil))
        _ = workspaceSidebarPinnedTabDrop(t.g, target: row, point: CGPoint(x: 150, y: 110))
        try await Task.sleep(for: .milliseconds(320))
        let join = try XCTUnwrap(workspaceSidebarPinnedTabDrop(t.g, target: row, point: CGPoint(x: 150, y: 110)),
            "A pin in All Projects takes in a tab of the project shown, though that isn't its home")
        try applyWorkspaceSidebarPinnedTabDrop(t.g, join)
        let b2Window = try XCTUnwrap(Window.get(byId: 4))
        XCTAssertTrue(b2Window.nodeWorkspace === t.g, "The tab's windows join the pin")
        XCTAssertTrue(workspaceIsPinnedInAllProjects(t.g), "which stays in All Projects: they're in every project now")
        XCTAssertEqual(t.g.projectId, t.a)

        // A window dragged onto its tile and paused tiles into it the same way.
        let b1Window = try XCTUnwrap(t.b1.allLeafWindowsRecursive.first)
        await queueWorkspaceSidebarDrop(b1Window.windowId, subject: .window, target: .workspace("g"), placement: .left,
            intent: .physical)?.value
        XCTAssertTrue(b1Window.nodeWorkspace === t.g)
        XCTAssertTrue(workspaceIsPinnedInAllProjects(t.g))
    }

    // MARK: Windows and batches

    func testATabDraggedOntoThePinsInAllProjectsIsPinnedThere() throws {
        let t = try tabs()
        let window = try XCTUnwrap(t.b2.allLeafWindowsRecursive.first)
        previewWorkspaceSidebarDrop(window.windowId, subject: .window,
            target: .pinnedTabs(projectId: t.b, gap: .init(workspaceName: "g", isAfter: true), monitorScopeId: scope,
                section: .allProjects))
        XCTAssertEqual(TrayMenuModel.shared.workspaceSidebarDropPreview?.targetPinSection, .allProjects)
        XCTAssertEqual(TrayMenuModel.shared.workspaceSidebarDropPreview?.changesPinScope, true)
        try applySidebarPinDrop(window.windowId, subject: .window, gap: .init(workspaceName: "g", isAfter: true),
            monitorScopeId: scope, section: .allProjects, projectId: t.b)
        XCTAssertTrue(workspaceIsPinnedInAllProjects(t.b2))
        XCTAssertEqual(workspacePinnedTabsInAllProjects().map(\.name), ["g", "b2"])
        XCTAssertEqual(t.b2.projectId, t.b)
    }

    func testChosenPinsDraggedTogetherAllChangeSectionWithOneUndo() async throws {
        let t = try tabs()
        let selection = WorkspaceSidebarTabSelection.shared
        let order = ["g", "q"]
        XCTAssertTrue(selection.handleClick(on: "g", modifiers: .command, order: order, active: nil))
        XCTAssertTrue(selection.handleClick(on: "q", modifiers: .command, order: order, active: nil))
        let batch = try XCTUnwrap(WorkspaceSidebarDragBatch(startingWith: "g"), "A's pin in All Projects is chosen with B's")
        XCTAssertEqual(batch.names, ["g", "q"])
        XCTAssertEqual(batch.kind, .pins)
        XCTAssertEqual(batch.projectId, t.b)

        let down = try XCTUnwrap(workspaceSidebarPinnedBatchDrop(batch, target: pinTarget(t.b, beside: nil, section: .project),
            point: CGPoint(x: 100, y: 30)))
        XCTAssertEqual(down, .rearrange(nil, monitorScopeId: scope, move: .init(to: .project, in: t.b)))
        XCTAssertEqual(workspaceSidebarPinnedBatchDropUndoTitle(batch, down), "Pin 2 Tabs to This Project")
        await runWorkspaceSidebarSession(undoTitle: workspaceSidebarPinnedBatchDropUndoTitle(batch, down)) {
            _ = try applyWorkspaceSidebarPinnedBatchDrop(batch, down)
        }?.value
        XCTAssertEqual(workspacePinnedTabs(in: t.b).map(\.name), ["g", "q"], "Both B's pins, in their order")
        XCTAssertEqual(t.g.projectId, t.b)
        XCTAssertTrue(workspacePinnedTabsInAllProjects().isEmpty)
        try WorkspaceSidebarTabUndo.shared.undo()
        XCTAssertTrue(workspaceIsPinnedInAllProjects(t.g), "One Undo for all of them")
        XCTAssertEqual(t.g.projectId, t.a)
        XCTAssertFalse(workspaceIsPinnedInAllProjects(t.q))

        // Chosen again, from B's pin this time.
        selection.clear()
        XCTAssertTrue(selection.handleClick(on: "g", modifiers: .command, order: order, active: nil))
        XCTAssertTrue(selection.handleClick(on: "q", modifiers: .command, order: order, active: nil))
        let fromQ = try XCTUnwrap(WorkspaceSidebarDragBatch(startingWith: "q"))
        let up = try XCTUnwrap(workspaceSidebarPinnedBatchDrop(fromQ, target: pinTarget(t.b, beside: nil, section: .allProjects),
            point: CGPoint(x: 100, y: 30)))
        _ = try applyWorkspaceSidebarPinnedBatchDrop(fromQ, up)
        XCTAssertEqual(workspacePinnedTabsInAllProjects().map(\.name), ["g", "q"])

        // D4: pins and tabs chosen together go nowhere.
        selection.clear()
        XCTAssertTrue(selection.handleClick(on: "g", modifiers: .command, order: ["g", "b1"], active: nil))
        XCTAssertTrue(selection.handleClick(on: "b1", modifiers: .command, order: ["g", "b1"], active: nil))
        let mixed = try XCTUnwrap(WorkspaceSidebarDragBatch(startingWith: "g"))
        XCTAssertEqual(mixed.kind, .mixed)
        XCTAssertNil(workspaceSidebarPinnedBatchDrop(mixed, target: pinTarget(t.b, beside: nil, section: .project),
            point: CGPoint(x: 100, y: 30)))
    }

    func testTheChosenTabsMenuPinsThemInAllProjectsOrBackInTheProjectShown() async throws {
        let t = try tabs()
        await updateWorkspaceSidebarModel()
        let titles = workspaceSidebarTabSelectionMenuEntries(["g", "q"], workspaces: TrayMenuModel.shared.workspaceSidebarWorkspaces,
            collections: [], contextProjectId: t.b, contextProjectName: "Bee", send: { _ in }, clear: {}).map(\.title)
        XCTAssertTrue(titles.contains("Pin 2 Tabs to All Projects"))
        XCTAssertTrue(titles.contains("Pin 2 Tabs to “Bee” Only"))

        await handleWorkspaceSidebarOrganizationAction(.setTabsPinScope(["g", "q", "b1"], .allProjects, projectId: t.b),
            targetMonitorScopeId: scope)?.value
        XCTAssertEqual(workspacePinnedTabsInAllProjects().map(\.name), ["g", "q", "b1"])
        XCTAssertEqual(WorkspaceSidebarTabUndo.shared.title, "Undo Pin Tabs to All Projects")
        try WorkspaceSidebarTabUndo.shared.undo()
        XCTAssertEqual(workspacePinnedTabsInAllProjects().map(\.name), ["g"])

        // Unpinned together, a pin in All Projects stays in the project shown.
        await handleWorkspaceSidebarOrganizationAction(.setTabsFavorite(["g", "q"], false), targetMonitorScopeId: scope)?.value
        XCTAssertEqual(t.g.projectId, t.b)
        XCTAssertEqual(appearance(t.g)?.isFavorite, false)
        XCTAssertEqual(appearance(t.q)?.isFavorite, false)
    }

    func testForgettingAPinInAllProjectsLeavesATabOfTheProjectShown() async throws {
        let t = try tabs()
        await forgetSavedWorkspaceFromSidebar("g", targetMonitorScopeId: scope)?.value
        XCTAssertNotEqual(appearance(t.g)?.isFavorite, true)
        XCTAssertEqual(t.g.projectId, t.b, "Not of its home, where this sidebar wouldn't list it")
    }

    // MARK: Undo and switching

    /// An edit that put the pin on screen, then a switch with it kept there: Undo takes the edit back
    /// and leaves the display in the project it was switched to, on the pin.
    func testUndoAfterASwitchKeepsTheProjectSwitchedTo() async throws {
        let t = try tabs()
        let rowRect = Rect(topLeftX: 0, topLeftY: 100, width: 200, height: 36)
        let row = WorkspaceSidebarDropTarget(kind: .workspace("b1"), rect: rowRect, acceptsSides: true,
            tabReorderDestination: .init(projectId: t.b, monitorScopeId: scope, collectionId: nil))
        _ = workspaceSidebarPinnedTabDrop(t.g, target: row, point: CGPoint(x: 150, y: 110))
        try await Task.sleep(for: .milliseconds(320))
        let join = try XCTUnwrap(workspaceSidebarPinnedTabDrop(t.g, target: row, point: CGPoint(x: 150, y: 110)))
        await runWorkspaceSidebarSession(undoTitle: workspaceSidebarPinnedTabDropUndoTitle(join)) {
            try applyWorkspaceSidebarPinnedTabDrop(t.g, join)
        }?.value
        XCTAssertTrue(mainMonitor.activeWorkspace === t.g)
        XCTAssertEqual(activeWorkspaceProjectId(for: mainMonitor), t.b)
        // The pin's own window, which Undo leaves in it, has focus.
        XCTAssertTrue(try XCTUnwrap(Window.get(byId: 1)).focusWindow())
        XCTAssertTrue(switchWorkspaceProject(t.a, on: mainMonitor) === t.g, "Kept on screen through the switch")
        try WorkspaceSidebarTabUndo.shared.undo()
        XCTAssertEqual(t.b1.allLeafWindowsRecursive.count, 1, "The tab has its window back")
        XCTAssertTrue(mainMonitor.activeWorkspace === t.g)
        XCTAssertEqual(activeWorkspaceProjectId(for: mainMonitor), t.a, "and the display stays in the project switched to")
    }
}

/// A list's surface, during a drag, that takes every drop on one target.
private final class PinSectionSurface: WorkspaceSidebarTemporaryDropSurface {
    let surfaceRef: WorkspaceSidebarSurfaceRef = .dropDestination(generation: 52)
    let stackingOrder = 1
    let dropDestination: WorkspaceSidebarDropDestinationIdentity?
    let target: WorkspaceSidebarDropTarget

    init(target: WorkspaceSidebarDropTarget, scope: String) {
        self.target = target
        dropDestination = .init(monitorScopeId: scope)
    }

    func surfaceRectNormalized(containing point: CGPoint) -> Rect? { target.rect.contains(point) ? target.rect : nil }
    func dropTarget(atNormalizedPoint _: CGPoint, hitSlop _: NSEdgeInsets, includesTabGaps _: Bool) -> WorkspaceSidebarDropTarget? {
        target
    }
}
