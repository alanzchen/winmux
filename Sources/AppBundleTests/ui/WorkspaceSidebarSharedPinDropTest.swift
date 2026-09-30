import AppKit
@testable import AppBundle
import Common
import XCTest

/// Shared pins (§7.2): with share-pinned-tabs on, the pin tiles are one collection shown on every
/// display. Pinning a tab there or rearranging the pins never takes a tab to another display.
/// Drops on a display's list, gaps, groups, tabs and New Tab still bring the tab there, and with
/// the setting off, pins do too, as before.
@MainActor
final class WorkspaceSidebarSharedPinDropTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        workspaceSidebarOrganizationStore = .init()
    }

    override func tearDown() async throws {
        WorkspaceSidebarTabUndo.shared.clear()
        clearWorkspaceSidebarDropPreview()
        workspaceSidebarOrganizationStore = .init()
        setMonitorsForTests(nil)
        config = defaultConfig
        try await super.tearDown()
    }

    func testRearrangingSharedPinsNeverMovesATabAcrossDisplays() throws {
        let (left, right, tabs) = try twoDisplaysOfTabs(sharing: true)
        let leftList = workspaceSidebarMonitorScopeId(for: left)
        // The right display's pin, dragged in front of the left one's on the left display's list.
        let beside = WorkspaceSidebarDropTarget(kind: .pinnedTabs(projectId: tabs.r.projectId,
            gap: .init(workspaceName: tabs.a.name, isAfter: false), monitorScopeId: leftList), rect: tile)
        let drop = try XCTUnwrap(workspaceSidebarPinnedTabDrop(tabs.r, target: beside, point: .zero))
        XCTAssertEqual(drop, .rearrange(.init(workspaceName: tabs.a.name, isAfter: false), monitorScopeId: leftList))
        try applyWorkspaceSidebarPinnedTabDrop(tabs.r, drop, pinGridIsShared: true)
        XCTAssertEqual(workspacePinnedTabs(in: tabs.r.projectId).map(\.name), [tabs.r.name, tabs.a.name])
        XCTAssertEqual(tabs.r.workspaceMonitor.rect, right.rect, "It stays on its display")
        XCTAssertTrue(right.activeWorkspace === tabs.r)
        XCTAssertTrue(left.activeWorkspace === tabs.d, "Nothing moved onto the left display")

        // Beside the pin it already follows, only the display would have changed: that's no drop.
        let inPlace = WorkspaceSidebarDropTarget(kind: .pinnedTabs(projectId: tabs.a.projectId,
            gap: .init(workspaceName: tabs.r.name, isAfter: true), monitorScopeId: workspaceSidebarMonitorScopeId(for: right)),
            rect: tile)
        XCTAssertNil(workspaceSidebarPinnedTabDrop(tabs.a, target: inPlace, point: .zero))
        let emptyZone = WorkspaceSidebarDropTarget(kind: .pinnedTabs(projectId: tabs.a.projectId,
            monitorScopeId: workspaceSidebarMonitorScopeId(for: right)), rect: tile)
        XCTAssertNil(workspaceSidebarPinnedTabDrop(tabs.a, target: emptyZone, point: .zero), "Nor Drop to Pin, already pinned")
        // A pin's own tile, rebuilt as a place beside it, rearranges the same way.
        let onTile = WorkspaceSidebarDropTarget(kind: .workspace(tabs.r.name), rect: tile, acceptsSides: true,
            tabReorderDestination: .init(projectId: tabs.r.projectId, monitorScopeId: leftList, collectionId: nil,
                arrangesPins: true))
        XCTAssertEqual(workspaceSidebarPinnedTabDrop(tabs.a, target: onTile, point: CGPoint(x: 1, y: 10)),
            .rearrange(.init(workspaceName: tabs.r.name, isAfter: false), monitorScopeId: leftList))
    }

    /// A tab pinned from another display's list, a whole tab or a window pulled out of a split,
    /// is pinned where it is.
    func testPinningATabFromAnotherDisplaysListPinsItWithoutMovingIt() throws {
        let (left, right, tabs) = try twoDisplaysOfTabs(sharing: true)
        let rightList = workspaceSidebarMonitorScopeId(for: right)
        let beside = WorkspaceSidebarTabGap(workspaceName: tabs.r.name, isAfter: true)
        previewWorkspaceSidebarDrop(4, subject: .window, target: .pinnedTabs(projectId: tabs.d.projectId, gap: beside,
            monitorScopeId: rightList))
        XCTAssertEqual(TrayMenuModel.shared.workspaceSidebarDropPreview?.targetsPinned, true, "The drop is shown")
        try applySidebarPinDrop(4, subject: .window, gap: beside, monitorScopeId: rightList, pinGridIsShared: true)
        XCTAssertTrue(workspacePinnedTabs(in: tabs.d.projectId).contains(tabs.d))
        XCTAssertEqual(tabs.d.workspaceMonitor.rect, left.rect, "Pinned, not moved")
        XCTAssertTrue(left.activeWorkspace === tabs.d)

        _ = TestWindow.new(id: 7, parent: tabs.s.rootTilingContainer)
        try applySidebarPinDrop(7, subject: .window, gap: nil, monitorScopeId: workspaceSidebarMonitorScopeId(for: left),
            pinGridIsShared: true)
        let pulled = try XCTUnwrap(Window.get(byId: 7)?.nodeWorkspace)
        XCTAssertFalse(pulled === tabs.s)
        XCTAssertTrue(workspacePinnedTabs(in: pulled.projectId).contains(pulled))
        XCTAssertEqual(pulled.workspaceMonitor.rect, right.rect, "Its new tab stays on the display it was made on")
    }

    /// Everything but the pin tiles keeps its display with shared pins.
    func testListGroupGapAndNewTabDropsStillMove() throws {
        let (left, right, tabs) = try twoDisplaysOfTabs(sharing: true)
        let rightList = workspaceSidebarMonitorScopeId(for: right)
        let leftList = workspaceSidebarMonitorScopeId(for: left)
        // A pin dropped into another display's list, into its group, or on its New Tab.
        try applyWorkspaceSidebarPinnedTabDrop(tabs.a, .list(projectId: tabs.a.projectId, monitorScopeId: rightList,
            gap: .init(workspaceName: tabs.s.name, isAfter: true)), pinGridIsShared: true)
        XCTAssertEqual(tabs.a.workspaceMonitor.rect, right.rect, "Into the list: it goes there, unpinned")
        XCTAssertFalse(workspacePinnedTabs(in: tabs.a.projectId).contains(tabs.a))
        try setWorkspaceSidebarTabFavorite(tabs.a, true)
        try applyWorkspaceSidebarPinnedTabDrop(tabs.a, .unpin(monitorScopeId: leftList), pinGridIsShared: true)
        XCTAssertEqual(tabs.a.workspaceMonitor.rect, left.rect, "On New Tab: it goes there")
        let group = try workspaceSidebarOrganizationStore.create(projectId: tabs.r.projectId, workspaceNames: [tabs.d.name])
        try applyWorkspaceSidebarPinnedTabDrop(tabs.r, .group(group.id, monitorScopeId: leftList), pinGridIsShared: true)
        XCTAssertEqual(tabs.r.workspaceMonitor.rect, left.rect, "Into a group: it goes there")

        // A window dropped into a group or between tabs on the other display's list.
        let group2 = try workspaceSidebarOrganizationStore.create(projectId: tabs.s.projectId, workspaceNames: [tabs.s.name])
        let window = try XCTUnwrap(Window.get(byId: 4))
        try applySidebarGroupDrop(4, tab: tabs.d, collectionId: group2.id, monitorScopeId: rightList)
        XCTAssertEqual(tabs.d.workspaceMonitor.rect, right.rect)
        XCTAssertTrue(applyTabGapDrop(sourceNode: window, sourceWindow: window, projectId: tabs.d.projectId,
            monitor: left, gap: .init(workspaceName: tabs.a.name, isAfter: true)))
        XCTAssertEqual(tabs.d.workspaceMonitor.rect, left.rect, "Between tabs: it goes there")
    }

    /// The setting off keeps pins the display's own: a drop on them brings the tab there.
    func testWithoutSharedPinsAPinDropStillBringsTheTab() throws {
        let (_, right, tabs) = try twoDisplaysOfTabs(sharing: false)
        let rightList = workspaceSidebarMonitorScopeId(for: right)
        XCTAssertFalse(workspaceSidebarPinGridIsShared())
        let drop = try XCTUnwrap(workspaceSidebarPinnedTabDrop(tabs.a, target: .init(kind: .pinnedTabs(projectId: tabs.a.projectId,
            gap: .init(workspaceName: tabs.r.name, isAfter: false), monitorScopeId: rightList), rect: tile), point: .zero))
        try applyWorkspaceSidebarPinnedTabDrop(tabs.a, drop, pinGridIsShared: false)
        XCTAssertEqual(tabs.a.workspaceMonitor.rect, right.rect)
        try applySidebarPinDrop(4, subject: .window, gap: nil, monitorScopeId: rightList, pinGridIsShared: false)
        XCTAssertEqual(tabs.d.workspaceMonitor.rect, right.rect)
    }

    /// A tab held to its display can't go to another, but it can be pinned among shared pins,
    /// since it stays where it is.
    func testATabHeldToItsDisplayCanStillBePinnedAmongSharedPins() throws {
        let (left, right, tabs) = try twoDisplaysOfTabs(sharing: true)
        config.workspaceToMonitorForceAssignment[tabs.d.name] = [.main]
        let rightList = workspaceSidebarMonitorScopeId(for: right)
        let pins = WorkspaceSidebarDropTargetKind.pinnedTabs(projectId: tabs.d.projectId,
            gap: .init(workspaceName: tabs.r.name, isAfter: true), monitorScopeId: rightList)
        previewWorkspaceSidebarDrop(4, subject: .window, target: pins)
        XCTAssertNotNil(TrayMenuModel.shared.workspaceSidebarDropPreview)
        try applySidebarPinDrop(4, subject: .window, gap: .init(workspaceName: tabs.r.name, isAfter: true),
            monitorScopeId: rightList, pinGridIsShared: true)
        XCTAssertTrue(workspacePinnedTabs(in: tabs.d.projectId).contains(tabs.d))
        XCTAssertEqual(tabs.d.workspaceMonitor.rect, left.rect)
        // Its list drops still refuse the other display.
        previewWorkspaceSidebarDrop(4, subject: .window, target: .newWorkspace(projectId: tabs.d.projectId, monitorScopeId: rightList))
        XCTAssertNotNil(TrayMenuModel.shared.workspaceSidebarDropPreview, "A window can still get a new tab there")
        XCTAssertNil(workspaceSidebarPinnedTabDrop(tabs.d, target: .init(kind: .tabGap(projectId: tabs.d.projectId,
            monitorScopeId: rightList, gap: .init(workspaceName: tabs.s.name, isAfter: true)), rect: tile), point: .zero),
            "Between the other display's tabs, it isn't offered")
    }

    func testSharedPinsOnADisplayThatWentAwayTakeNothing() throws {
        let (_, _, tabs) = try twoDisplaysOfTabs(sharing: true)
        let gone = "monitor:5000.0,0.0"
        XCTAssertNil(workspaceSidebarPinnedTabDrop(tabs.a, target: .init(kind: .pinnedTabs(projectId: tabs.a.projectId,
            gap: .init(workspaceName: tabs.r.name, isAfter: true), monitorScopeId: gone), rect: tile), point: .zero))
        XCTAssertThrowsError(try applySidebarPinDrop(4, subject: .window, gap: nil, monitorScopeId: gone, pinGridIsShared: true))
        XCTAssertFalse(workspacePinnedTabs(in: tabs.d.projectId).contains(tabs.d))
        XCTAssertThrowsError(try applyWorkspaceSidebarPinnedTabDrop(tabs.a, .rearrange(nil, monitorScopeId: gone),
            pinGridIsShared: true))
    }

    /// A pin write that can't be saved leaves everything where it was.
    func testASharedPinDropThatCantBeSavedChangesNothing() throws {
        let (left, right, tabs) = try twoDisplaysOfTabs(sharing: true)
        workspaceSidebarOrganizationStore = .init(state: workspaceSidebarOrganizationStore.state, readOnlyReason: "Read-only")
        defer { MessageModel.shared.message = nil }
        let before = workspacePinnedTabs(in: tabs.a.projectId).map(\.name)
        XCTAssertThrowsError(try applyWorkspaceSidebarPinnedTabDrop(tabs.r, .rearrange(.init(workspaceName: tabs.a.name,
            isAfter: false), monitorScopeId: workspaceSidebarMonitorScopeId(for: left)), pinGridIsShared: true))
        XCTAssertEqual(workspacePinnedTabs(in: tabs.a.projectId).map(\.name), before)
        XCTAssertEqual(tabs.r.workspaceMonitor.rect, right.rect)
    }

    /// A window pulled out of a split onto shared pins, whose pin then can't be written: the split
    /// comes back as it was, and nothing is pinned.
    func testASplitWindowWhosePinFailsGoesBackIntoItsTab() throws {
        let (_, right, tabs) = try twoDisplaysOfTabs(sharing: true)
        _ = TestWindow.new(id: 7, parent: tabs.s.rootTilingContainer)
        let pins = workspacePinnedTabs(in: tabs.s.projectId).map(\.name)
        // Writable as far as anyone can tell, but the write itself fails.
        workspaceSidebarOrganizationStore = .init(state: workspaceSidebarOrganizationStore.state,
            url: URL(fileURLWithPath: "/dev/null/sidebar-organization.json"))
        XCTAssertThrowsError(try applySidebarPinDrop(7, subject: .window, gap: nil, monitorScopeId: workspaceSidebarMonitorScopeId(
            for: sortedMonitors[0]), pinGridIsShared: true))
        XCTAssertTrue(Window.get(byId: 7)?.nodeWorkspace === tabs.s, "Back in the tab it was pulled out of")
        XCTAssertEqual(Set(tabs.s.allLeafWindowsRecursive.map(\.windowId)), [6, 7])
        XCTAssertEqual(tabs.s.workspaceMonitor.rect, right.rect)
        XCTAssertEqual(workspacePinnedTabs(in: tabs.s.projectId).map(\.name), pins)
    }

    // MARK: Helpers

    private let tile = Rect(topLeftX: 0, topLeftY: 0, width: 100, height: 54)

    /// Two displays. Left shows d; a is pinned and hidden there. Right shows r, which is pinned,
    /// and s is hidden there.
    private func twoDisplaysOfTabs(sharing: Bool) throws -> (left: Monitor, right: Monitor,
                                                              tabs: (a: Workspace, d: Workspace, r: Workspace, s: Workspace)) {
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        config.workspaceSidebar.sharePinnedTabs = sharing
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
        for (tab, monitor) in [(a, left), (d, left), (r, right), (s, right)] as [(Workspace, Monitor)] {
            tab.preferredMonitorPoint = monitor.rect.topLeftCorner
        }
        XCTAssertTrue(left.setActiveWorkspace(d))
        XCTAssertTrue(right.setActiveWorkspace(r))
        try setWorkspaceSidebarTabsFavorite([a, r], true)
        XCTAssertEqual(workspacePinnedTabs(in: a.projectId).map(\.name), [a.name, r.name])
        return (left, right, (a, d, r, s))
    }
}
