import AppKit
@testable import AppBundle
import Common
import XCTest

/// Tabs mode: several chosen tabs dragged together. A drag that starts on a chosen tab carries all of
/// them, whole and in order, to a gap, a group or the pins, on this display or another's list. It
/// moves them all or none, with one Undo, and offers no split, New Tab or screen drop.
@MainActor
final class WorkspaceSidebarTabBatchDragTest: XCTestCase {
    private let selection = WorkspaceSidebarTabSelection.shared
    /// The registry holds its surfaces weakly, as the panels that show them do.
    private var surfaces: [ListSurface] = []

    override func setUp() async throws {
        setUpWorkspacesForTests()
        workspaceSidebarOrganizationStore = .init()
        selection.clear()
        TrayMenuModel.shared.isEnabled = true
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
    }

    override func tearDown() async throws {
        clearActiveWorkspaceSidebarDrag()
        clearPendingWindowDragIntent()
        cancelManipulatedWithMouseState()
        cancelActiveSidebarPinnedTabDrag()
        selection.clear()
        WorkspaceSidebarTabSplitHoverController.shared.reset()
        WorkspaceSidebarTabUndo.shared.clear()
        WorkspaceSidebarTemporaryDropSurfaces.shared.removeAll()
        surfaces = []
        setWorkspaceSidebarDragSourceScopeIdForTests(nil)
        clearWorkspaceSidebarDropPreview()
        MousePointerTracker.shared.reset()
        workspaceSidebarOrganizationStore = .init()
        setMonitorsForTests(nil)
        config = defaultConfig
        try await super.tearDown()
    }

    // MARK: What a drag carries

    func testADragFromAChosenTabCarriesEveryChosenTabInOrder() throws {
        _ = try displaysOfTabs()
        choose(["b", "a"])
        XCTAssertEqual(selection.names, ["a", "b"], "In the order shown")
        let batch = try beginDrag(from: "b")
        XCTAssertEqual(batch.names, ["a", "b"])
        XCTAssertEqual(batch.primary, "b")
        XCTAssertEqual(batch.kind, .tabs)
        XCTAssertEqual(WorkspaceSidebarTabDragState.shared.draggedTabs, ["a", "b"], "Both dim")
        XCTAssertEqual(workspaceSidebarSourcePreview(sourceWindow: try window(of: "b"), subject: .window).label, "2 Tabs")
        XCTAssertTrue(workspaceSidebarDragCarriesBatch())
        // Choosing another tab during the drag changes nothing it carries.
        choose(["c"])
        beginActiveWorkspaceSidebarDrag(windowId: try window(of: "b").windowId, subject: .window)
        XCTAssertEqual(currentActiveWorkspaceSidebarDrag()?.batch?.names, ["a", "b"])
        clearActiveWorkspaceSidebarDrag()
        XCTAssertEqual(WorkspaceSidebarTabDragState.shared.draggedTabs, [], "Nothing dims after the drag")
        XCTAssertFalse(workspaceSidebarDragCarriesBatch())
    }

    func testADragFromATabNotChosenCarriesJustThatTabAndKeepsTheChoice() throws {
        _ = try displaysOfTabs()
        choose(["a", "b"])
        beginActiveWorkspaceSidebarDrag(windowId: try window(of: "c").windowId, subject: .window)
        XCTAssertNil(currentActiveWorkspaceSidebarDrag()?.batch)
        XCTAssertEqual(WorkspaceSidebarTabDragState.shared.draggedTabs, [])
        XCTAssertFalse(workspaceSidebarDragCarriesBatch(), "Its screen drop is as before")
        clearActiveWorkspaceSidebarDrag()
        XCTAssertEqual(selection.names, ["a", "b"])
        // One tab chosen isn't a batch either.
        selection.clear()
        choose(["a"])
        beginActiveWorkspaceSidebarDrag(windowId: try window(of: "a").windowId, subject: .window)
        XCTAssertNil(currentActiveWorkspaceSidebarDrag()?.batch)
    }

    /// D2: one window dragged out of a chosen split tab still carries the chosen tabs, whole.
    func testOneWindowOfAChosenSplitCarriesTheWholeTabs() async throws {
        let (_, _, tabs) = try displaysOfTabs()
        let other = TestWindow.new(id: 9, parent: tabs["a"]!.rootTilingContainer)
        choose(["a", "b"])
        beginActiveWorkspaceSidebarDrag(windowId: other.windowId, subject: .window)
        let batch = try XCTUnwrap(currentActiveWorkspaceSidebarDrag()?.batch)
        clearActiveWorkspaceSidebarDrag()
        let gap = gapKind(after: "c", on: scope(0))
        await queueWorkspaceSidebarBatchDrop(batch, target: gap, intent: .physical)?.value
        XCTAssertEqual(listOrder(), ["c", "a", "b", "r"])
        XCTAssertEqual(tabs["a"]!.allLeafWindowsRecursive.map(\.windowId), [1, 9], "The split moved whole")
    }

    /// V4 (VM smoke): an icon drag of chosen tabs says how many, above the icon, which the pointer
    /// sits on, so the pointer, covering what's below and right of its tip, leaves the count clear.
    /// A single tab's drag image is as it was.
    func testABatchDragShowsHowManyTabsWhereThePointerDoesntCoverIt() throws {
        _ = try displaysOfTabs()
        choose(["a", "b", "c"])
        _ = try beginDrag(from: "b")
        let style = WorkspaceSidebarDragPreviewStyle.appIcon(size: 22)
        let preview = workspaceSidebarSourcePreview(sourceWindow: try window(of: "b"), subject: .window)
        XCTAssertEqual(preview.batchTabCount, 3)
        XCTAssertEqual(preview.label, "3 Tabs")
        let size = windowDragCursorProxySize(preview: preview, style: style)
        let icon = windowDragCursorProxySize(label: preview.label, style: style)
        XCTAssertGreaterThanOrEqual(size.width, workspaceSidebarTabDropLabelWidth("3 Tabs"), "The count fits")
        XCTAssertEqual(size.height, icon.height + windowDragCursorProxyBatchLabelSpacing + windowDragCursorProxyBatchLabelHeight)
        let pointer = try XCTUnwrap(windowDragCursorProxyPointerFromBottom(preview: preview, style: style))
        XCTAssertEqual(pointer, icon.height / 2, "On the icon")
        XCTAssertLessThan(pointer + 2, size.height - windowDragCursorProxyBatchLabelHeight, "Below the count")
        let frame = windowDragCursorProxyFrame(mouseScreenPoint: .zero, proxySize: size, pointerFromBottom: pointer)
        XCTAssertEqual(frame.size, size)

        clearActiveWorkspaceSidebarDrag()
        selection.clear()
        _ = try beginDrag(from: "c", batch: false)
        let single = workspaceSidebarSourcePreview(sourceWindow: try window(of: "c"), subject: .window)
        XCTAssertNil(single.batchTabCount)
        XCTAssertEqual(windowDragCursorProxySize(preview: single, style: style), windowDragCursorProxySize(label: single.label, style: style))
        XCTAssertNil(windowDragCursorProxyPointerFromBottom(preview: single, style: style), "Centered on the pointer, as before")
        XCTAssertEqual(windowDragCursorProxySize(preview: single, style: .row), windowDragCursorProxySize(label: single.label, style: .row))
    }

    // MARK: Between tabs
    // MARK: Between tabs

    /// Alan's report: a and b chosen, dragged onto the other display's list (the one its rail opens).
    /// Both go there, in order, and the tab dragged comes forward there.
    func testChosenTabsDroppedOnAnotherDisplaysListAllGoThere() async throws {
        let (left, right, tabs) = try displaysOfTabs()
        choose(["a", "b"])
        let batch = try beginDrag(from: "a")
        clearActiveWorkspaceSidebarDrag()
        let target = try listTarget(gapKind(after: "r", on: scope(1)), listing: right)
        XCTAssertTrue(isActionableWorkspaceSidebarBatchDropTarget(batch, target: target.kind))
        let intent = try XCTUnwrap(WorkspaceSidebarDropIntent.captured(for: target))
        await queueWorkspaceSidebarBatchDrop(batch, target: target.kind, intent: intent)?.value
        XCTAssertEqual(tabs["a"]!.workspaceMonitor.rect, right.rect)
        XCTAssertEqual(tabs["b"]!.workspaceMonitor.rect, right.rect, "Listed there, though hidden")
        XCTAssertEqual(listOrder(), ["c", "r", "a", "b"])
        XCTAssertTrue(right.activeWorkspace === tabs["a"], "The tab dragged shows there")
        XCTAssertTrue(focus.workspace === tabs["a"])
        XCTAssertFalse(left.activeWorkspace === tabs["a"] || left.activeWorkspace === tabs["b"], "Its display shows another tab")
        XCTAssertEqual(selection.names, [], "D3: the choice is done with")
        XCTAssertEqual(WorkspaceSidebarTabUndo.shared.title, "Undo Move 2 Tabs")

        await runWorkspaceSidebarSession { try WorkspaceSidebarTabUndo.shared.undo() }?.value
        XCTAssertEqual(tabs["a"]!.workspaceMonitor.rect, left.rect, "One Undo puts both back")
        XCTAssertEqual(tabs["b"]!.workspaceMonitor.rect, left.rect)
        XCTAssertEqual(listOrder(), ["a", "b", "c", "r"])
    }

    /// The real drag, released on the list: the batch's drop is the one shown, and it moves them all.
    func testTheReleaseOnAnotherDisplaysListMovesEveryChosenTab() async throws {
        let (_, right, tabs) = try displaysOfTabs()
        choose(["a", "b"])
        let target = try listTarget(gapKind(after: "r", on: scope(1)), listing: right)
        let source = try window(of: "a")
        WorkspaceSidebarDragSessions.shared.noteLeftMouseDown()
        setWorkspaceSidebarDragSourceScopeIdForTests(scope(0))
        updateSidebarWindowDrag(source.windowId, subject: .window, pointer: CGPoint(x: -9000, y: -9000))
        XCTAssertNotNil(currentActiveWorkspaceSidebarDrag()?.batch)
        let point = target.rect.center
        // The preview reads the real pointer in Tabs mode; record what it would have shown here.
        let hit = try XCTUnwrap(workspaceSidebarSurfaceHit(at: point).target)
        WorkspaceSidebarTabSplitHoverController.shared.noteDisplayed(source: source.windowId, hitKind: hit.kind, target: hit,
            placement: nil)
        finishSidebarWindowDrag(pointer: point)
        try await waitUntil { tabs["b"]!.workspaceMonitor.rect == right.rect }
        XCTAssertEqual(tabs["a"]!.workspaceMonitor.rect, right.rect)
        XCTAssertEqual(listOrder(), ["c", "r", "a", "b"])
        XCTAssertEqual(selection.names, [])
    }

    func testChosenTabsDroppedInTheirOwnListGoTogetherInOrder() async throws {
        let (_, _, tabs) = try displaysOfTabs()
        choose(["a", "b"])
        let batch = try beginDrag(from: "b")
        clearActiveWorkspaceSidebarDrag()
        await queueWorkspaceSidebarBatchDrop(batch, target: gapKind(after: "c", on: scope(0)), intent: .physical)?.value
        XCTAssertEqual(listOrder(), ["c", "a", "b", "r"])
        XCTAssertTrue(sortedMonitors[0].activeWorkspace === tabs["a"], "Nothing changed display, so nothing comes forward")

        // D5: dropped in a group's gap, they join that group, as one tab would.
        let group = try workspaceSidebarOrganizationStore.create(projectId: tabs["c"]!.projectId, workspaceNames: ["c"])
        choose(["a", "b"])
        await queueWorkspaceSidebarBatchDrop(batch, target: gapKind(after: "c", on: scope(0), in: group.id), intent: .physical)?.value
        XCTAssertEqual(workspaceSidebarOrganizationStore.collection(containing: "c")?.workspaceNames, ["c", "a", "b"])
    }

    func testABatchIsOfferedNothingWhereItIsOrBesideItself() throws {
        _ = try displaysOfTabs()
        choose(["a", "b"])
        let batch = try beginDrag(from: "a")
        XCTAssertFalse(isActionableWorkspaceSidebarBatchDropTarget(batch, target: gapKind(after: "b", on: scope(0))),
            "Beside one of its own tabs")
        XCTAssertFalse(isActionableWorkspaceSidebarBatchDropTarget(batch, target: gapKind(before: "a", on: scope(0))))
        XCTAssertFalse(isActionableWorkspaceSidebarBatchDropTarget(batch, target: gapKind(before: "c", on: scope(0))),
            "Already there, in that order")
        XCTAssertTrue(isActionableWorkspaceSidebarBatchDropTarget(batch, target: gapKind(after: "c", on: scope(0))))
    }

    /// A batch never splits with a tab: over a row, even after a pause, it goes beside it. Nor does
    /// it open a New Tab, or land on the screen.
    func testABatchIsOfferedNoSplitNewTabOrScreenDrop() async throws {
        let (_, _, tabs) = try displaysOfTabs()
        choose(["a", "b"])
        let batch = try beginDrag(from: "a")
        let row = WorkspaceSidebarDropTarget(kind: .workspace("c"), rect: Rect(topLeftX: 0, topLeftY: 100, width: 200, height: 36),
            acceptsSides: true, tabReorderDestination: .init(projectId: tabs["c"]!.projectId, monitorScopeId: scope(0), collectionId: nil))
        for _ in 0 ..< 2 {
            let resolved = workspaceSidebarBatchDropTarget(row, point: CGPoint(x: 150, y: 130))
            XCTAssertEqual(resolved?.kind, gapKind(after: "c", on: scope(0)), "Beside it, by the nearer edge")
            try await Task.sleep(for: .milliseconds(320))
        }
        XCTAssertEqual(workspaceSidebarBatchDropTarget(row, point: CGPoint(x: 150, y: 105))?.kind, gapKind(before: "c", on: scope(0)))
        for kind: WorkspaceSidebarDropTargetKind in [.workspace("c"), .newWorkspace(projectId: tabs["c"]!.projectId, monitorScopeId: scope(0))] {
            XCTAssertFalse(isActionableWorkspaceSidebarBatchDropTarget(batch, target: kind))
        }
        XCTAssertTrue(workspaceSidebarOwnsDrag(usesBrowserTabs: true, startedInSidebar: true, hasActiveSidebarDrag: true,
            isPointerInSidebar: false, carriesBatch: true), "Over the screen, the batch's drag stays the sidebar's: it drops nothing there")
        XCTAssertFalse(workspaceSidebarOwnsDrag(usesBrowserTabs: true, startedInSidebar: true, hasActiveSidebarDrag: true,
            isPointerInSidebar: false), "A single tab's screen drop is as before")
    }

    // MARK: All or nothing

    func testABatchGoesOnlyWhereAllOfItCan() throws {
        let (left, right, tabs) = try displaysOfTabs()
        choose(["a", "b"])
        let batch = try beginDrag(from: "a")
        config.workspaceToMonitorForceAssignment["b"] = [.main]
        let gap = gapKind(after: "r", on: scope(1))
        XCTAssertFalse(isActionableWorkspaceSidebarBatchDropTarget(batch, target: gap), "b is held to its display")
        XCTAssertThrowsError(try applyWorkspaceSidebarBatchDrop(batch, target: gap))
        XCTAssertEqual(tabs["a"]!.workspaceMonitor.rect, left.rect, "So a stays too")
        XCTAssertNotEqual(tabs["b"]!.workspaceMonitor.rect, right.rect)
        XCTAssertEqual(selection.names, ["a", "b"], "The choice stays after a refusal")
    }

    func testAChosenTabThatChangedMeanwhileMovesNothing() async throws {
        let (_, _, tabs) = try displaysOfTabs()
        choose(["a", "b"])
        let batch = try beginDrag(from: "a")
        let gap = gapKind(after: "c", on: scope(0))
        try setWorkspaceSidebarTabFavorite(tabs["b"]!, true)
        XCTAssertFalse(isActionableWorkspaceSidebarBatchDropTarget(batch, target: gap), "b was pinned")
        XCTAssertFalse(try applyWorkspaceSidebarBatchDrop(batch, target: gap))
        try setWorkspaceSidebarTabFavorite(tabs["b"]!, false)
        removeWorkspaceFromRegistry(tabs["b"]!, reason: .deleted)
        XCTAssertFalse(isActionableWorkspaceSidebarBatchDropTarget(batch, target: gap), "b closed")
        await queueWorkspaceSidebarBatchDrop(batch, target: gap, intent: .physical)?.value
        XCTAssertEqual(listOrder(), ["a", "c", "r"], "a stayed")
    }

    func testABatchForADisplayThatWentAwayMovesNothing() async throws {
        let (left, right, tabs) = try displaysOfTabs()
        choose(["a", "b"])
        let batch = try beginDrag(from: "a")
        clearActiveWorkspaceSidebarDrag()
        let target = try listTarget(gapKind(after: "r", on: scope(1)), listing: right)
        let intent = try XCTUnwrap(WorkspaceSidebarDropIntent.captured(for: target))
        setMonitorsForTests([left])
        await queueWorkspaceSidebarBatchDrop(batch, target: target.kind, intent: intent)?.value
        XCTAssertThrowsError(try applyWorkspaceSidebarBatchDrop(batch, target: target.kind))
        XCTAssertEqual(tabs["a"]!.workspaceMonitor.rect, left.rect)
        XCTAssertEqual(listOrder(), ["a", "b", "c", "r"])
        XCTAssertEqual(selection.names, ["a", "b"])
    }

    /// One tab moves, the next can't: the first goes back too.
    func testAFailurePartwayPutsEveryTabBack() throws {
        let (_, _, tabs) = try displaysOfTabs()
        _ = try workspaceSidebarOrganizationStore.create(projectId: tabs["b"]!.projectId, workspaceNames: ["b"])
        choose(["a", "b"])
        let batch = try beginDrag(from: "a")
        // a moves without a write; b leaves its group, which can't be saved.
        workspaceSidebarOrganizationStore = .init(state: workspaceSidebarOrganizationStore.state, readOnlyReason: "Read-only")
        XCTAssertFalse(try applyWorkspaceSidebarBatchDrop(batch, target: gapKind(after: "c", on: scope(0))))
        XCTAssertEqual(listOrder(), ["a", "b", "c", "r"], "a went back")
        XCTAssertNotNil(workspaceSidebarOrganizationStore.collection(containing: "b"))
    }

    /// Review: saved tabs moved to a display their homes can't name go back there once hidden, so the
    /// batch would end split across displays. It goes back whole instead.
    func testABatchThatWouldEndSplitAcrossDisplaysGoesBackWhole() throws {
        let (laptop, projector) = try savedTabsOnALaptopAndAProjector()
        choose(["a", "b"])
        let batch = try beginDrag(from: "a")
        clearActiveWorkspaceSidebarDrag()
        let gap = gapKind(after: "r", on: workspaceSidebarMonitorScopeId(for: projector))
        XCTAssertFalse(try applyWorkspaceSidebarBatchDrop(batch, target: gap))
        for name in ["a", "b"] {
            XCTAssertEqual(Workspace.existing(byName: name)?.workspaceMonitor.rect, laptop.rect, "\(name) is back where it was")
        }
        XCTAssertEqual(orderedWorkspaces(in: workspaceProjectDefaultId).map(\.name).filter { ["a", "b", "r"].contains($0) },
            ["a", "b", "r"])
    }

    /// Review round 2: a chosen tab already shown on the list's display, though saved elsewhere, can
    /// be hidden there by another one coming over. A group or pin drop then goes back whole too.
    func testABatchWhoseTabAlreadyThereWouldGoBackGoesBackWhole() throws {
        let (laptop, projector) = try savedTabsOnALaptopAndAProjector()
        let group = try workspaceSidebarOrganizationStore.create(projectId: workspaceProjectDefaultId, workspaceNames: ["r"])
        let projectorList = workspaceSidebarMonitorScopeId(for: projector)
        let targets: [WorkspaceSidebarDropTargetKind] = [.tabCollection(group.id, monitorScopeId: projectorList),
            .pinnedTabs(projectId: workspaceProjectDefaultId, gap: nil, monitorScopeId: projectorList)]
        for target in targets {
            // a is brought to the projector, as a click does; its saved home is still the laptop.
            XCTAssertTrue(placeWorkspaceTabOnDisplay(Workspace.get(byName: "a"), projector))
            XCTAssertTrue(Workspace.get(byName: "a").isVisible)
            choose(["a", "b"])
            let batch = try beginDrag(from: "b")
            clearActiveWorkspaceSidebarDrag()
            XCTAssertTrue(isActionableWorkspaceSidebarBatchDropTarget(batch, target: target))
            XCTAssertFalse(try applyWorkspaceSidebarBatchDrop(batch, target: target), "\(target)")
            XCTAssertEqual(Workspace.existing(byName: "a")?.workspaceMonitor.rect, projector.rect, "a is shown where it was")
            XCTAssertEqual(Workspace.existing(byName: "b")?.workspaceMonitor.rect, laptop.rect, "b didn't go")
            XCTAssertEqual(workspaceSidebarOrganizationStore.collection(containing: "r")?.workspaceNames, ["r"])
            XCTAssertEqual(pinOrder(), [])
            selection.clear()
        }
    }

    /// Review: the preview offers a batch drop the dragged tab alone wouldn't make, and never "New Tab".
    func testThePreviewShowsWhereTheBatchGoes() throws {
        let (_, _, tabs) = try displaysOfTabs()
        choose(["a", "c"])
        _ = try beginDrag(from: "a")
        // a alone is already before b; with c, the drop puts c there too.
        previewWorkspaceSidebarDrop(try window(of: "a").windowId, subject: .window, target: gapKind(before: "b", on: scope(0)))
        XCTAssertEqual(TrayMenuModel.shared.workspaceSidebarDropPreview?.targetGap, .init(workspaceName: "b", isAfter: false))
        clearActiveWorkspaceSidebarDrag()
        selection.clear()

        let split = TestWindow.new(id: 9, parent: tabs["a"]!.rootTilingContainer)
        let group = try workspaceSidebarOrganizationStore.create(projectId: tabs["a"]!.projectId, workspaceNames: ["a"])
        choose(["a", "c"])
        beginActiveWorkspaceSidebarDrag(windowId: split.windowId, subject: .window)
        // a alone is already before b; with c, the drop puts c there too.
        let gap = gapKind(before: "b", on: scope(0))
        previewWorkspaceSidebarDrop(split.windowId, subject: .window, target: gap)
        let preview = try XCTUnwrap(TrayMenuModel.shared.workspaceSidebarDropPreview)
        XCTAssertEqual(preview.label, "2 Tabs")
        XCTAssertNotNil(preview.targetGap)
        XCTAssertFalse(preview.separatesFromTab, "Whole tabs move: no New Tab")
        // a is in the group already; c isn't.
        previewWorkspaceSidebarDrop(split.windowId, subject: .window, target: .tabCollection(group.id, monitorScopeId: scope(0)))
        XCTAssertEqual(TrayMenuModel.shared.workspaceSidebarDropPreview?.targetCollectionId, group.id)
        previewWorkspaceSidebarDrop(split.windowId, subject: .window, target: .newWorkspace(projectId: tabs["a"]!.projectId,
            monitorScopeId: scope(0)))
        XCTAssertNil(TrayMenuModel.shared.workspaceSidebarDropPreview, "Nor a New Tab")
    }

    // MARK: Groups and pins

    func testChosenTabsDroppedOnAGroupAllJoinIt() async throws {
        let (_, right, tabs) = try displaysOfTabs()
        let group = try workspaceSidebarOrganizationStore.create(projectId: tabs["r"]!.projectId, workspaceNames: ["r"])
        choose(["a", "b"])
        let batch = try beginDrag(from: "b")
        clearActiveWorkspaceSidebarDrag()
        let target = try listTarget(.tabCollection(group.id, monitorScopeId: scope(1)), listing: right)
        XCTAssertTrue(isActionableWorkspaceSidebarBatchDropTarget(batch, target: target.kind))
        await queueWorkspaceSidebarBatchDrop(batch, target: target.kind,
            intent: try XCTUnwrap(WorkspaceSidebarDropIntent.captured(for: target)))?.value
        XCTAssertEqual(workspaceSidebarOrganizationStore.collection(containing: "a")?.workspaceNames, ["r", "a", "b"])
        XCTAssertEqual(tabs["a"]!.workspaceMonitor.rect, right.rect, "From another display's list, they come to it")
        XCTAssertEqual(tabs["b"]!.workspaceMonitor.rect, right.rect)
        XCTAssertTrue(right.activeWorkspace === tabs["b"], "The tab dragged comes forward")
        XCTAssertEqual(WorkspaceSidebarTabUndo.shared.title, "Undo Move 2 Tabs to Group")
        choose(["a", "b"])
        XCTAssertFalse(isActionableWorkspaceSidebarBatchDropTarget(try beginDrag(from: "a"),
            target: .tabCollection(group.id, monitorScopeId: scope(1))), "Already in it, there")
    }

    func testChosenTabsDroppedOnThePinsAreAllPinnedInOrder() async throws {
        let (left, right, tabs) = try displaysOfTabs()
        try setWorkspaceSidebarTabFavorite(tabs["c"]!, true)
        choose(["a", "b"])
        let batch = try beginDrag(from: "a")
        clearActiveWorkspaceSidebarDrag()
        let pins = WorkspaceSidebarDropTargetKind.pinnedTabs(projectId: tabs["c"]!.projectId,
            gap: .init(workspaceName: "c", isAfter: false), monitorScopeId: scope(0))
        XCTAssertTrue(isActionableWorkspaceSidebarBatchDropTarget(batch, target: pins))
        await queueWorkspaceSidebarBatchDrop(batch, target: pins, intent: .physical)?.value
        XCTAssertEqual(pinOrder(), ["a", "b", "c"])
        XCTAssertEqual(WorkspaceSidebarTabUndo.shared.title, "Undo Pin 2 Tabs")

        // Another display's pins: shared, they stay where they are; otherwise they come over.
        await runWorkspaceSidebarSession { try WorkspaceSidebarTabUndo.shared.undo() }?.value
        XCTAssertEqual(pinOrder(), ["c"])
        for shared in [true, false] {
            config.workspaceSidebar.sharePinnedTabs = shared
            choose(["a", "b"])
            let batch = try beginDrag(from: "a")
            clearActiveWorkspaceSidebarDrag()
            let target = try listTarget(.pinnedTabs(projectId: tabs["c"]!.projectId, gap: nil, monitorScopeId: scope(1)), listing: right)
            var intent = try XCTUnwrap(WorkspaceSidebarDropIntent.captured(for: target))
            intent.pinGridIsShared = workspaceSidebarPinGridIsShared()
            await queueWorkspaceSidebarBatchDrop(batch, target: target.kind, intent: intent)?.value
            // With no pin to go beside, they go after the pins, in their order.
            XCTAssertEqual(pinOrder(), ["c", "a", "b"])
            XCTAssertEqual(tabs["b"]!.workspaceMonitor.rect, shared ? left.rect : right.rect)
            await runWorkspaceSidebarSession { try WorkspaceSidebarTabUndo.shared.undo() }?.value
        }
    }

    /// Review: pinned with no pin to go beside, tabs keep the order shown, even where a group puts
    /// them out of their tab order.
    func testChosenTabsPinnedWithNoPinBesideKeepTheOrderShown() async throws {
        let (_, _, tabs) = try displaysOfTabs()
        _ = try workspaceSidebarOrganizationStore.create(projectId: tabs["c"]!.projectId, workspaceNames: ["c", "a"])
        for name in ["c", "b"] {
            XCTAssertTrue(selection.handleClick(on: name, modifiers: [.command], order: ["c", "a", "b", "r"], active: nil))
        }
        XCTAssertEqual(selection.names, ["c", "b"], "As shown: the group's tabs together")
        let batch = try beginDrag(from: "b")
        clearActiveWorkspaceSidebarDrag()
        await queueWorkspaceSidebarBatchDrop(batch, target: .pinnedTabs(projectId: tabs["c"]!.projectId, gap: nil,
            monitorScopeId: scope(0)), intent: .physical)?.value
        XCTAssertEqual(pinOrder(), ["c", "b"])
    }

    /// D4: pins and tabs chosen together go nowhere, from a row or from a pin's tile.
    func testAChoiceOfPinsAndTabsGoesNowhere() throws {
        let (_, _, tabs) = try displaysOfTabs()
        try setWorkspaceSidebarTabFavorite(tabs["c"]!, true)
        choose(["a", "c"])
        let batch = try beginDrag(from: "a")
        XCTAssertEqual(batch.kind, .mixed)
        let group = try workspaceSidebarOrganizationStore.create(projectId: tabs["r"]!.projectId, workspaceNames: ["r"])
        let kinds: [WorkspaceSidebarDropTargetKind] = [gapKind(after: "b", on: scope(0)),
            .tabCollection(group.id, monitorScopeId: scope(0)),
            .pinnedTabs(projectId: tabs["c"]!.projectId, gap: nil, monitorScopeId: scope(0))]
        for kind in kinds {
            XCTAssertFalse(isActionableWorkspaceSidebarBatchDropTarget(batch, target: kind))
            XCTAssertNil(workspaceSidebarPinnedBatchDrop(batch, target: .init(kind: kind, rect: rowRect), point: rowRect.center))
            XCTAssertFalse(try applyWorkspaceSidebarBatchDrop(batch, target: kind))
        }
        XCTAssertEqual(pinOrder(), ["c"])
        XCTAssertEqual(listOrder(), ["a", "b", "r"])
    }

    func testChosenPinsMoveTogether() async throws {
        let (_, _, tabs) = try displaysOfTabs()
        for name in ["a", "b", "c"] { try setWorkspaceSidebarTabFavorite(tabs[name]!, true) }
        choose(["a", "b"])
        let batch = try XCTUnwrap(WorkspaceSidebarDragBatch(startingWith: "a"))
        XCTAssertEqual(batch.kind, .pins)
        let projectId = tabs["a"]!.projectId
        let pinTarget = { (gap: WorkspaceSidebarTabGap) in
            WorkspaceSidebarDropTarget(kind: .pinnedTabs(projectId: projectId, gap: gap, monitorScopeId: self.scope(0)), rect: self.rowRect)
        }
        XCTAssertNil(workspaceSidebarPinnedBatchDrop(batch, target: pinTarget(.init(workspaceName: "b", isAfter: true)), point: .zero),
            "Beside one of its own")
        XCTAssertNil(workspaceSidebarPinnedBatchDrop(batch, target: pinTarget(.init(workspaceName: "c", isAfter: false)), point: .zero),
            "Already there")
        let drop = try XCTUnwrap(workspaceSidebarPinnedBatchDrop(batch, target: pinTarget(.init(workspaceName: "c", isAfter: true)),
            point: .zero))
        XCTAssertEqual(workspaceSidebarPinnedBatchDropUndoTitle(batch, drop), "Move 2 Tabs")
        XCTAssertTrue(try applyWorkspaceSidebarPinnedBatchDrop(batch, drop))
        XCTAssertEqual(pinOrder(), ["c", "a", "b"])

        // Over a tab in the list, nothing, even after a pause: a batch joins no tab. Nor New Tab.
        let row = WorkspaceSidebarDropTarget(kind: .workspace("r"), rect: rowRect, acceptsSides: true,
            tabReorderDestination: .init(projectId: projectId, monitorScopeId: scope(0), collectionId: nil))
        XCTAssertNil(workspaceSidebarPinnedBatchDrop(batch, target: row, point: rowRect.center))
        try await Task.sleep(for: .milliseconds(320))
        XCTAssertNil(workspaceSidebarPinnedBatchDrop(batch, target: row, point: rowRect.center))
        XCTAssertNil(workspaceSidebarPinnedBatchDrop(batch, target: .init(kind: .newWorkspace(projectId: projectId,
            monitorScopeId: scope(0)), rect: rowRect), point: .zero))

        // Between the list's tabs, both come down, in order; into a group, both join it.
        let list = try XCTUnwrap(workspaceSidebarPinnedBatchDrop(batch, target: .init(kind: gapKind(after: "r", on: scope(0)),
            rect: rowRect), point: .zero))
        XCTAssertEqual(workspaceSidebarPinnedBatchDropUndoTitle(batch, list), "Unpin 2 Tabs")
        XCTAssertTrue(try applyWorkspaceSidebarPinnedBatchDrop(batch, list))
        XCTAssertEqual(pinOrder(), ["c"])
        XCTAssertEqual(listOrder(), ["r", "a", "b"])
        for name in ["a", "b"] { try setWorkspaceSidebarTabFavorite(tabs[name]!, true) }
        let group = try workspaceSidebarOrganizationStore.create(projectId: projectId, workspaceNames: ["r"])
        let grouped = try XCTUnwrap(workspaceSidebarPinnedBatchDrop(batch, target: .init(kind: .tabCollection(group.id,
            monitorScopeId: scope(0)), rect: rowRect), point: .zero))
        XCTAssertTrue(try applyWorkspaceSidebarPinnedBatchDrop(batch, grouped))
        XCTAssertEqual(workspaceSidebarOrganizationStore.collection(containing: "a")?.workspaceNames, ["r", "a", "b"])
        XCTAssertEqual(pinOrder(), ["c"])
    }

    /// Review: a group shows its tabs in tab order, so pins arranged out of it keep their order there.
    func testChosenPinsJoinAGroupInTheirOrder() throws {
        let (_, _, tabs) = try displaysOfTabs()
        for name in ["a", "b"] { try setWorkspaceSidebarTabFavorite(tabs[name]!, true) }
        try pinWorkspaceSidebarTab(tabs["b"]!, beside: .init(workspaceName: "a", isAfter: false))
        XCTAssertEqual(pinOrder(), ["b", "a"])
        for name in ["b", "a"] {
            XCTAssertTrue(selection.handleClick(on: name, modifiers: [.command], order: ["b", "a", "c", "r"], active: nil))
        }
        let batch = try XCTUnwrap(WorkspaceSidebarDragBatch(startingWith: "a"))
        XCTAssertEqual(batch.names, ["b", "a"])
        let group = try workspaceSidebarOrganizationStore.create(projectId: tabs["r"]!.projectId, workspaceNames: ["r"])
        XCTAssertTrue(try applyWorkspaceSidebarPinnedBatchDrop(batch, .group(group.id, monitorScopeId: scope(0))))
        let shown = orderedWorkspaces(in: workspaceProjectDefaultId).map(\.name).filter { ["a", "b", "r"].contains($0) }
        XCTAssertEqual(shown.filter { ["a", "b"].contains($0) }, ["b", "a"], "As they were dragged")
    }

    /// The real drag of a pin's tile, released beside another pin: the chosen pins move with it.
    func testTheReleaseOfAChosenPinMovesTheChosenPins() async throws {
        let (_, _, tabs) = try displaysOfTabs()
        for name in ["a", "b", "c"] { try setWorkspaceSidebarTabFavorite(tabs[name]!, true) }
        choose(["a", "b"])
        let surface = ListSurface(target: .init(kind: .pinnedTabs(projectId: tabs["a"]!.projectId,
            gap: .init(workspaceName: "c", isAfter: true), monitorScopeId: scope(0)), rect: rowRect, surface: ListSurface.ref),
            listing: scope(0))
        register(surface)
        WorkspaceSidebarDragSessions.shared.noteLeftMouseDown()
        updateSidebarPinnedTabDrag("a", pointer: rowRect.center)
        XCTAssertEqual(WorkspaceSidebarTabDragState.shared.draggedTabs, ["a", "b"])
        XCTAssertEqual(TrayMenuModel.shared.workspaceSidebarDropPreview?.label, "2 Tabs")
        XCTAssertEqual(TrayMenuModel.shared.workspaceSidebarDropPreview?.batchTabCount, 2, "V4: the tile's drag image says how many")
        finishSidebarPinnedTabDrag("a", pointer: rowRect.center)
        try await waitUntil { self.pinOrder() == ["c", "a", "b"] }
        XCTAssertEqual(selection.names, [])
        XCTAssertEqual(WorkspaceSidebarTabUndo.shared.title, "Undo Move 2 Tabs")
    }

    // MARK: Single drags

    func testASingleDragWhileOthersAreChosenMovesJustItsTab() async throws {
        let (left, right, tabs) = try displaysOfTabs()
        choose(["a", "b"])
        let source = try window(of: "c")
        let target = try listTarget(gapKind(after: "r", on: scope(1)), listing: right)
        let intent = try XCTUnwrap(WorkspaceSidebarDropIntent.captured(for: target, source: .init(window: source, subject: .window)))
        await queueWorkspaceSidebarDrop(source.windowId, subject: .window, target: target.kind, placement: nil, intent: intent)?.value
        XCTAssertEqual(tabs["c"]!.workspaceMonitor.rect, right.rect)
        XCTAssertEqual(tabs["a"]!.workspaceMonitor.rect, left.rect)
        XCTAssertEqual(tabs["b"]!.workspaceMonitor.rect, left.rect)
        XCTAssertEqual(selection.names, ["a", "b"])
    }

    // MARK: Fixtures

    private let rowRect = Rect(topLeftX: 0, topLeftY: 100, width: 200, height: 36)

    private func scope(_ index: Int) -> String { workspaceSidebarMonitorScopeId(for: sortedMonitors[index]) }

    private func choose(_ names: [String]) {
        for name in names {
            XCTAssertTrue(selection.handleClick(on: name, modifiers: [.command], order: ["a", "b", "c", "r"], active: nil))
        }
    }

    private func window(of name: String) throws -> Window {
        try XCTUnwrap(Workspace.existing(byName: name)?.anyLeafWindowRecursive)
    }

    @discardableResult
    private func beginDrag(from name: String) throws -> WorkspaceSidebarDragBatch {
        try XCTUnwrap(beginDrag(from: name, batch: true))
    }

    @discardableResult
    private func beginDrag(from name: String, batch: Bool) throws -> WorkspaceSidebarDragBatch? {
        clearActiveWorkspaceSidebarDrag()
        beginActiveWorkspaceSidebarDrag(windowId: try window(of: name).windowId, subject: .window)
        return currentActiveWorkspaceSidebarDrag()?.batch
    }

    private func gapKind(after name: String, on scope: String, in group: String? = nil) -> WorkspaceSidebarDropTargetKind {
        .tabGap(projectId: workspaceProjectDefaultId, monitorScopeId: scope,
            gap: .init(workspaceName: name, isAfter: true, collectionId: group))
    }

    private func gapKind(before name: String, on scope: String) -> WorkspaceSidebarDropTargetKind {
        .tabGap(projectId: workspaceProjectDefaultId, monitorScopeId: scope, gap: .init(workspaceName: name, isAfter: false))
    }

    /// `kind` on a list of `monitor`, as the column a rail opens shows it.
    private func listTarget(_ kind: WorkspaceSidebarDropTargetKind, listing monitor: Monitor) throws -> WorkspaceSidebarDropTarget {
        let target = WorkspaceSidebarDropTarget(kind: kind, rect: rowRect, surface: ListSurface.ref)
        register(ListSurface(target: target, listing: workspaceSidebarMonitorScopeId(for: monitor)))
        return target
    }

    private func register(_ surface: ListSurface) {
        WorkspaceSidebarTemporaryDropSurfaces.shared.removeAll()
        surfaces = [surface]
        WorkspaceSidebarTemporaryDropSurfaces.shared.register(surface)
    }

    private func listOrder() -> [String] {
        orderedWorkspaces(in: workspaceProjectDefaultId).map(\.name).filter { ["a", "b", "c", "r"].contains($0) }
            .filter { workspaceSidebarOrganizationStore.state.workspaces[$0]?.isFavorite != true }
    }

    private func pinOrder() -> [String] { workspacePinnedTabs(in: workspaceProjectDefaultId).map(\.name) }

    /// Tabs a, b, c on the left display (one window each, a on screen); r on the right.
    private func displaysOfTabs() throws -> (left: Monitor, right: Monitor, tabs: [String: Workspace]) {
        let left = WorkspaceSidebarDragTestMonitor(monitorAppKitNsScreenScreensId: 1, name: "Left",
            rect: Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080),
            visibleRect: Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080), isMain: true)
        let right = WorkspaceSidebarDragTestMonitor(monitorAppKitNsScreenScreensId: 2, name: "Right",
            rect: Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080),
            visibleRect: Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080), isMain: false)
        setMonitorsForTests([left, right])
        Workspace.reconcileWorkspaceState()
        var tabs: [String: Workspace] = [:]
        for (index, (name, monitor)) in [("a", left), ("b", left), ("c", left), ("r", right)].enumerated() {
            let tab = Workspace.get(byName: name)
            _ = TestWindow.new(id: UInt32(index + 1), parent: tab.rootTilingContainer)
            tab.preferredMonitorPoint = monitor.rect.topLeftCorner
            tabs[name] = tab
        }
        XCTAssertTrue(left.setActiveWorkspace(tabs["a"]!))
        XCTAssertTrue(right.setActiveWorkspace(tabs["r"]!))
        return (left, right, tabs)
    }

    /// Saved tabs a and b homed on a laptop, a on screen there, and r on a projector, a display a
    /// saved home can't name.
    private func savedTabsOnALaptopAndAProjector() throws -> (laptop: Monitor, projector: Monitor) {
        setSavedWorkspaceTestEnvironment()
        let laptop = SavedWorkspaceTestMonitor(id: 1, name: "Built-in Display", x: 0, isMain: true, uuid: "LAPTOP", isBuiltin: true)
        let projector = SavedWorkspaceTestMonitor(id: 2, name: "Projector", x: 1920, uuid: nil)
        setMonitorsForTests([laptop, projector])
        Workspace.reconcileWorkspaceState()
        for (index, name) in ["a", "b"].enumerated() {
            let tab = Workspace.get(byName: name)
            _ = TestWindow.new(id: UInt32(index + 1), parent: tab.rootTilingContainer)
            XCTAssertTrue(laptop.setActiveWorkspace(tab))
            try ensureSavedWorkspaceRecord(tab)
        }
        let other = Workspace.get(byName: "r")
        _ = TestWindow.new(id: 4, parent: other.rootTilingContainer)
        XCTAssertTrue(projector.setActiveWorkspace(other))
        XCTAssertTrue(laptop.setActiveWorkspace(Workspace.get(byName: "a")))
        return (laptop, projector)
    }

    private func waitUntil(_ condition: () -> Bool, timeout: Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// A display's list, as temporary drop UI shows it, with one target.
@MainActor
private final class ListSurface: WorkspaceSidebarTemporaryDropSurface {
    static let ref: WorkspaceSidebarSurfaceRef = .dropDestination(generation: 57)
    let surfaceRef = ListSurface.ref
    let stackingOrder = 1
    let dropDestination: WorkspaceSidebarDropDestinationIdentity?
    let target: WorkspaceSidebarDropTarget

    init(target: WorkspaceSidebarDropTarget, listing scopeId: String) {
        self.target = target
        dropDestination = .init(monitorScopeId: scopeId)
    }

    func surfaceRectNormalized(containing point: CGPoint) -> Rect? { target.rect.contains(point) ? target.rect : nil }
    func dropTarget(atNormalizedPoint _: CGPoint, hitSlop _: NSEdgeInsets, includesTabGaps _: Bool) -> WorkspaceSidebarDropTarget? {
        target
    }
}
