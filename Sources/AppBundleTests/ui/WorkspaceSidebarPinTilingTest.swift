import AppKit
@testable import AppBundle
import Common
import XCTest

/// Tabs mode: a pinned tile with one window dragged onto a tab in the list, and paused there, splits its
/// window with that tab, on the half it was dropped on. The tab stays an ordinary tab, and the pin stays
/// pinned in its place, lending its window, grey. An empty pin takes in a tab with one window instead.
/// Moving across a tab without the pause does nothing: only the gaps between tabs, and New Tab, unpin it.
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

    func testAPinPausedOverATabSplitsItsWindowWithItOnTheHalfPointedAt() async throws {
        for right in [false, true] {
            try await setUp()
            let (pin, tab) = try pinAndTab()
            let pinOrder = workspaceSidebarOrganizationStore.state.workspaces["p"]?.pinOrder
            let drop = try await pausedDrop(pin, onto: tab, right: right)
            XCTAssertEqual(drop, .join("n", placement: right ? .right : .left,
                operation: .lend(.init(try XCTUnwrap(pin.anyLeafWindowRecursive))), monitorScopeId: scope),
                "What it does is shown with the pin's own window")
            try applyWorkspaceSidebarPinnedTabDrop(pin, drop)
            // Pin p's window 1 goes on the half pointed at: right of n's window 2, or left of it.
            XCTAssertEqual(tab.allLeafWindowsRecursive.map(\.windowId), right ? [2, 1] : [1, 2])
            XCTAssertFalse(workspaceSidebarIsPinned(tab), "The split is an ordinary tab")
            XCTAssertTrue(pin.allLeafWindowsRecursive.isEmpty, "The pin isn't a pinned split")
            XCTAssertEqual(workspaceSidebarLentWindow(of: pin)?.windowId, 1, "It lends its window, grey")
            XCTAssertEqual(pins(), ["p"], "The pin stays pinned")
            XCTAssertEqual(workspaceSidebarOrganizationStore.state.workspaces["p"]?.pinOrder, pinOrder, "In its place")
            XCTAssertTrue(focus.workspace === tab, "Focus is on the split, with the pin's window")
            XCTAssertEqual(focus.windowOrNil?.windowId, 1)
            WorkspaceSidebarTabSplitHoverController.shared.reset()
        }
    }

    func testThePreviewShowsTheTabsHalfAsForAnyTab() async throws {
        let (pin, tab) = try pinAndTab()
        let drop = try await pausedDrop(pin, onto: tab, right: true)
        let preview = workspaceSidebarPinnedTabDropPreview(pin, drop: drop)
        XCTAssertEqual(preview.targetWorkspaceName, "n", "The tab's half lights up")
        XCTAssertEqual(preview.targetPlacement, .right)
        XCTAssertNil(preview.receivingPinnedTabName, "The pin takes nothing in")
        XCTAssertEqual(preview.targetMonitorScopeId, scope, "On that list's display")
        XCTAssertNil(workspaceSidebarTabDropLabelText(for: preview), "The split's own label")
        XCTAssertEqual(workspaceSidebarPinnedTabDropUndoTitle(drop), "Split Tabs")
        // An empty pin takes the tab in, and lights up.
        let empty = Workspace.get(byName: "empty")
        try setWorkspaceSidebarTabFavorite(empty, true)
        let fill = try await pausedDrop(empty, onto: tab, right: true)
        let filling = workspaceSidebarPinnedTabDropPreview(empty, drop: fill)
        XCTAssertEqual(filling.receivingPinnedTabName, "empty")
        XCTAssertEqual(workspaceSidebarTabDropLabelText(for: filling), "Tile into Pin")
        XCTAssertNil(filling.sourceOnly.receivingPinnedTabName, "Panels that don't show the drop don't light the pin")
        XCTAssertEqual(workspaceSidebarPinnedTabDropUndoTitle(fill), "Tile into Pinned Tab")
    }

    /// A pin's window splitting with a split tab joins that split, which keeps its layout: side by
    /// side, its windows sit beside the pin's; stacked, it stays stacked, beside it.
    func testAPinsWindowJoinsASplitTabWhichKeepsItsLayout() async throws {
        for stacked in [false, true] {
            try await setUp()
            config.enableNormalizationFlattenContainers = true
            config.enableNormalizationOppositeOrientationForNestedContainers = true
            let (pin, tab) = try pinAndTab()
            _ = TestWindow.new(id: 3, parent: tab.rootTilingContainer)
            if stacked { tab.rootTilingContainer.changeOrientation(.v) }
            let drop = try await pausedDrop(pin, onto: tab, right: true)
            await runWorkspaceSidebarSession(undoTitle: workspaceSidebarPinnedTabDropUndoTitle(drop)) {
                try applyWorkspaceSidebarPinnedTabDrop(pin, drop)
            }?.value
            let root = tab.rootTilingContainer
            XCTAssertEqual(root.orientation, .h, "Side by side with the pin's window")
            XCTAssertEqual(tab.allLeafWindowsRecursive.map(\.windowId), [2, 3, 1], "The pin's window on the right")
            if stacked {
                let kept = try XCTUnwrap(root.children.first as? TilingContainer, "The stack stays one piece")
                XCTAssertEqual(kept.orientation, .v, "Still stacked")
                XCTAssertEqual(kept.allLeafWindowsRecursive.map(\.windowId), [2, 3])
            } else {
                XCTAssertTrue(root.children.allSatisfy { $0 is Window }, "Side by side, the pin's window sits beside them")
            }
            XCTAssertFalse(workspaceSidebarIsPinned(tab))
            XCTAssertEqual(pins(), ["p"])
        }
    }

    /// A pinned split is made only from a split tab's menu: an empty pin takes in no split tab, and a
    /// pinned split, or a pin lending its window, splits with no tab.
    func testNoPinnedSplitComesFromAPinOverATab() async throws {
        let (pin, tab) = try pinAndTab()
        _ = TestWindow.new(id: 3, parent: tab.rootTilingContainer)
        let empty = Workspace.get(byName: "empty")
        try setWorkspaceSidebarTabFavorite(empty, true)
        let fill = try await pausedDropOrNil(empty, onto: tab, right: true)
        XCTAssertNil(fill, "An empty pin takes in no split tab")
        let other = Workspace.get(byName: "o")
        _ = TestWindow.new(id: 5, parent: other.rootTilingContainer)
        _ = TestWindow.new(id: 4, parent: pin.rootTilingContainer)
        let fromSplit = try await pausedDropOrNil(pin, onto: other, right: true)
        XCTAssertNil(fromSplit, "A pinned split splits with no tab")
        XCTAssertEqual(pin.allLeafWindowsRecursive.map(\.windowId), [1, 4])
        XCTAssertEqual(other.allLeafWindowsRecursive.map(\.windowId), [5])
    }

    /// Review: a tab whose window used last floats still takes the pin's window as a split beside its
    /// tiled one; the floating one stays floating where it is.
    func testATabsFloatingWindowStaysFloatingWhenThePinsWindowJoins() async throws {
        let (pin, tab) = try pinAndTab()
        let floating = TestWindow.new(id: 9, parent: tab)
        XCTAssertTrue(floating.isFloating)
        XCTAssertTrue(floating.focusWindow())
        XCTAssertTrue(tab.mostRecentWindowRecursive === floating)
        let drop = try await pausedDrop(pin, onto: tab, right: true)
        try applyWorkspaceSidebarPinnedTabDrop(pin, drop)
        XCTAssertEqual(tab.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId), [2, 1], "Split with the tiled window")
        XCTAssertTrue(floating.isFloating)
        XCTAssertTrue(floating.parent === tab, "The floating one stays in its tab")
        XCTAssertEqual(focus.windowOrNil?.windowId, 1, "The pin's window comes forward, as a dropped window does")
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

    /// Review: a rested pointer sends no events; the pause's own wake shows the split.
    func testThePauseShowsTheSplitWithoutAnotherPointerEvent() async throws {
        let (_, tab) = try pinAndTab()
        let surface = RowSurface(target: row(for: tab, scope: scope))
        WorkspaceSidebarTemporaryDropSurfaces.shared.register(surface)
        defer { WorkspaceSidebarTemporaryDropSurfaces.shared.unregister(surface) }
        WorkspaceSidebarDragSessions.shared.noteLeftMouseDown()
        updateSidebarPinnedTabDrag("p", pointer: CGPoint(x: 150, y: 110))
        XCTAssertNil(TrayMenuModel.shared.workspaceSidebarDropPreview)
        try await waitUntil {
            TrayMenuModel.shared.workspaceSidebarDropPreview?.targetWorkspaceName == "n"
                && TrayMenuModel.shared.workspaceSidebarDropPreview?.targetPlacement == .right
        }
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
        XCTAssertEqual(tab.allLeafWindowsRecursive.map(\.windowId), [2, 1])
        await runWorkspaceSidebarSession { try WorkspaceSidebarTabUndo.shared.undo() }?.value
        XCTAssertEqual(pin.allLeafWindowsRecursive.map(\.windowId), [1], "The pin has its own window back")
        XCTAssertNil(workspaceSidebarLentWindow(of: pin), "Not grey any more")
        XCTAssertEqual(Workspace.existing(byName: "n")?.allLeafWindowsRecursive.map(\.windowId), [2], "And the tab its own")
        XCTAssertEqual(pins(), ["p"])
    }

    /// The release makes the drop the preview showed, through the real drag: none before the pause.
    func testTheReleaseMakesTheSplitShownAndNothingBeforeThePause() async throws {
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
        XCTAssertEqual(TrayMenuModel.shared.workspaceSidebarDropPreview?.targetWorkspaceName, "n")
        XCTAssertNil(TrayMenuModel.shared.workspaceSidebarDropPreview?.receivingPinnedTabName)
        // V3: the label has a place clear of the dragged tile.
        XCTAssertEqual(TrayMenuModel.shared.workspaceSidebarDropPreview?.targetLabelSlot?.isHidden, false)
        finishSidebarPinnedTabDrag("p", pointer: pointer)
        try await waitUntil { tab.allLeafWindowsRecursive.count == 2 }
        XCTAssertEqual(tab.allLeafWindowsRecursive.map(\.windowId), [2, 1])
        XCTAssertEqual(workspaceSidebarLentWindow(of: pin)?.windowId, 1)
    }

    // MARK: Displays

    /// D8, now the pin stays: a shared pin's window that lives on another display comes to the tab's
    /// display, into the tab. The tab never leaves its display, and the pin keeps its own.
    func testASharedPinsWindowFromAnotherDisplayGoesToTheTabOnItsDisplay() async throws {
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
        XCTAssertTrue(left.activeWorkspace === tab, "The split shows on the tab's display")
        XCTAssertEqual(tab.allLeafWindowsRecursive.map(\.windowId), [2, 1])
        XCTAssertEqual(tab.workspaceMonitor.rect, left.rect, "The tab stayed on its display")
        XCTAssertEqual(pin.preferredMonitorPoint, right.rect.topLeftCorner, "The pin didn't move")
        XCTAssertEqual(workspaceSidebarLentWindow(of: pin)?.windowId, 1)
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
        XCTAssertEqual(tab.allLeafWindowsRecursive.map(\.windowId), [2], "Nothing moved")
        XCTAssertTrue(right.activeWorkspace === pin)
    }

    func testATabHeldToItsOwnDisplayStillTakesAPinsWindow() async throws {
        let (pin, tab) = try pinAndTab()
        config.workspaceToMonitorForceAssignment[tab.name] = [.main]
        let drop = try await pausedDrop(pin, onto: tab, right: false)
        try applyWorkspaceSidebarPinnedTabDrop(pin, drop)
        XCTAssertEqual(tab.allLeafWindowsRecursive.map(\.windowId), [1, 2])
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

    /// V1 (VM smoke): the layouts after a tiling drop move its split's weights, if only by float noise.
    /// That's no change: the drop's Undo stays through the refreshes that follow, and still puts the
    /// tabs, the display and the order back.
    func testUndoOfATilingDropOutlastsTheLayoutsAfterIt() async throws {
        // Wide enough to leave the tab 784 points beside the sidebar, as in the VM.
        setMonitorsForTests([oneDisplay(width: 1088)])
        Workspace.reconcileWorkspaceState()
        let (pin, tab) = try pinAndTab()
        _ = TestWindow.new(id: 4, parent: tab.rootTilingContainer)
        // The tab laid out on the display first, at 392 and 392.
        XCTAssertTrue(tab.workspaceMonitor.setActiveWorkspace(tab))
        try await tab.layoutWorkspace()
        let listBefore = orderedWorkspaces(in: workspaceProjectDefaultId).map(\.name).filter { ["p", "n"].contains($0) }
        let drop = try await pausedDrop(pin, onto: tab, right: true)
        await runWorkspaceSidebarSession(undoTitle: workspaceSidebarPinnedTabDropUndoTitle(drop)) {
            try applyWorkspaceSidebarPinnedTabDrop(pin, drop)
        }?.value
        XCTAssertEqual(tab.allLeafWindowsRecursive.count, 3)
        let title = try XCTUnwrap(WorkspaceSidebarTabUndo.shared.title)
        let weights = tab.rootTilingContainer.children.map { $0.getWeight(.h) }
        XCTAssertEqual(weights.reduce(0, +), 784, accuracy: 0.001, "\(weights)")
        for _ in 0 ..< 3 { try await runRefreshSessionBlocking(.globalObserver("test")) }
        let laidOut = tab.rootTilingContainer.children.map { $0.getWeight(.h) }
        XCTAssertNotEqual(laidOut, weights, "The layouts after it moved the weights, if only by float noise")
        XCTAssertEqual(laidOut.count, weights.count)
        for (a, b) in zip(laidOut, weights) { XCTAssertEqual(a, b, accuracy: 1e-6) }
        XCTAssertEqual(WorkspaceSidebarTabUndo.shared.title, title, "Undo is still there")

        await runWorkspaceSidebarSession { try WorkspaceSidebarTabUndo.shared.undo() }?.value
        XCTAssertEqual(pin.allLeafWindowsRecursive.map(\.windowId), [1], "The pin has its window back")
        XCTAssertEqual(Workspace.existing(byName: "n")?.allLeafWindowsRecursive.map(\.windowId), [2, 4], "And the tab its own")
        XCTAssertEqual(orderedWorkspaces(in: workspaceProjectDefaultId).map(\.name).filter { ["p", "n"].contains($0) }, listBefore)
        XCTAssertEqual(pins(), ["p"])
    }

    /// V1, the window onto the pin, made by the pins' rule now: the window is the whole of its tab, which
    /// takes the split, beside the pin's window, and the pin lends it. The split is two equal halves,
    /// which lay out exactly; the layouts after it move its weights by no more than float noise, and
    /// the drop's Undo stays through them, and puts the pin's window back in the pin. Three windows,
    /// whose thirds the layouts do move by float noise, are the pin-onto-tab case above.
    func testUndoOfAWindowDroppedOnAPinOutlastsTheLayoutsAfterIt() async throws {
        setMonitorsForTests([oneDisplay(width: 1088)])
        Workspace.reconcileWorkspaceState()
        let (pin, tab) = try pinAndTab()
        // The tab laid out on the display first, as in the VM.
        XCTAssertTrue(tab.workspaceMonitor.setActiveWorkspace(tab))
        try await tab.layoutWorkspace()
        let listBefore = orderedWorkspaces(in: workspaceProjectDefaultId).map(\.name).filter { ["p", "n"].contains($0) }
        await queueWorkspaceSidebarDrop(2, subject: .window, target: .workspace(pin.name), placement: .right,
            intent: .physical)?.value
        XCTAssertEqual(tab.allLeafWindowsRecursive.map(\.windowId), [1, 2], "The split is in n, 2 on the right of p's window")
        XCTAssertEqual(pin.allLeafWindowsRecursive, [])
        XCTAssertEqual(workspaceSidebarLentWindow(of: pin)?.windowId, 1)
        let title = try XCTUnwrap(WorkspaceSidebarTabUndo.shared.title)
        let weights = tab.rootTilingContainer.children.map { $0.getWeight(.h) }
        for _ in 0 ..< 3 { try await runRefreshSessionBlocking(.globalObserver("test")) }
        XCTAssertEqual(weights.reduce(0, +), 784, accuracy: 0.001, "\(weights)")
        let laidOut = tab.rootTilingContainer.children.map { $0.getWeight(.h) }
        XCTAssertEqual(laidOut.count, weights.count)
        for (a, b) in zip(laidOut, weights) { XCTAssertEqual(a, b, accuracy: 1e-6, "\(weights) -> \(laidOut)") }
        XCTAssertEqual(WorkspaceSidebarTabUndo.shared.title, title, "Undo is still there")

        await runWorkspaceSidebarSession { try WorkspaceSidebarTabUndo.shared.undo() }?.value
        XCTAssertEqual(pin.allLeafWindowsRecursive.map(\.windowId), [1], "The pin has its window back")
        XCTAssertNil(workspaceSidebarLentWindow(of: pin))
        XCTAssertEqual(Workspace.existing(byName: "n")?.allLeafWindowsRecursive.map(\.windowId), [2])
        XCTAssertEqual(orderedWorkspaces(in: workspaceProjectDefaultId).map(\.name).filter { ["p", "n"].contains($0) }, listBefore)
        XCTAssertEqual(pins(), ["p"])
    }

    // MARK: Review V1 F6: the release's operation, made with the windows it was shown with

    /// A pin's window shown going to a tab is the one that goes: if the pin's window changed before the
    /// session runs, nothing is made, and the pin isn't made to take the tab in instead.
    func testAPinsSplitShownWithItsWindowIsntMadeWithAnother() async throws {
        let (pin, tab) = try pinAndTab()
        let shown = try await releasedDrop("p", over: tab)
        XCTAssertEqual(shown, .join("n", placement: .right, operation: .lend(.init(try XCTUnwrap(Window.get(byId: 1)))),
            monitorScopeId: scope))
        // Released: before its session runs, the pin's window closes and another is opened in it.
        try XCTUnwrap(Window.get(byId: 1)).unbindFromParent()
        _ = TestWindow.new(id: 9, parent: pin.rootTilingContainer)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(tab.allLeafWindowsRecursive.map(\.windowId), [2], "Nothing joined the tab")
        XCTAssertEqual(pin.allLeafWindowsRecursive.map(\.windowId), [9])
        XCTAssertNil(workspaceSidebarLentWindow(of: pin))
    }

    /// An empty pin shown taking a tab in takes that tab's window, or nothing: not one opened in the pin
    /// since, which would make it lend instead, nor another window of the tab.
    func testAnEmptyPinShownTakingATabInIsntMadeOnceEitherChanged() async throws {
        for changed in ["pin", "tab"] {
            try await setUp()
            let (_, tab) = try pinAndTab()
            let empty = Workspace.get(byName: "empty")
            try setWorkspaceSidebarTabFavorite(empty, true)
            let shown = try await releasedDrop("empty", over: tab)
            XCTAssertEqual(shown, .join("n", placement: .right, operation: .fill(.init(try XCTUnwrap(Window.get(byId: 2)))),
                monitorScopeId: scope), changed)
            if changed == "pin" {
                _ = TestWindow.new(id: 9, parent: empty.rootTilingContainer)
            } else {
                try XCTUnwrap(Window.get(byId: 2)).unbindFromParent()
                _ = TestWindow.new(id: 8, parent: tab.rootTilingContainer)
            }
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(empty.allLeafWindowsRecursive.map(\.windowId), changed == "pin" ? [9] : [], changed)
            XCTAssertEqual(tab.allLeafWindowsRecursive.map(\.windowId), changed == "pin" ? [2] : [8], changed)
            XCTAssertNil(workspaceSidebarLentWindow(of: empty), changed)
        }
    }

    /// V1: a change made after a tiling drop, not by its layouts, still clears its Undo, so it never
    /// puts things back over newer work: a window resized, or one opened in the pin.
    func testAChangeAfterATilingDropStillClearsItsUndo() async throws {
        for change in ["resize", "new window"] {
            try await setUp()
            let (pin, tab) = try pinAndTab()
            let drop = try await pausedDrop(pin, onto: tab, right: true)
            await runWorkspaceSidebarSession(undoTitle: workspaceSidebarPinnedTabDropUndoTitle(drop)) {
                try applyWorkspaceSidebarPinnedTabDrop(pin, drop)
            }?.value
            XCTAssertNotNil(WorkspaceSidebarTabUndo.shared.title)
            if change == "resize" {
                let window = try XCTUnwrap(tab.allLeafWindowsRecursive.first)
                window.setWeight(.h, window.getWeight(.h) + 40)
            } else {
                _ = TestWindow.new(id: 9, parent: pin.rootTilingContainer)
            }
            await updateWorkspaceSidebarModel()
            XCTAssertNil(WorkspaceSidebarTabUndo.shared.title, change)
            await runWorkspaceSidebarSession { try WorkspaceSidebarTabUndo.shared.undo() }?.value
            XCTAssertEqual(tab.allLeafWindowsRecursive.map(\.windowId), [2, 1], "\(change): nothing put back")
            XCTAssertEqual(pin.allLeafWindowsRecursive.map(\.windowId), change == "resize" ? [] : [9])
        }
    }

    /// V3 (VM smoke): the join's label fits half a tab at the sidebar's default width, where the old
    /// one was cut off, and has a place there clear of the dragged tile.
    func testTheJoinLabelFitsHalfATab() {
        // A tab spans the sidebar less its 10-point insets.
        let row = CGFloat(defaultConfig.workspaceSidebar.width - 20)
        let inset: CGFloat = 2 * workspaceSidebarTabDropLabelInset + 2 * workspaceSidebarTabGroupInset
        let room: CGFloat = row / 2 - inset
        XCTAssertLessThanOrEqual(workspaceSidebarTabDropLabelWidth(workspaceSidebarPinTilingLabel), room)
        XCTAssertGreaterThan(workspaceSidebarTabDropLabelWidth("Tile into Pinned Tab"), room, "The old label didn't fit")
        for pointX in stride(from: row / 2 + 4, through: row - 4, by: 8) {
            let slot = workspaceSidebarTabDropLabelSlot(pointX: 10 + pointX, targetMinX: 10, targetMaxX: 10 + row,
                placement: .right, labelWidth: workspaceSidebarTabDropLabelWidth(workspaceSidebarPinTilingLabel),
                clearance: workspaceSidebarDragImageHalfWidth(.appIcon(size: 22)) + 4)
            XCTAssertEqual(slot?.isHidden, false, "pointer at \(pointX)")
        }
    }

    /// Review: Undo of a split across displays puts the pin's window back in the pin, on its display,
    /// and the tab's on its.
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
        XCTAssertEqual(tab.allLeafWindowsRecursive.map(\.windowId), [1, 2])
        await runWorkspaceSidebarSession { try WorkspaceSidebarTabUndo.shared.undo() }?.value
        XCTAssertTrue(right.activeWorkspace === pin, "The pin is back on its display")
        XCTAssertEqual(pin.preferredMonitorPoint, right.rect.topLeftCorner)
        XCTAssertEqual(pin.allLeafWindowsRecursive.map(\.windowId), [1])
        let restored = try XCTUnwrap(Workspace.existing(byName: "n"))
        XCTAssertEqual(restored.allLeafWindowsRecursive.map(\.windowId), [2])
        XCTAssertEqual(restored.workspaceMonitor.rect, left.rect, "And the tab on its")
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

    /// Drags pin `name` over `tab`'s row, right half, rests there, and releases: the drop shown then.
    /// Its session hasn't run yet when this returns.
    private func releasedDrop(_ name: String, over tab: Workspace) async throws -> WorkspaceSidebarPinnedTabDrop? {
        let surface = RowSurface(target: row(for: tab, scope: scope))
        WorkspaceSidebarTemporaryDropSurfaces.shared.register(surface)
        defer { WorkspaceSidebarTemporaryDropSurfaces.shared.unregister(surface) }
        let pointer = CGPoint(x: 150, y: 110)
        WorkspaceSidebarDragSessions.shared.noteLeftMouseDown()
        updateSidebarPinnedTabDrag(name, pointer: pointer)
        try await Task.sleep(for: .milliseconds(350))
        updateSidebarPinnedTabDrag(name, pointer: pointer)
        let shown = try XCTUnwrap(Workspace.existing(byName: name)).flatMap { pin in
            workspaceSidebarPinnedTabDrop(pin, target: row(for: tab, scope: scope), point: pointer)
        }
        finishSidebarPinnedTabDrag(name, pointer: pointer)
        return shown
    }


    private func oneDisplay(width: CGFloat) -> Monitor {
        WorkspaceSidebarDragTestMonitor(monitorAppKitNsScreenScreensId: 1, name: "Main",
            rect: Rect(topLeftX: 0, topLeftY: 0, width: width, height: 768),
            visibleRect: Rect(topLeftX: 0, topLeftY: 0, width: width, height: 768), isMain: true)
    }

    private func twoDisplays(leftWidth: CGFloat = 1920, rightWidth: CGFloat = 1920) -> (left: Monitor, right: Monitor) {
        let left = WorkspaceSidebarDragTestMonitor(monitorAppKitNsScreenScreensId: 1, name: "Left",
            rect: Rect(topLeftX: 0, topLeftY: 0, width: leftWidth, height: 1080),
            visibleRect: Rect(topLeftX: 0, topLeftY: 0, width: leftWidth, height: 1080), isMain: true)
        let right = WorkspaceSidebarDragTestMonitor(monitorAppKitNsScreenScreensId: 2, name: "Right",
            rect: Rect(topLeftX: leftWidth, topLeftY: 0, width: rightWidth, height: 1080),
            visibleRect: Rect(topLeftX: leftWidth, topLeftY: 0, width: rightWidth, height: 1080), isMain: false)
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
