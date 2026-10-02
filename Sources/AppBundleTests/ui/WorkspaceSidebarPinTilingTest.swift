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
        XCTAssertEqual(workspaceSidebarTabDropLabelText(for: preview), "Tile into Pin")
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

    /// Review rounds 2 and 3: a split joining side by side keeps its windows' sizes once laid out,
    /// into an empty pin and beside one or two of the pin's windows. Weights are lengths, and layout
    /// adds the same amount to each child, so the split ends with the 1/(n + 1) of the row one piece
    /// would, and each of the pin's windows gives up what it would to one more window.
    func testASplitKeepsItsWindowsSizesWhenItJoins() async throws {
        for pinWindows in 0 ... 2 {
            try await setUp()
            config.enableNormalizationFlattenContainers = true
            config.enableNormalizationOppositeOrientationForNestedContainers = true
            let tab = Workspace.get(byName: "n")
            let width = tab.workspaceMonitor.visibleRectPaddedByOuterGaps.width
            let wide = TestWindow.new(id: 2, parent: tab.rootTilingContainer)
            let narrow = TestWindow.new(id: 3, parent: tab.rootTilingContainer)
            wide.setWeight(.h, width * 0.75)
            narrow.setWeight(.h, width * 0.25)
            let pin = Workspace.get(byName: pinWindows == 0 ? "empty" : "p")
            let own = (0 ..< pinWindows).map { TestWindow.new(id: UInt32(10 + $0), parent: pin.rootTilingContainer) }
            try await pin.layoutWorkspace()
            try setWorkspaceSidebarTabFavorite(pin, true)
            XCTAssertTrue(tab.workspaceMonitor.setActiveWorkspace(tab))
            try await tab.layoutWorkspace()
            XCTAssertEqual(wide.getWeight(.h), width * 0.75, accuracy: 0.5, "Laid out as set")
            let drop = try await pausedDrop(pin, onto: tab, right: true)
            try applyWorkspaceSidebarPinnedTabDrop(pin, drop)
            try await pin.layoutWorkspace()
            let share = width / CGFloat(pinWindows + 1)
            XCTAssertEqual(pin.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId), [2, 3] + own.map(\.windowId))
            XCTAssertEqual(wide.getWeight(.h), share * 0.75, accuracy: 0.5, "\(pinWindows) pin windows: its windows keep their sizes")
            XCTAssertEqual(narrow.getWeight(.h), share * 0.25, accuracy: 0.5, "\(pinWindows) pin windows")
            for window in own {
                XCTAssertEqual(window.getWeight(.h), share, accuracy: 0.5, "The pin's windows give up what one more window takes")
            }
            for window in pin.rootTilingContainer.allLeafWindowsRecursive {
                XCTAssertGreaterThan(try XCTUnwrap(window.lastAppliedLayoutPhysicalRect).width, 0)
            }
        }
    }

    /// Review round 4: a stacked pin is wrapped in a side-by-side row whose one child starts at 1.
    /// Laid out, the stack still keeps half the display, and the split the other half at 3:1.
    func testAStackedPinMakesRoomForASplitAsForOneWindow() async throws {
        config.enableNormalizationFlattenContainers = true
        config.enableNormalizationOppositeOrientationForNestedContainers = true
        let (wide, narrow) = threeToOneTab()
        let pin = Workspace.get(byName: "p")
        let own = [TestWindow.new(id: 1, parent: pin.rootTilingContainer), TestWindow.new(id: 4, parent: pin.rootTilingContainer)]
        pin.rootTilingContainer.changeOrientation(.v)
        try await pin.layoutWorkspace()
        try setWorkspaceSidebarTabFavorite(pin, true)
        let tab = Workspace.get(byName: "n")
        XCTAssertTrue(tab.workspaceMonitor.setActiveWorkspace(tab))
        try await tab.layoutWorkspace()
        let width = tilingWidth(of: tab.workspaceMonitor)
        let drop = try await pausedDrop(pin, onto: tab, right: true)
        try applyWorkspaceSidebarPinnedTabDrop(pin, drop)
        try await pin.layoutWorkspace()
        let root = pin.rootTilingContainer
        XCTAssertEqual(root.orientation, .h)
        let stack = try XCTUnwrap(root.children.last as? TilingContainer, "The pin's stack, beside the tab")
        XCTAssertEqual(stack.allLeafWindowsRecursive.map(\.windowId), own.map(\.windowId))
        XCTAssertEqual(stack.getWeight(.h), width / 2, accuracy: 0.5, "The stack keeps half, as beside one more window")
        XCTAssertEqual(wide.getWeight(.h), width * 3 / 8, accuracy: 0.5, "The split takes the other half at 3:1")
        XCTAssertEqual(narrow.getWeight(.h), width / 8, accuracy: 0.5)
    }

    /// Review round 4: a tab last laid out on a wider display, then not again, still fills an empty
    /// pin at 3:1, not with its old lengths pushed off the display.
    func testASplitLaidOutWiderFillsAnEmptyPin() async throws {
        let tab = Workspace.get(byName: "n")
        let width = tilingWidth(of: tab.workspaceMonitor)
        let (wide, narrow) = threeToOneTab(width: width * 2)
        let pin = Workspace.get(byName: "empty")
        try setWorkspaceSidebarTabFavorite(pin, true)
        XCTAssertTrue(tab.workspaceMonitor.setActiveWorkspace(tab))
        let drop = try await pausedDrop(pin, onto: tab, right: true)
        try applyWorkspaceSidebarPinnedTabDrop(pin, drop)
        try await pin.layoutWorkspace()
        XCTAssertEqual(pin.allLeafWindowsRecursive.map(\.windowId), [2, 3])
        XCTAssertEqual(wide.getWeight(.h), width * 0.75, accuracy: 0.5)
        XCTAssertEqual(narrow.getWeight(.h), width * 0.25, accuracy: 0.5)
    }

    /// Review round 4: a shared pin laid out on a wider display, brought to the tab's, fits it: half
    /// for the pin's window and half for the split at 3:1, none of it pushed off.
    func testAPinFromAWiderDisplayMakesRoomForASplitOnTheTabsDisplay() async throws {
        let (left, right) = twoDisplays(leftWidth: 1200, rightWidth: 2400)
        config.workspaceSidebar.sharePinnedTabs = true
        let (wide, narrow) = threeToOneTab(width: tilingWidth(of: left))
        let tab = Workspace.get(byName: "n")
        let pin = Workspace.get(byName: "p")
        let own = TestWindow.new(id: 1, parent: pin.rootTilingContainer)
        try setWorkspaceSidebarTabFavorite(pin, true)
        pin.preferredMonitorPoint = right.rect.topLeftCorner
        tab.preferredMonitorPoint = left.rect.topLeftCorner
        XCTAssertTrue(right.setActiveWorkspace(pin))
        XCTAssertTrue(left.setActiveWorkspace(tab))
        try await pin.layoutWorkspace()
        try await tab.layoutWorkspace()
        XCTAssertEqual(own.getWeight(.h), tilingWidth(of: right), accuracy: 0.5, "Laid out on the wider display")
        let drop = try await pausedDrop(pin, onto: tab, right: true, scope: workspaceSidebarMonitorScopeId(for: left))
        try applyWorkspaceSidebarPinnedTabDrop(pin, drop, pinGridIsShared: true)
        XCTAssertTrue(left.activeWorkspace === pin)
        try await pin.layoutWorkspace()
        let width = tilingWidth(of: left)
        XCTAssertEqual(pin.allLeafWindowsRecursive.map(\.windowId), [2, 3, 1])
        XCTAssertEqual(own.getWeight(.h), width / 2, accuracy: 0.5)
        XCTAssertEqual(wide.getWeight(.h), width * 3 / 8, accuracy: 0.5)
        XCTAssertEqual(narrow.getWeight(.h), width / 8, accuracy: 0.5)
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
        // V3: the label has a place clear of the dragged tile.
        XCTAssertEqual(TrayMenuModel.shared.workspaceSidebarDropPreview?.targetLabelSlot?.isHidden, false)
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

    /// V1 (VM smoke): the layouts after a tiling drop spread float noise over its split, three
    /// thirds of 784 summing to 784.0000000000001. That's no change: the drop's Undo stays through
    /// the refreshes that follow, for a join into a pin and a window dropped on a pin alike, and
    /// still puts both tabs, the display and the order back.
    func testUndoOfATilingDropOutlastsTheLayoutsAfterIt() async throws {
        for joinsTheTab in [true, false] {
            try await setUp()
            // Wide enough to leave the pin 784 points beside the sidebar, as in the VM.
            setMonitorsForTests([oneDisplay(width: 1088)])
            Workspace.reconcileWorkspaceState()
            let (pin, tab) = try pinAndTab()
            _ = TestWindow.new(id: 4, parent: pin.rootTilingContainer)
            // The pin laid out on the display first, at 392 and 392, as it was in the VM.
            let monitor = tab.workspaceMonitor
            XCTAssertTrue(monitor.setActiveWorkspace(pin))
            try await pin.layoutWorkspace()
            XCTAssertTrue(monitor.setActiveWorkspace(tab))
            let listBefore = orderedWorkspaces(in: workspaceProjectDefaultId).map(\.name).filter { ["p", "n"].contains($0) }
            if joinsTheTab {
                let drop = try await pausedDrop(pin, onto: tab, right: true)
                await runWorkspaceSidebarSession(undoTitle: workspaceSidebarPinnedTabDropUndoTitle(drop)) {
                    try applyWorkspaceSidebarPinnedTabDrop(pin, drop)
                }?.value
            } else {
                await queueWorkspaceSidebarDrop(2, subject: .window, target: .workspace(pin.name), placement: .right,
                    intent: .physical)?.value
            }
            XCTAssertEqual(pin.allLeafWindowsRecursive.count, 3, "\(joinsTheTab)")
            let title = try XCTUnwrap(WorkspaceSidebarTabUndo.shared.title)
            let weights = pin.rootTilingContainer.children.map { $0.getWeight(.h) }
            XCTAssertEqual(weights.reduce(0, +), 784, accuracy: 0.001, "\(weights)")
            for _ in 0 ..< 3 { try await runRefreshSessionBlocking(.globalObserver("test")) }
            let laidOut = pin.rootTilingContainer.children.map { $0.getWeight(.h) }
            XCTAssertNotEqual(laidOut, weights, "The layouts after it moved the weights, if only by float noise")
            XCTAssertEqual(laidOut.count, weights.count)
            for (a, b) in zip(laidOut, weights) { XCTAssertEqual(a, b, accuracy: 1e-6) }
            XCTAssertEqual(WorkspaceSidebarTabUndo.shared.title, title, "\(joinsTheTab): Undo is still there")

            await runWorkspaceSidebarSession { try WorkspaceSidebarTabUndo.shared.undo() }?.value
            XCTAssertEqual(pin.allLeafWindowsRecursive.map(\.windowId), [1, 4], "The pin has its windows back")
            XCTAssertEqual(Workspace.existing(byName: "n")?.allLeafWindowsRecursive.map(\.windowId), [2], "And the tab its own")
            XCTAssertEqual(Workspace.existing(byName: "n")?.workspaceMonitor.rect, pin.workspaceMonitor.rect)
            XCTAssertEqual(orderedWorkspaces(in: workspaceProjectDefaultId).map(\.name).filter { ["p", "n"].contains($0) }, listBefore)
            XCTAssertEqual(pins(), ["p"])
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
                let window = try XCTUnwrap(pin.allLeafWindowsRecursive.first)
                window.setWeight(.h, window.getWeight(.h) + 40)
            } else {
                _ = TestWindow.new(id: 9, parent: pin.rootTilingContainer)
            }
            await updateWorkspaceSidebarModel()
            XCTAssertNil(WorkspaceSidebarTabUndo.shared.title, change)
            await runWorkspaceSidebarSession { try WorkspaceSidebarTabUndo.shared.undo() }?.value
            XCTAssertEqual(pin.allLeafWindowsRecursive.map(\.windowId).sorted(), (change == "resize" ? [1, 2] : [1, 2, 9]),
                "\(change): nothing put back")
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

    /// Tab n, split side by side at 3:1 across `width`, the tiling width of its display by default.
    private func threeToOneTab(width: CGFloat? = nil) -> (wide: Window, narrow: Window) {
        let tab = Workspace.get(byName: "n")
        let width = width ?? tilingWidth(of: tab.workspaceMonitor)
        let wide = TestWindow.new(id: 2, parent: tab.rootTilingContainer)
        let narrow = TestWindow.new(id: 3, parent: tab.rootTilingContainer)
        wide.setWeight(.h, width * 0.75)
        narrow.setWeight(.h, width * 0.25)
        return (wide, narrow)
    }

    private func tilingWidth(of monitor: Monitor) -> CGFloat {
        workspaceStandardTilingRect(monitor.visibleRectPaddedByOuterGaps).width
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
