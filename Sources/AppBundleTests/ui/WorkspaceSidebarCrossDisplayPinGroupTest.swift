import AppKit
@testable import AppBundle
import Common
import XCTest

/// Audit F2: in Tabs mode each list belongs to a display. A tab pinned or grouped on another
/// display's list moves to that display first, as it does between tabs, and a list it can't
/// go to promises no drop.
@MainActor
final class WorkspaceSidebarCrossDisplayPinGroupTest: XCTestCase {
    private let otherDisplay = "monitor:1920.0,0.0"

    override func setUp() async throws {
        setUpWorkspacesForTests()
        workspaceSidebarOrganizationStore = .init()
    }

    override func tearDown() async throws {
        WorkspaceSidebarTabUndo.shared.clear()
        WorkspaceSidebarTabDragState.shared.set(false)
        clearWorkspaceSidebarDropPreview()
        workspaceSidebarOrganizationStore = .init()
        setMonitorsForTests(nil)
        config = defaultConfig
        try await super.tearDown()
    }

    func testATabPinnedOnAnotherDisplaysListMovesThereFirst() throws {
        let (left, right, tabs) = try twoDisplaysOfTabs()
        let rightList = workspaceSidebarMonitorScopeId(for: right)
        let beside = WorkspaceSidebarTabGap(workspaceName: tabs.r.name, isAfter: true)
        let target = WorkspaceSidebarDropTargetKind.pinnedTabs(projectId: tabs.d.projectId, gap: beside, monitorScopeId: rightList)
        previewWorkspaceSidebarDrop(4, subject: .window, target: target)
        let preview = try XCTUnwrap(TrayMenuModel.shared.workspaceSidebarDropPreview)
        XCTAssertTrue(preview.targetsPinned)
        XCTAssertEqual(preview.targetMonitorScopeId, rightList, "The preview names the list the tab goes to")

        try applySidebarPinDrop(4, subject: .window, gap: beside, monitorScopeId: rightList)
        XCTAssertEqual(tabs.d.workspaceMonitor.rect, right.rect, "The tab moved to the display whose pins it was dropped on")
        XCTAssertTrue(right.activeWorkspace === tabs.d)
        XCTAssertFalse(left.activeWorkspace === tabs.d)
        XCTAssertEqual(workspacePinnedTabs(in: tabs.d.projectId).map(\.name), [tabs.a.name, tabs.r.name, tabs.d.name])
    }

    func testAPinOnTheSameDisplaysListStaysPut() throws {
        let (left, _, tabs) = try twoDisplaysOfTabs()
        let leftList = workspaceSidebarMonitorScopeId(for: left)
        try applySidebarPinDrop(4, subject: .window, gap: .init(workspaceName: tabs.a.name, isAfter: true), monitorScopeId: leftList)
        XCTAssertEqual(tabs.d.workspaceMonitor.rect, left.rect)
        XCTAssertTrue(left.activeWorkspace === tabs.d, "Nothing about its display changes")
        XCTAssertEqual(workspacePinnedTabs(in: tabs.d.projectId).map(\.name), [tabs.a.name, tabs.d.name, tabs.r.name])
    }

    func testATabGroupedOnAnotherDisplaysListMovesThereFirst() throws {
        let (_, right, tabs) = try twoDisplaysOfTabs()
        let rightList = workspaceSidebarMonitorScopeId(for: right)
        let group = try workspaceSidebarOrganizationStore.create(projectId: tabs.d.projectId, workspaceNames: [tabs.s.name])
        previewWorkspaceSidebarDrop(4, subject: .window, target: .tabCollection(group.id, monitorScopeId: rightList))
        XCTAssertEqual(TrayMenuModel.shared.workspaceSidebarDropPreview?.targetCollectionId, group.id)
        XCTAssertEqual(TrayMenuModel.shared.workspaceSidebarDropPreview?.targetMonitorScopeId, rightList)

        try applySidebarGroupDrop(4, tab: tabs.d, collectionId: group.id, monitorScopeId: rightList)
        XCTAssertEqual(tabs.d.workspaceMonitor.rect, right.rect)
        XCTAssertEqual(workspaceSidebarOrganizationStore.collection(containing: tabs.d.name)?.id, group.id)

        // Already in the group, it can still be brought over from another display's list.
        let leftList = workspaceSidebarMonitorScopeId(for: sortedMonitors[0])
        previewWorkspaceSidebarDrop(4, subject: .window, target: .tabCollection(group.id, monitorScopeId: leftList))
        XCTAssertNotNil(TrayMenuModel.shared.workspaceSidebarDropPreview)
        previewWorkspaceSidebarDrop(4, subject: .window, target: .tabCollection(group.id, monitorScopeId: rightList))
        XCTAssertNil(TrayMenuModel.shared.workspaceSidebarDropPreview, "In the group on this display already: nothing to do")
    }

    func testATabHeldToItsDisplayIsOfferedNoPinsOrGroupsOnAnother() throws {
        let (left, right, tabs) = try twoDisplaysOfTabs()
        config.workspaceToMonitorForceAssignment[tabs.d.name] = [.main]
        let rightList = workspaceSidebarMonitorScopeId(for: right)
        let group = try workspaceSidebarOrganizationStore.create(projectId: tabs.d.projectId, workspaceNames: [tabs.s.name])
        for target in [WorkspaceSidebarDropTargetKind.pinnedTabs(projectId: tabs.d.projectId,
                           gap: .init(workspaceName: tabs.r.name, isAfter: true), monitorScopeId: rightList),
                       .tabCollection(group.id, monitorScopeId: rightList)] {
            previewWorkspaceSidebarDrop(4, subject: .window, target: target)
            XCTAssertNil(TrayMenuModel.shared.workspaceSidebarDropPreview, "\(target): no drop is promised")
        }
        XCTAssertThrowsError(try applySidebarPinDrop(4, subject: .window, gap: .init(workspaceName: tabs.r.name, isAfter: true),
            monitorScopeId: rightList), "A drop that raced the check is refused")
        XCTAssertEqual(tabs.d.workspaceMonitor.rect, left.rect)
        XCTAssertFalse(workspacePinnedTabs(in: tabs.d.projectId).contains(tabs.d), "Refused, it isn't pinned either")
    }

    func testADraggedPinGoesToTheDisplayOfTheListItsDroppedOn() throws {
        let (_, right, tabs) = try twoDisplaysOfTabs()
        let rightList = workspaceSidebarMonitorScopeId(for: right)
        config.workspaceSidebar.mode = .tabs
        // Beside the pin it already follows: only the display changes, which is still a move.
        let beside = WorkspaceSidebarDropTarget(kind: .pinnedTabs(projectId: tabs.a.projectId,
            gap: .init(workspaceName: tabs.r.name, isAfter: false), monitorScopeId: rightList),
            rect: Rect(topLeftX: 0, topLeftY: 0, width: 100, height: 54))
        let drop = try XCTUnwrap(workspaceSidebarPinnedTabDrop(tabs.a, target: beside, point: .zero))
        XCTAssertEqual(drop, .rearrange(.init(workspaceName: tabs.r.name, isAfter: false), monitorScopeId: rightList))
        XCTAssertEqual(workspaceSidebarPinnedTabDropPreview(tabs.a, drop: drop).targetMonitorScopeId, rightList)
        try applyWorkspaceSidebarPinnedTabDrop(tabs.a, drop)
        XCTAssertEqual(tabs.a.workspaceMonitor.rect, right.rect)

        let group = try workspaceSidebarOrganizationStore.create(projectId: tabs.r.projectId, workspaceNames: [tabs.s.name])
        let leftList = workspaceSidebarMonitorScopeId(for: sortedMonitors[0])
        try applyWorkspaceSidebarPinnedTabDrop(tabs.r, .group(group.id, monitorScopeId: leftList))
        XCTAssertEqual(tabs.r.workspaceMonitor.rect, sortedMonitors[0].rect)
        XCTAssertEqual(workspaceSidebarOrganizationStore.collection(containing: tabs.r.name)?.id, group.id)
        try applyWorkspaceSidebarPinnedTabDrop(tabs.a, .unpin(monitorScopeId: leftList))
        XCTAssertEqual(tabs.a.workspaceMonitor.rect, sortedMonitors[0].rect)
        XCTAssertFalse(workspacePinnedTabs(in: tabs.a.projectId).contains(tabs.a))
    }

    /// Review follow-up: a pin dragged onto another display's list where nothing is pinned yet.
    func testAPinMovesOntoAnotherDisplaysEmptyPins() throws {
        let (_, right, tabs) = try twoDisplaysOfTabs()
        try setWorkspaceSidebarTabFavorite(tabs.r, false)
        let rightList = workspaceSidebarMonitorScopeId(for: right)
        let zone = WorkspaceSidebarDropTarget(kind: .pinnedTabs(projectId: tabs.a.projectId, monitorScopeId: rightList),
            rect: Rect(topLeftX: 0, topLeftY: 0, width: 200, height: 28))
        let drop = try XCTUnwrap(workspaceSidebarPinnedTabDrop(tabs.a, target: zone, point: .zero), "Drop to Pin takes it")
        XCTAssertEqual(drop, .rearrange(nil, monitorScopeId: rightList))
        XCTAssertTrue(workspaceSidebarPinnedTabDropPreview(tabs.a, drop: drop).targetsPinned)
        try applyWorkspaceSidebarPinnedTabDrop(tabs.a, drop)
        XCTAssertEqual(tabs.a.workspaceMonitor.rect, right.rect)
        XCTAssertTrue(workspacePinnedTabs(in: tabs.a.projectId).contains(tabs.a), "Still pinned")
        let sameZone = WorkspaceSidebarDropTarget(kind: .pinnedTabs(projectId: tabs.a.projectId, monitorScopeId: rightList),
            rect: zone.rect)
        XCTAssertNil(workspaceSidebarPinnedTabDrop(tabs.a, target: sameZone, point: .zero), "Already there: nothing to do")
    }

    /// Review follow-up: the display the drop was for is unplugged or rearranged before its session runs.
    func testADropForADisplayThatWentAwayChangesNothing() throws {
        let (left, right, tabs) = try twoDisplaysOfTabs()
        let rightList = workspaceSidebarMonitorScopeId(for: right)
        let group = try workspaceSidebarOrganizationStore.create(projectId: tabs.d.projectId, workspaceNames: [tabs.s.name])
        let pinsBefore = workspacePinnedTabs(in: tabs.d.projectId).map(\.name)
        setMonitorsForTests([left])
        let beside = WorkspaceSidebarTabGap(workspaceName: tabs.a.name, isAfter: true)
        previewWorkspaceSidebarDrop(4, subject: .window, target: .pinnedTabs(projectId: tabs.d.projectId, gap: beside,
            monitorScopeId: rightList))
        XCTAssertNil(TrayMenuModel.shared.workspaceSidebarDropPreview, "A gone display's list promises nothing")
        XCTAssertThrowsError(try applySidebarPinDrop(4, subject: .window, gap: beside, monitorScopeId: rightList))
        XCTAssertThrowsError(try applySidebarGroupDrop(4, tab: tabs.d, collectionId: group.id, monitorScopeId: rightList))
        XCTAssertThrowsError(try applyWorkspaceSidebarPinnedTabDrop(tabs.a, .group(group.id, monitorScopeId: rightList)))
        XCTAssertThrowsError(try applyWorkspaceSidebarPinnedTabDrop(tabs.a, .unpin(monitorScopeId: rightList)))
        XCTAssertEqual(workspacePinnedTabs(in: tabs.d.projectId).map(\.name), pinsBefore, "Nothing was pinned or unpinned")
        XCTAssertNil(workspaceSidebarOrganizationStore.collection(containing: tabs.d.name))
        XCTAssertNil(workspaceSidebarOrganizationStore.collection(containing: tabs.a.name))
    }

    /// Review follow-up: the tab was already on the list's display at the release, and something
    /// moved it before the session ran. The drop still brings it back to that display.
    func testAGroupDropKeepsItsDisplayUntilItsSessionRuns() throws {
        let (left, right, tabs) = try twoDisplaysOfTabs()
        let rightList = workspaceSidebarMonitorScopeId(for: right)
        let group = try workspaceSidebarOrganizationStore.create(projectId: tabs.s.projectId, workspaceNames: [tabs.d.name])
        XCTAssertTrue(left.setActiveWorkspace(tabs.s), "Moved to the left display meanwhile")
        try applySidebarGroupDrop(6, tab: tabs.s, collectionId: group.id, monitorScopeId: rightList)
        XCTAssertEqual(tabs.s.workspaceMonitor.rect, right.rect)
        XCTAssertEqual(workspaceSidebarOrganizationStore.collection(containing: tabs.s.name)?.id, group.id)

        // A window that left the tab since the release takes no tab with it.
        let other = Workspace.get(byName: "other")
        let window = try XCTUnwrap(Window.get(byId: 5))
        window.bind(to: other.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        try applySidebarGroupDrop(5, tab: tabs.r, collectionId: group.id, monitorScopeId: rightList)
        XCTAssertNil(workspaceSidebarOrganizationStore.collection(containing: tabs.r.name))
    }

    /// Review follow-up: when the edit after the move fails, the move is undone too.
    func testAFailedEditUndoesTheMoveToAnotherDisplay() throws {
        let (left, right, tabs) = try twoDisplaysOfTabs()
        let rightList = workspaceSidebarMonitorScopeId(for: right)
        let rightActive = right.activeWorkspace
        XCTAssertThrowsError(try applyWorkspaceSidebarPinnedTabDrop(tabs.a, .group("gone", monitorScopeId: rightList)),
            "The group went away before the session")
        XCTAssertEqual(tabs.a.workspaceMonitor.rect, left.rect, "Back on its own display")
        XCTAssertTrue(right.activeWorkspace === rightActive, "The other display shows what it did")
        XCTAssertTrue(workspacePinnedTabs(in: tabs.a.projectId).contains(tabs.a))
    }

    /// Review follow-up: one window pulled out of a split and pinned on another display's list
    /// gets a tab of its own there; the rest of the split stays.
    func testAWindowPulledOutOfASplitIsPinnedOnAnotherDisplay() throws {
        let (left, right, tabs) = try twoDisplaysOfTabs()
        _ = TestWindow.new(id: 7, parent: tabs.d.rootTilingContainer)
        let rightList = workspaceSidebarMonitorScopeId(for: right)
        let beside = WorkspaceSidebarTabGap(workspaceName: tabs.r.name, isAfter: true)
        previewWorkspaceSidebarDrop(7, subject: .window, target: .pinnedTabs(projectId: tabs.d.projectId, gap: beside,
            monitorScopeId: rightList))
        XCTAssertNotNil(TrayMenuModel.shared.workspaceSidebarDropPreview)
        try applySidebarPinDrop(7, subject: .window, gap: beside, monitorScopeId: rightList)
        let moved = try XCTUnwrap(Window.get(byId: 7)?.nodeWorkspace)
        XCTAssertFalse(moved === tabs.d)
        XCTAssertEqual(moved.workspaceMonitor.rect, right.rect)
        XCTAssertTrue(workspacePinnedTabs(in: moved.projectId).contains(moved))
        XCTAssertEqual(tabs.d.allLeafWindowsRecursive.map(\.windowId), [4])
        XCTAssertEqual(tabs.d.workspaceMonitor.rect, left.rect)
    }

    /// agy follow-up: between tabs, as among pins, a tab held to its display isn't offered another's list.
    func testATabHeldToItsDisplayIsOfferedNoGapOnAnother() throws {
        let (_, right, tabs) = try twoDisplaysOfTabs()
        config.workspaceToMonitorForceAssignment[tabs.d.name] = [.main]
        config.workspaceToMonitorForceAssignment[tabs.a.name] = [.main]
        let rightList = workspaceSidebarMonitorScopeId(for: right)
        let gap = WorkspaceSidebarTabGap(workspaceName: tabs.s.name, isAfter: true)
        previewWorkspaceSidebarDrop(4, subject: .window, target: .tabGap(projectId: tabs.d.projectId,
            monitorScopeId: rightList, gap: gap))
        XCTAssertNil(TrayMenuModel.shared.workspaceSidebarDropPreview)
        let target = WorkspaceSidebarDropTarget(kind: .tabGap(projectId: tabs.a.projectId, monitorScopeId: rightList, gap: gap),
            rect: Rect(topLeftX: 0, topLeftY: 0, width: 200, height: 10))
        XCTAssertNil(workspaceSidebarPinnedTabDrop(tabs.a, target: target, point: .zero))
    }

    func testOnlyTheListADropGoesToShowsIt() {
        var preview = WorkspaceSidebarDropPreviewViewModel(sourceWindowId: 1, label: "a", appName: "App",
            targetWorkspaceName: nil, targetsNewWorkspace: false, targetProjectId: workspaceProjectDefaultId,
            targetMonitorScopeId: otherDisplay, isTabGroup: false, windowCount: 1)
        preview.targetsPinned = true
        preview.targetPinnedGap = .init(workspaceName: "one", isAfter: false)
        XCTAssertTrue(workspaceSidebarDropPreview(preview, targetsList: otherDisplay))
        XCTAssertFalse(workspaceSidebarDropPreview(preview, targetsList: "monitor:0.0,0.0"))
        XCTAssertEqual(workspaceSidebarPinnedInsertionEdge(preview, workspaceName: "one", projectId: workspaceProjectDefaultId,
            monitorScopeId: otherDisplay), .leading)
        XCTAssertNil(workspaceSidebarPinnedInsertionEdge(preview, workspaceName: "one", projectId: workspaceProjectDefaultId,
            monitorScopeId: "monitor:0.0,0.0"), "Another display listing the same pin shows no line")
        let unscoped = WorkspaceSidebarDropPreviewViewModel(sourceWindowId: 1, label: "a", appName: "App",
            targetWorkspaceName: "one", targetsNewWorkspace: false, isTabGroup: false, windowCount: 1)
        XCTAssertTrue(workspaceSidebarDropPreview(unscoped, targetsList: "monitor:0.0,0.0"), "A preview for no display shows as before")
    }

    // MARK: Helpers

    /// Two displays in Tabs mode. On the left: a (pinned, window 1) on screen, and d (window 4),
    /// not pinned. On the right: r (pinned, window 5) on screen, and s (window 6).
    private func twoDisplaysOfTabs() throws -> (left: Monitor, right: Monitor,
                                                tabs: (a: Workspace, d: Workspace, r: Workspace, s: Workspace)) {
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        let left = WorkspaceSidebarDragTestMonitor(monitorAppKitNsScreenScreensId: 1, name: "Left",
            rect: Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080),
            visibleRect: Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080), isMain: true)
        let right = WorkspaceSidebarDragTestMonitor(monitorAppKitNsScreenScreensId: 2, name: "Right",
            rect: Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080),
            visibleRect: Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080), isMain: false)
        setMonitorsForTests([left, right])
        Workspace.reconcileWorkspaceState()
        func tab(_ name: String, window: UInt32) -> Workspace {
            let tab = Workspace.get(byName: name)
            _ = TestWindow.new(id: window, parent: tab.rootTilingContainer)
            return tab
        }
        let a = tab("a", window: 1)
        let d = tab("d", window: 4)
        let r = tab("r", window: 5)
        let s = tab("s", window: 6)
        // A hidden tab belongs to the display it was first placed on.
        for (tab, monitor) in [(a, left), (d, left), (r, right), (s, right)] as [(Workspace, Monitor)] {
            tab.preferredMonitorPoint = monitor.rect.topLeftCorner
        }
        XCTAssertTrue(left.setActiveWorkspace(d))
        XCTAssertTrue(right.setActiveWorkspace(r))
        XCTAssertEqual(d.workspaceMonitor.rect, left.rect)
        XCTAssertEqual(a.workspaceMonitor.rect, left.rect)
        XCTAssertEqual(r.workspaceMonitor.rect, right.rect)
        XCTAssertEqual(s.workspaceMonitor.rect, right.rect)
        try setWorkspaceSidebarTabsFavorite([a, r], true)
        return (left, right, (a, d, r, s))
    }
}
