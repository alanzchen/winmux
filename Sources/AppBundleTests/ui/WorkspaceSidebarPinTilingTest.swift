import AppKit
@testable import AppBundle
import Common
import XCTest

/// Tabs mode: a pinned tile dragged onto a tab in the list, and paused there, tiles that tab into the
/// pin. The pin stays pinned, in its place, and goes on the half it was dropped on. Moving across a
/// tab without the pause does nothing: only the gaps between tabs, and New Tab, unpin it.
@MainActor
final class WorkspaceSidebarPinTilingTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        workspaceSidebarOrganizationStore = .init()
        TrayMenuModel.shared.isEnabled = true
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
    }

    override func tearDown() async throws {
        WorkspaceSidebarTabSplitHoverController.shared.reset()
        WorkspaceSidebarTabUndo.shared.clear()
        clearWorkspaceSidebarDropPreview()
        workspaceSidebarOrganizationStore = .init()
        setMonitorsForTests(nil)
        config = defaultConfig
        try await super.tearDown()
    }

    // MARK: Over a tab in the list

    func testAPinMovedAcrossATabWithoutPausingDoesNothing() throws {
        let (pin, tab) = try pinAndTab()
        XCTAssertNil(drop(pin, onto: tab, right: true), "No pause: no drop, and no line to promise one")
        XCTAssertNil(drop(pin, onto: tab, right: false))
        XCTAssertEqual(pins(), ["p"], "Still pinned")
        // The gap between tabs still unpins it there.
        let gap = WorkspaceSidebarDropTarget(kind: .tabGap(projectId: tab.projectId, monitorScopeId: scope,
            gap: .init(workspaceName: tab.name, isAfter: true)), rect: rowRect)
        XCTAssertEqual(workspaceSidebarPinnedTabDrop(pin, target: gap, point: CGPoint(x: 100, y: 135)),
            .list(projectId: tab.projectId, monitorScopeId: scope, gap: .init(workspaceName: tab.name, isAfter: true)))
    }

    func testAPinPausedOverATabTilesItOnTheHalfPointedAt() async throws {
        for right in [false, true] {
            try await setUp()
            let (pin, tab) = try pinAndTab()
            let pinOrder = workspaceSidebarOrganizationStore.state.workspaces["p"]
            let drop = try await pausedDrop(pin, onto: tab, right: right)
            XCTAssertEqual(drop, .join("n", placement: right ? .right : .left, monitorScopeId: scope))
            try applyWorkspaceSidebarPinnedTabDrop(pin, drop)
            // Pin p (window 1) goes on the half pointed at: right of n's window 2, or left of it.
            XCTAssertEqual(pin.allLeafWindowsRecursive.map(\.windowId), right ? [2, 1] : [1, 2])
            XCTAssertTrue(tab.allLeafWindowsRecursive.isEmpty, "The tab came over whole")
            XCTAssertEqual(pins(), ["p"], "The pin stays pinned")
            XCTAssertEqual(workspaceSidebarOrganizationStore.state.workspaces["p"], pinOrder, "Its appearance and place too")
            XCTAssertTrue(focus.workspace === pin, "Focus is on the pin, on the tab's display")
            WorkspaceSidebarTabSplitHoverController.shared.reset()
        }
    }

    func testThePreviewShowsTheTabsHalfAndThePinThatTakesItIn() async throws {
        let (pin, tab) = try pinAndTab()
        let drop = try await pausedDrop(pin, onto: tab, right: true)
        let preview = workspaceSidebarPinnedTabDropPreview(pin, drop: drop)
        XCTAssertEqual(preview.targetWorkspaceName, "n", "The tab's half lights up")
        XCTAssertEqual(preview.targetPlacement, .right)
        XCTAssertEqual(preview.receivingPinnedTabName, "p", "And the pin that takes it in")
        XCTAssertEqual(preview.targetMonitorScopeId, scope, "On that list's display")
        XCTAssertEqual(workspaceSidebarTabDropLabelText(for: preview), "Tile into Pinned Tab")
        XCTAssertNil(workspaceSidebarTabDropLabelText(for: workspaceSidebarPinnedTabDropPreview(pin, drop: nil)))
        XCTAssertNil(preview.sourceOnly.receivingPinnedTabName, "Panels that don't show the drop don't light the pin")
        XCTAssertEqual(workspaceSidebarPinnedTabDropUndoTitle(drop), "Tile into Pinned Tab")
    }

    /// Review: with the default normalization, which turns a container nested in one split the same
    /// way, a tab split side by side still shows side by side once it joins, and one stacked stays
    /// stacked.
    func testASplitTabJoinsWholeAndKeepsItsLayout() async throws {
        for stacked in [false, true] {
            try await setUp()
            config.enableNormalizationFlattenContainers = true
            config.enableNormalizationOppositeOrientationForNestedContainers = true
            let (pin, tab) = try pinAndTab()
            _ = TestWindow.new(id: 3, parent: tab.rootTilingContainer)
            _ = TestWindow.new(id: 4, parent: pin.rootTilingContainer)
            if stacked { tab.rootTilingContainer.changeOrientation(.v) }
            let drop = try await pausedDrop(pin, onto: tab, right: true)
            await runWorkspaceSidebarSession(undoTitle: workspaceSidebarPinnedTabDropUndoTitle(drop)) {
                try applyWorkspaceSidebarPinnedTabDrop(pin, drop)
            }?.value
            let root = pin.rootTilingContainer
            XCTAssertEqual(root.orientation, .h, "Side by side with the pin")
            XCTAssertEqual(pin.allLeafWindowsRecursive.map(\.windowId), [2, 3, 1, 4], "The tab on the pin's left, in order")
            if stacked {
                let joined = try XCTUnwrap(root.children.first as? TilingContainer, "A stacked tab joins as one piece")
                XCTAssertEqual(joined.orientation, .v, "Still stacked")
                XCTAssertEqual(joined.allLeafWindowsRecursive.map(\.windowId), [2, 3])
            } else {
                XCTAssertTrue(root.children.allSatisfy { $0 is Window }, "Side by side, its windows sit beside the pin's")
            }
            XCTAssertEqual(pins(), ["p"])
        }
    }

    /// Review: a tab whose window used last floats still joins its tiled window as a split; the
    /// floating one floats over the pin.
    func testAFloatingWindowUsedLastDoesntMakeTheTiledOneFloat() async throws {
        let (pin, tab) = try pinAndTab()
        let floating = TestWindow.new(id: 9, parent: tab)
        XCTAssertTrue(floating.isFloating)
        XCTAssertTrue(floating.focusWindow())
        XCTAssertTrue(tab.mostRecentWindowRecursive === floating)
        let drop = try await pausedDrop(pin, onto: tab, right: true)
        try applyWorkspaceSidebarPinnedTabDrop(pin, drop)
        XCTAssertEqual(pin.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId), [2, 1], "The tiled window splits with the pin")
        XCTAssertTrue(floating.isFloating)
        XCTAssertTrue(floating.parent === pin, "The floating one floats over the pin")
        XCTAssertTrue(focus.windowOrNil === floating, "The window used last keeps focus")
    }

    /// Review: leaving the tab, for another target or for nowhere, starts the pause over.
    func testLeavingTheTabStartsThePauseOver() async throws {
        let (pin, tab) = try pinAndTab()
        _ = drop(pin, onto: tab, right: true)
        try await Task.sleep(for: .milliseconds(320))
        XCTAssertNotNil(drop(pin, onto: tab, right: true), "Armed")
        let gap = WorkspaceSidebarDropTarget(kind: .tabGap(projectId: tab.projectId, monitorScopeId: scope,
            gap: .init(workspaceName: tab.name, isAfter: true)), rect: rowRect)
        _ = workspaceSidebarPinnedTabDrop(pin, target: gap, point: CGPoint(x: 100, y: 135))
        XCTAssertNil(drop(pin, onto: tab, right: true), "Back from a gap, it needs a new pause")

        let surface = RowSurface(target: row(for: tab, scope: scope))
        WorkspaceSidebarTemporaryDropSurfaces.shared.register(surface)
        let pointer = CGPoint(x: 150, y: 110)
        WorkspaceSidebarDragSessions.shared.noteLeftMouseDown()
        updateSidebarPinnedTabDrag("p", pointer: pointer)
        try await Task.sleep(for: .milliseconds(350))
        updateSidebarPinnedTabDrag("p", pointer: pointer)
        XCTAssertNotNil(TrayMenuModel.shared.workspaceSidebarDropPreview, "Armed over the tab")
        WorkspaceSidebarTemporaryDropSurfaces.shared.unregister(surface)
        updateSidebarPinnedTabDrag("p", pointer: pointer)
        WorkspaceSidebarTemporaryDropSurfaces.shared.register(surface)
        defer { WorkspaceSidebarTemporaryDropSurfaces.shared.unregister(surface) }
        updateSidebarPinnedTabDrag("p", pointer: pointer)
        XCTAssertNil(TrayMenuModel.shared.workspaceSidebarDropPreview, "Back from nowhere, it needs a new pause")
        cancelActiveSidebarPinnedTabDrag()
    }

    /// Review: a rested pointer sends no events; the pause's own wake shows the join.
    func testThePauseShowsTheJoinWithoutAnotherPointerEvent() async throws {
        let (_, tab) = try pinAndTab()
        let surface = RowSurface(target: row(for: tab, scope: scope))
        WorkspaceSidebarTemporaryDropSurfaces.shared.register(surface)
        defer { WorkspaceSidebarTemporaryDropSurfaces.shared.unregister(surface) }
        WorkspaceSidebarDragSessions.shared.noteLeftMouseDown()
        updateSidebarPinnedTabDrag("p", pointer: CGPoint(x: 150, y: 110))
        XCTAssertNil(TrayMenuModel.shared.workspaceSidebarDropPreview)
        try await waitUntil { TrayMenuModel.shared.workspaceSidebarDropPreview?.receivingPinnedTabName == "p" }
        cancelActiveSidebarPinnedTabDrag()
    }

    func testAnEmptyPinTakesTheTabIn() async throws {
        let (_, tab) = try pinAndTab()
        let empty = Workspace.get(byName: "empty")
        try setWorkspaceSidebarTabFavorite(empty, true)
        let drop = try await pausedDrop(empty, onto: tab, right: false)
        try applyWorkspaceSidebarPinnedTabDrop(empty, drop)
        XCTAssertEqual(empty.allLeafWindowsRecursive.map(\.windowId), [2])
        XCTAssertEqual(workspaceSidebarOrganizationStore.state.workspaces["empty"]?.isFavorite, true)
    }

    func testTabsThatCantJoinAreOfferedNothing() async throws {
        let (pin, tab) = try pinAndTab()
        // Another pin rearranges instead, as before.
        let other = Workspace.get(byName: "q")
        _ = TestWindow.new(id: 5, parent: other.rootTilingContainer)
        try setWorkspaceSidebarTabFavorite(other, true)
        let ontoPin = try await pausedDropOrNil(pin, onto: other, right: true)
        XCTAssertNil(ontoPin, "A pinned tab in the list isn't joined")
        // An empty tab has nothing to tile.
        let empty = Workspace.get(byName: "blank")
        let ontoEmpty = try await pausedDropOrNil(pin, onto: empty, right: true)
        XCTAssertNil(ontoEmpty)
        // A search result takes no reorder, so nothing at all.
        let searchResult = WorkspaceSidebarDropTarget(kind: .workspace(tab.name), rect: rowRect, acceptsSides: true)
        XCTAssertNil(workspaceSidebarPinnedTabDrop(pin, target: searchResult, point: CGPoint(x: 150, y: 110)))
    }

    func testUndoPutsBothTabsBack() async throws {
        let (pin, tab) = try pinAndTab()
        let drop = try await pausedDrop(pin, onto: tab, right: true)
        await runWorkspaceSidebarSession(undoTitle: workspaceSidebarPinnedTabDropUndoTitle(drop)) {
            try applyWorkspaceSidebarPinnedTabDrop(pin, drop)
        }?.value
        XCTAssertEqual(pin.allLeafWindowsRecursive.map(\.windowId), [2, 1])
        await runWorkspaceSidebarSession { try WorkspaceSidebarTabUndo.shared.undo() }?.value
        XCTAssertEqual(pin.allLeafWindowsRecursive.map(\.windowId), [1], "The pin has its own window back")
        XCTAssertEqual(Workspace.existing(byName: "n")?.allLeafWindowsRecursive.map(\.windowId), [2], "And the tab its own")
        XCTAssertEqual(pins(), ["p"])
    }

    /// The release makes the drop the preview showed, through the real drag: none before the pause.
    func testTheReleaseMakesTheJoinShownAndNothingBeforeThePause() async throws {
        let (pin, tab) = try pinAndTab()
        let surface = RowSurface(target: row(for: tab, scope: scope))
        WorkspaceSidebarTemporaryDropSurfaces.shared.register(surface)
        defer { WorkspaceSidebarTemporaryDropSurfaces.shared.unregister(surface) }
        let pointer = CGPoint(x: 150, y: 110)

        WorkspaceSidebarDragSessions.shared.noteLeftMouseDown()
        updateSidebarPinnedTabDrag("p", pointer: pointer)
        XCTAssertNil(TrayMenuModel.shared.workspaceSidebarDropPreview, "Before the pause, nothing is shown")
        finishSidebarPinnedTabDrag("p", pointer: pointer)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(tab.allLeafWindowsRecursive.map(\.windowId), [2], "Released before the pause: nothing moved")
        XCTAssertEqual(pins(), ["p"], "And the pin didn't come down")

        WorkspaceSidebarDragSessions.shared.noteLeftMouseDown()
        updateSidebarPinnedTabDrag("p", pointer: pointer)
        try await Task.sleep(for: .milliseconds(350))
        updateSidebarPinnedTabDrag("p", pointer: pointer)
        XCTAssertEqual(TrayMenuModel.shared.workspaceSidebarDropPreview?.receivingPinnedTabName, "p")
        finishSidebarPinnedTabDrag("p", pointer: pointer)
        try await waitUntil { pin.allLeafWindowsRecursive.count == 2 }
        XCTAssertEqual(pin.allLeafWindowsRecursive.map(\.windowId), [2, 1])
    }

    // MARK: Displays

    /// D8: a shared pin that lives on another display comes to the tab's display, as a click
    /// brings it, and tiles there. The tab never leaves its display.
    func testASharedPinFromAnotherDisplayComesToTheTabsDisplay() async throws {
        let (left, right) = twoDisplays()
        config.workspaceSidebar.sharePinnedTabs = true
        let (pin, tab) = try pinAndTab()
        pin.preferredMonitorPoint = right.rect.topLeftCorner
        tab.preferredMonitorPoint = left.rect.topLeftCorner
        let other = Workspace.get(byName: "r")
        _ = TestWindow.new(id: 7, parent: other.rootTilingContainer)
        other.preferredMonitorPoint = right.rect.topLeftCorner
        XCTAssertTrue(right.setActiveWorkspace(pin))
        XCTAssertTrue(left.setActiveWorkspace(tab))
        let leftList = workspaceSidebarMonitorScopeId(for: left)
        let drop = try await pausedDrop(pin, onto: tab, right: true, scope: leftList)
        try applyWorkspaceSidebarPinnedTabDrop(pin, drop, pinGridIsShared: true)
        XCTAssertTrue(left.activeWorkspace === pin, "The pin came to the tab's display")
        XCTAssertFalse(right.activeWorkspace === pin, "Its old display shows another tab")
        XCTAssertEqual(pin.preferredMonitorPoint, left.rect.topLeftCorner, "Its new display is recorded")
        XCTAssertEqual(pin.allLeafWindowsRecursive.map(\.windowId), [2, 1])
        XCTAssertEqual(pin.workspaceMonitor.rect, left.rect, "The tab's window stayed on its display")
    }

    func testAPinHeldToAnotherDisplayIsOfferedNoJoin() async throws {
        let (left, right) = twoDisplays()
        let (pin, tab) = try pinAndTab()
        pin.preferredMonitorPoint = right.rect.topLeftCorner
        tab.preferredMonitorPoint = left.rect.topLeftCorner
        XCTAssertTrue(right.setActiveWorkspace(pin))
        XCTAssertTrue(left.setActiveWorkspace(tab))
        config.workspaceToMonitorForceAssignment[pin.name] = [.secondary]
        let held = try await pausedDropOrNil(pin, onto: tab, right: true, scope: workspaceSidebarMonitorScopeId(for: left))
        XCTAssertNil(held)
        XCTAssertThrowsError(try joinWorkspaceTabIntoPinnedTab("n", pin: pin, placement: .right))
        XCTAssertEqual(tab.allLeafWindowsRecursive.map(\.windowId), [2], "Nothing moved")
        XCTAssertTrue(right.activeWorkspace === pin)
    }

    func testATabHeldToItsOwnDisplayStillJoinsAPinThere() async throws {
        let (pin, tab) = try pinAndTab()
        config.workspaceToMonitorForceAssignment[tab.name] = [.main]
        let drop = try await pausedDrop(pin, onto: tab, right: false)
        try applyWorkspaceSidebarPinnedTabDrop(pin, drop)
        XCTAssertEqual(pin.allLeafWindowsRecursive.map(\.windowId), [1, 2])
    }

    /// Review: a drop released on a display's own sidebar must still find the tab on that display
    /// when it runs; a display gone by then takes nothing.
    func testAJoinWhoseDisplayWentAwayChangesNothing() async throws {
        let (left, right) = twoDisplays()
        let (pin, tab) = try pinAndTab()
        pin.preferredMonitorPoint = left.rect.topLeftCorner
        tab.preferredMonitorPoint = left.rect.topLeftCorner
        XCTAssertTrue(left.setActiveWorkspace(tab))
        let leftList = workspaceSidebarMonitorScopeId(for: left)
        let drop = try await pausedDrop(pin, onto: tab, right: true, scope: leftList)
        setMonitorsForTests([right])
        XCTAssertThrowsError(try applyWorkspaceSidebarPinnedTabDrop(pin, drop))
        XCTAssertEqual(tab.allLeafWindowsRecursive.map(\.windowId), [2], "Nothing moved")
        XCTAssertEqual(pin.allLeafWindowsRecursive.map(\.windowId), [1])

        // The display still there, but the tab moved off it: the join isn't made somewhere else.
        setMonitorsForTests([left, right])
        Workspace.reconcileWorkspaceState()
        XCTAssertTrue(placeWorkspaceTabOnDisplay(tab, right))
        XCTAssertEqual(tab.workspaceMonitor.rect, right.rect)
        try applyWorkspaceSidebarPinnedTabDrop(pin, drop)
        XCTAssertEqual(tab.allLeafWindowsRecursive.map(\.windowId), [2], "Not joined on another display")
    }

    /// Review: Undo of a join across displays puts the pin back on its display, and the tab on its.
    func testUndoAcrossDisplaysPutsBothTabsAndDisplaysBack() async throws {
        let (left, right) = twoDisplays()
        config.workspaceSidebar.sharePinnedTabs = true
        let (pin, tab) = try pinAndTab()
        pin.preferredMonitorPoint = right.rect.topLeftCorner
        tab.preferredMonitorPoint = left.rect.topLeftCorner
        XCTAssertTrue(right.setActiveWorkspace(pin))
        XCTAssertTrue(left.setActiveWorkspace(tab))
        let drop = try await pausedDrop(pin, onto: tab, right: false, scope: workspaceSidebarMonitorScopeId(for: left))
        await runWorkspaceSidebarSession(undoTitle: workspaceSidebarPinnedTabDropUndoTitle(drop)) {
            try applyWorkspaceSidebarPinnedTabDrop(pin, drop, pinGridIsShared: true)
        }?.value
        XCTAssertTrue(left.activeWorkspace === pin)
        await runWorkspaceSidebarSession { try WorkspaceSidebarTabUndo.shared.undo() }?.value
        XCTAssertTrue(right.activeWorkspace === pin, "The pin is back on its display")
        XCTAssertEqual(pin.preferredMonitorPoint, right.rect.topLeftCorner)
        XCTAssertEqual(pin.allLeafWindowsRecursive.map(\.windowId), [1])
        let restored = try XCTUnwrap(Workspace.existing(byName: "n"))
        XCTAssertEqual(restored.allLeafWindowsRecursive.map(\.windowId), [2])
        XCTAssertEqual(restored.workspaceMonitor.rect, left.rect, "And the tab on its")
    }

    /// Review: after joining, an ordinary tab goes, as any tab whose last window moves into another
    /// does; a saved one stays, greyed.
    func testAfterJoiningAnOrdinaryTabGoesAndASavedOneStays() async throws {
        for saved in [false, true] {
            try await setUp()
            let (pin, tab) = try pinAndTab()
            if saved { try saveWorkspaceSidebarIdentity(tab) }
            let drop = try await pausedDrop(pin, onto: tab, right: true)
            await runWorkspaceSidebarSession(undoTitle: workspaceSidebarPinnedTabDropUndoTitle(drop)) {
                try applyWorkspaceSidebarPinnedTabDrop(pin, drop)
            }?.value
            XCTAssertTrue(tab.allLeafWindowsRecursive.isEmpty)
            let kept = Workspace.existing(byName: "n").map { !$0.isArchived } ?? false
            print("PIN-TILING afterlife saved=\(saved) kept=\(kept)")
            XCTAssertEqual(kept, saved, saved ? "A saved tab stays" : "An ordinary tab goes")
        }
    }

    // MARK: Fixtures

    private let scope = "monitor:0.0,0.0"
    private let rowRect = Rect(topLeftX: 0, topLeftY: 100, width: 200, height: 36)

    /// Pinned tab p with window 1, hidden; tab n with window 2, on screen.
    private func pinAndTab() throws -> (pin: Workspace, tab: Workspace) {
        let pin = Workspace.get(byName: "p")
        _ = TestWindow.new(id: 1, parent: pin.rootTilingContainer)
        let tab = Workspace.get(byName: "n")
        _ = TestWindow.new(id: 2, parent: tab.rootTilingContainer)
        try setWorkspaceSidebarTabFavorite(pin, true)
        XCTAssertTrue(tab.workspaceMonitor.setActiveWorkspace(tab))
        return (pin, tab)
    }

    private func row(for tab: Workspace, scope: String) -> WorkspaceSidebarDropTarget {
        WorkspaceSidebarDropTarget(kind: .workspace(tab.name), rect: rowRect, acceptsSides: true,
            tabReorderDestination: .init(projectId: tab.projectId, monitorScopeId: scope, collectionId: nil))
    }

    private func drop(_ pin: Workspace, onto tab: Workspace, right: Bool, scope: String? = nil) -> WorkspaceSidebarPinnedTabDrop? {
        workspaceSidebarPinnedTabDrop(pin, target: row(for: tab, scope: scope ?? self.scope),
            point: CGPoint(x: right ? 150 : 50, y: 110))
    }

    /// The drop once the pointer has rested over the tab for the pause.
    private func pausedDrop(_ pin: Workspace, onto tab: Workspace, right: Bool,
                            scope: String? = nil) async throws -> WorkspaceSidebarPinnedTabDrop {
        let drop = try await pausedDropOrNil(pin, onto: tab, right: right, scope: scope)
        return try XCTUnwrap(drop)
    }

    private func pausedDropOrNil(_ pin: Workspace, onto tab: Workspace, right: Bool,
                                 scope: String? = nil) async throws -> WorkspaceSidebarPinnedTabDrop? {
        _ = drop(pin, onto: tab, right: right, scope: scope)
        try await Task.sleep(for: .milliseconds(320))
        defer { WorkspaceSidebarTabSplitHoverController.shared.reset() }
        return drop(pin, onto: tab, right: right, scope: scope)
    }

    private func pins() -> [String] { workspacePinnedTabs(in: workspaceProjectDefaultId).map(\.name) }

    private func twoDisplays() -> (left: Monitor, right: Monitor) {
        let left = WorkspaceSidebarDragTestMonitor(monitorAppKitNsScreenScreensId: 1, name: "Left",
            rect: Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080),
            visibleRect: Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080), isMain: true)
        let right = WorkspaceSidebarDragTestMonitor(monitorAppKitNsScreenScreensId: 2, name: "Right",
            rect: Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080),
            visibleRect: Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080), isMain: false)
        setMonitorsForTests([left, right])
        Workspace.reconcileWorkspaceState()
        return (left, right)
    }

    private func waitUntil(_ condition: () -> Bool, timeout: Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// A list surface whose one target is a tab's row, wherever the pointer is on it.
@MainActor
private final class RowSurface: WorkspaceSidebarTemporaryDropSurface {
    let surfaceRef: WorkspaceSidebarSurfaceRef = .dropDestination(generation: 41)
    let stackingOrder = 1
    let dropDestination: WorkspaceSidebarDropDestinationIdentity? = .init(monitorScopeId: "monitor:0.0,0.0")
    let target: WorkspaceSidebarDropTarget

    init(target: WorkspaceSidebarDropTarget) { self.target = target }

    func surfaceRectNormalized(containing point: CGPoint) -> Rect? { target.rect.contains(point) ? target.rect : nil }
    func dropTarget(atNormalizedPoint _: CGPoint, hitSlop _: NSEdgeInsets, includesTabGaps _: Bool) -> WorkspaceSidebarDropTarget? {
        target
    }
}
