import AppKit
@testable import AppBundle
import Common
import SwiftUI
import XCTest

@MainActor
final class WorkspaceSidebarPinnedDragTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        workspaceSidebarOrganizationStore = .init()
    }

    override func tearDown() async throws {
        WorkspaceSidebarTabUndo.shared.clear()
        WorkspaceSidebarTabDragState.shared.set(false)
        clearWorkspaceSidebarDropPreview()
        workspaceSidebarOrganizationStore = .init()
        config = defaultConfig
        try await super.tearDown()
    }

    /// Tabs a, b, c and d, in that order, with windows 1 to 4; a, b and c are pinned.
    private func tabs() throws -> (a: Workspace, b: Workspace, c: Workspace, d: Workspace) {
        let tabs = ["a", "b", "c", "d"].enumerated().map { index, name in
            let tab = Workspace.get(byName: name)
            _ = TestWindow.new(id: UInt32(index + 1), parent: tab.rootTilingContainer)
            return tab
        }
        try setWorkspaceSidebarTabsFavorite(Array(tabs.prefix(3)), true)
        return (tabs[0], tabs[1], tabs[2], tabs[3])
    }

    private func pins(_ projectId: WorkspaceProjectId = workspaceProjectDefaultId) -> [String] {
        workspacePinnedTabs(in: projectId).map(\.name)
    }

    /// The tabs' navigation order, without the empty workspace the tests start on.
    private func navigation(from tab: Workspace) -> [String] {
        workspaceNavigationTabs(current: tab).map(\.name).filter { ["a", "b", "c", "d"].contains($0) }
    }

    private func preview(_ windowId: UInt32, _ target: WorkspaceSidebarDropTargetKind) -> WorkspaceSidebarDropPreviewViewModel? {
        previewWorkspaceSidebarDrop(windowId, subject: .window, target: target)
        return TrayMenuModel.shared.workspaceSidebarDropPreview
    }

    private func beside(_ tab: Workspace, after: Bool) -> WorkspaceSidebarDropTargetKind {
        .pinnedTabs(projectId: tab.projectId, gap: .init(workspaceName: tab.name, isAfter: after))
    }

    /// What dropping a dragged pin on `kind` would do, with the pointer in the target's upper or lower half.
    private func drop(_ tab: Workspace, _ kind: WorkspaceSidebarDropTargetKind, lower: Bool = false, left: Bool = false,
                      reorder: WorkspaceSidebarTabReorderDestination? = nil) -> WorkspaceSidebarPinnedTabDrop? {
        let target = WorkspaceSidebarDropTarget(kind: kind, rect: Rect(topLeftX: 0, topLeftY: 100, width: 200, height: 36),
            tabReorderDestination: reorder)
        return workspaceSidebarPinnedTabDrop(tab, target: target, point: CGPoint(x: left ? 50 : 150, y: lower ? 130 : 105))
    }

    private func pinTile(_ tab: Workspace) -> WorkspaceSidebarDropTarget {
        WorkspaceSidebarDropTarget(kind: .workspace(tab.name), rect: Rect(topLeftX: 0, topLeftY: 0, width: 106, height: 54),
            acceptsSides: true, tabReorderDestination: .init(projectId: tab.projectId, monitorScopeId: "s", collectionId: nil,
                arrangesPins: true))
    }

    func testArrangedPinsComeFirstAndThePinsNotYetArrangedFollowInTabOrder() {
        let tabs: [(name: String, pinned: Bool, order: Int?)] = [
            ("a", true, nil), ("x", false, nil), ("b", true, 1), ("c", true, 0), ("d", true, nil), ("y", false, 0),
        ]
        let ordered = workspaceTabOrder(tabs, name: \.name, isPinned: \.pinned, pinOrder: \.order, collections: [])
        XCTAssertEqual(ordered.map(\.name), ["c", "b", "a", "d", "x", "y"], "A pin order means nothing for a tab that isn't pinned")
        XCTAssertEqual(workspaceTabOrder(tabs, name: \.name, isPinned: \.pinned, collections: []).map(\.name),
            ["a", "b", "c", "d", "x", "y"], "Without an arrangement, pins keep the tab order")
    }

    func testDraggingAPinBesideAnotherRearrangesThePinsOnly() throws {
        let (a, b, c, d) = try tabs()
        let order = orderedWorkspaces(in: a.projectId).map(\.name)
        XCTAssertEqual(drop(c, beside(a, after: false)), .rearrange(.init(workspaceName: a.name, isAfter: false)))
        XCTAssertNil(drop(c, beside(b, after: true)), "c already follows b")
        XCTAssertNil(drop(c, beside(c, after: false)), "Beside itself")
        XCTAssertNil(drop(a, beside(b, after: false)), "a already precedes b")
        XCTAssertNil(drop(c, beside(d, after: false)), "d isn't pinned")
        XCTAssertNil(drop(c, .pinnedTabs(projectId: "another", gap: .init(workspaceName: a.name, isAfter: false))))
        XCTAssertNil(drop(d, .tabGap(projectId: d.projectId, monitorScopeId: "s", gap: .init(workspaceName: a.name, isAfter: true))),
            "Only a pinned tab drags this way")
        let preview = workspaceSidebarPinnedTabDropPreview(c, drop: .rearrange(.init(workspaceName: a.name, isAfter: false)))
        XCTAssertTrue(preview.targetsPinned)
        XCTAssertEqual(preview.targetPinnedGap, .init(workspaceName: a.name, isAfter: false))

        try applyWorkspaceSidebarPinnedTabDrop(c, .rearrange(.init(workspaceName: a.name, isAfter: false)))
        XCTAssertEqual(pins(), ["c", "a", "b"])
        XCTAssertEqual(navigation(from: a), ["c", "a", "b", "d"],
            "Next, previous and numbered tabs follow the pins' new order")
        XCTAssertEqual(orderedWorkspaces(in: a.projectId).map(\.name), order,
            "The tabs' own order is untouched, so an unpinned tab goes back where it was")
        XCTAssertEqual(workspaceSidebarOrderedTabs(sidebarTabs([a, b, c, d]), collections: []).map(\.name), ["c", "a", "b", "d"],
            "The sidebar shows the same order")
        try applyWorkspaceSidebarPinnedTabDrop(a, .rearrange(.init(workspaceName: b.name, isAfter: true)))
        XCTAssertEqual(pins(), ["c", "b", "a"])
    }

    func testATabDroppedBesideAPinIsPinnedThereAndLeavesItsGroup() throws {
        let (a, b, _, d) = try tabs()
        let group = try workspaceSidebarOrganizationStore.create(projectId: d.projectId, workspaceNames: [d.name])
        let pinning = try XCTUnwrap(preview(4, beside(a, after: true)), "A list tab dragged beside a pin")
        XCTAssertTrue(pinning.targetsPinned)
        XCTAssertEqual(pinning.targetPinnedGap?.workspaceName, a.name)
        try pinWorkspaceSidebarTab(d, beside: .init(workspaceName: a.name, isAfter: true))
        XCTAssertEqual(pins(), ["a", "d", "b", "c"])
        XCTAssertFalse(workspaceSidebarOrganizationStore.state.collections.first { $0.id == group.id }?.workspaceNames
            .contains(d.name) ?? true, "Pinned tabs leave their group")

        let e = Workspace.get(byName: "e")
        _ = TestWindow.new(id: 5, parent: e.rootTilingContainer)
        try setWorkspaceSidebarTabFavorite(e, true)
        XCTAssertEqual(pins(), ["a", "d", "b", "c", "e"], "Pinned from its menu, a tab goes after the arranged pins")
        XCTAssertTrue(b.isSaved, "Pinning still saves the tab")
    }

    func testDraggingAPinIntoTheListUnpinsItWhereItsDropped() throws {
        let (a, _, c, d) = try tabs()
        try pinWorkspaceSidebarTab(c, beside: .init(workspaceName: a.name, isAfter: false))
        let scope = workspaceSidebarMonitorScopeId(for: c.workspaceMonitor)
        let before = WorkspaceSidebarDropTargetKind.tabGap(projectId: c.projectId, monitorScopeId: scope,
            gap: .init(workspaceName: d.name, isAfter: false))
        XCTAssertEqual(drop(c, before), .list(projectId: c.projectId, monitorScopeId: scope,
            gap: .init(workspaceName: d.name, isAfter: false)), "Its place in the list is where it already sits, but it leaves the pins")
        XCTAssertNotNil(preview(3, before), "A window drag of the whole pinned tab is offered the same place")
        let row = WorkspaceSidebarTabReorderDestination(projectId: c.projectId, monitorScopeId: scope, collectionId: nil)
        XCTAssertNil(drop(c, .workspace(d.name), lower: true, reorder: row),
            "Over a tab, without pausing, it doesn't leave the pins: only the gaps between tabs unpin it")
        XCTAssertNil(drop(c, .workspace(d.name)), "A tab that takes no reorder, such as a search result, takes no pin")

        try applyWorkspaceSidebarPinnedTabDrop(c, .list(projectId: c.projectId, monitorScopeId: scope,
            gap: .init(workspaceName: d.name, isAfter: true)))
        XCTAssertEqual(pins(), ["a", "b"])
        XCTAssertNil(workspaceSidebarOrganizationStore.state.workspaces[c.name]?.pinOrder, "An unpinned tab forgets its place")
        XCTAssertEqual(navigation(from: a), ["a", "b", "d", "c"])
        XCTAssertEqual(c.allLeafWindowsRecursive.map(\.windowId), [3], "The tab moves whole")
        XCTAssertNil(preview(3, before.withGap(.init(workspaceName: d.name, isAfter: true))),
            "Unpinned, the same place is where it already is")

        try setWorkspaceSidebarTabFavorite(c, true)
        XCTAssertEqual(pins(), ["a", "b", "c"], "Pinned again, it goes after the arranged pins, not to its old place")
    }

    func testAPinnedSplitDragsAsOneTabIntoTheListOrAGroup() throws {
        let (a, b, _, d) = try tabs()
        _ = TestWindow.new(id: 9, parent: a.rootTilingContainer)
        let group = try workspaceSidebarOrganizationStore.create(projectId: d.projectId, workspaceNames: [d.name])
        XCTAssertEqual(drop(a, .tabCollection(group.id)), .group(group.id))
        XCTAssertNil(drop(a, .tabCollection("missing")))
        try applyWorkspaceSidebarPinnedTabDrop(a, .group(group.id))
        XCTAssertEqual(pins(), ["b", "c"])
        XCTAssertEqual(workspaceSidebarOrganizationStore.collection(containing: a.name)?.id, group.id)
        XCTAssertEqual(a.allLeafWindowsRecursive.map(\.windowId), [1, 9], "The split moves as one tab")

        let scope = workspaceSidebarMonitorScopeId(for: b.workspaceMonitor)
        try applyWorkspaceSidebarPinnedTabDrop(b, .list(projectId: b.projectId, monitorScopeId: scope,
            gap: .init(workspaceName: d.name, isAfter: true, collectionId: group.id)))
        XCTAssertEqual(pins(), ["c"])
        XCTAssertEqual(workspaceSidebarOrganizationStore.collection(containing: b.name)?.id, group.id,
            "Dropped between a group's tabs, it joins the group")
    }

    func testAnEmptyPinRearrangesAndUnpinsLikeAnyOther() throws {
        let (a, _, _, d) = try tabs()
        let empty = Workspace.get(byName: "empty")
        try setWorkspaceSidebarTabFavorite(empty, true)
        XCTAssertEqual(pins(), ["a", "b", "c", "empty"])
        let preview = workspaceSidebarPinnedTabDropPreview(empty, drop: nil)
        XCTAssertEqual(preview.sourceWindowId, 0, "No window to dim or carry")
        XCTAssertEqual(drop(empty, beside(a, after: false)), .rearrange(.init(workspaceName: a.name, isAfter: false)))
        try applyWorkspaceSidebarPinnedTabDrop(empty, .rearrange(.init(workspaceName: a.name, isAfter: false)))
        XCTAssertEqual(pins(), ["empty", "a", "b", "c"])
        try applyWorkspaceSidebarPinnedTabDrop(empty, .list(projectId: d.projectId,
            monitorScopeId: workspaceSidebarMonitorScopeId(for: d.workspaceMonitor), gap: .init(workspaceName: d.name, isAfter: true)))
        XCTAssertEqual(pins(), ["a", "b", "c"])
        XCTAssertTrue(Workspace.existing(byName: "empty") === empty, "Unpinning keeps the saved tab")
    }

    func testNewTabUnpinsAPinWhereItIs() throws {
        let (a, b, _, _) = try tabs()
        XCTAssertEqual(drop(b, .newWorkspace(projectId: b.projectId, monitorScopeId: "s")), .unpin(monitorScopeId: "s"))
        XCTAssertNil(drop(b, .newWorkspace(projectId: "another", monitorScopeId: "s")))
        XCTAssertTrue(workspaceSidebarPinnedTabDropPreview(b, drop: .unpin()).targetsNewWorkspace)
        try applyWorkspaceSidebarPinnedTabDrop(b, .unpin())
        XCTAssertEqual(pins(), ["a", "c"])
        XCTAssertEqual(b.allLeafWindowsRecursive.map(\.windowId), [2], "Its window stays in it")
        XCTAssertEqual(navigation(from: a), ["a", "c", "b", "d"])
    }

    func testWithEveryTabPinnedTheEmptyListStillTakesAPin() {
        XCTAssertNil(workspaceSidebarTabsTailGap(sections: []))
        let tail = workspaceSidebarTabsTailGap(sections: [], lastPin: "c")
        XCTAssertEqual(tail?.gap, .init(workspaceName: "c", isAfter: true))
        XCTAssertEqual(tail?.drawsOwnLine, true, "No row in the list draws its line")
        let emptyGroup = WorkspaceTabCollection(projectId: workspaceProjectDefaultId, workspaceNames: [])
        XCTAssertEqual(workspaceSidebarTabsTailGap(sections: [.collection(emptyGroup, [])], lastPin: "c")?.gap.workspaceName, "c")
    }

    func testAPinThatCantBeUnpinnedStaysInItsProject() throws {
        let (_, _, c, _) = try tabs()
        let other = createWorkspaceProject()
        let anchor = Workspace.get(byName: "elsewhere")
        _ = TestWindow.new(id: 7, parent: anchor.rootTilingContainer)
        anchor.assignProject(other.id)
        workspaceSidebarOrganizationStore = .init(state: workspaceSidebarOrganizationStore.state, readOnlyReason: "Read-only")
        defer { MessageModel.shared.message = nil }
        applyTabGapDrop(sourceNode: c.allLeafWindowsRecursive[0], sourceWindow: c.allLeafWindowsRecursive[0], projectId: other.id,
            monitor: c.workspaceMonitor, gap: .init(workspaceName: anchor.name, isAfter: true))
        XCTAssertEqual(c.projectId, workspaceProjectDefaultId, "Unpinning failed first, so the tab didn't move")
        XCTAssertEqual(pins(), ["a", "b", "c"])
        XCTAssertNotNil(MessageModel.shared.message)
    }

    func testAPinThatCantBeSavedStaysPutWhenDroppedIntoAnotherProjectsGroup() throws {
        let (_, _, c, _) = try tabs()
        let other = createWorkspaceProject()
        let anchor = Workspace.get(byName: "elsewhere")
        _ = TestWindow.new(id: 7, parent: anchor.rootTilingContainer)
        anchor.assignProject(other.id)
        let group = try workspaceSidebarOrganizationStore.create(projectId: other.id, workspaceNames: [anchor.name])
        workspaceSidebarOrganizationStore = .init(state: workspaceSidebarOrganizationStore.state, readOnlyReason: "Read-only")
        defer { MessageModel.shared.message = nil }
        try applyWorkspaceSidebarPinnedTabDrop(c, .list(projectId: other.id,
            monitorScopeId: workspaceSidebarMonitorScopeId(for: c.workspaceMonitor),
            gap: .init(workspaceName: anchor.name, isAfter: true, collectionId: group.id)))
        XCTAssertEqual(c.projectId, workspaceProjectDefaultId, "Checked before anything moved")
        XCTAssertEqual(pins(), ["a", "b", "c"])
        XCTAssertNotNil(MessageModel.shared.message)
    }

    func testAPinStaysPutWhenJoiningAGroupCantSaveTheTab() throws {
        let (a, _, _, d) = try tabs()
        let group = try workspaceSidebarOrganizationStore.create(projectId: d.projectId, workspaceNames: [d.name])
        let saved = savedWorkspaceStore
        savedWorkspaceStore = SavedWorkspaceStore(url: nil, readOnlyReason: "newer")
        defer { savedWorkspaceStore = saved; MessageModel.shared.message = nil }
        try applyWorkspaceSidebarPinnedTabDrop(a, .list(projectId: a.projectId,
            monitorScopeId: workspaceSidebarMonitorScopeId(for: a.workspaceMonitor),
            gap: .init(workspaceName: d.name, isAfter: true, collectionId: group.id)))
        XCTAssertEqual(pins(), ["a", "b", "c"])
        XCTAssertNil(workspaceSidebarOrganizationStore.collection(containing: a.name))
        XCTAssertNotNil(MessageModel.shared.message)
    }

    func testTheLastPinDroppedInTheEmptyListAfterItselfIsUnpinnedInPlace() throws {
        let (a, _, c, _) = try tabs()
        let order = orderedWorkspaces(in: c.projectId).map(\.name)
        try applyWorkspaceSidebarPinnedTabDrop(c, .list(projectId: c.projectId,
            monitorScopeId: workspaceSidebarMonitorScopeId(for: c.workspaceMonitor), gap: .init(workspaceName: c.name, isAfter: true)))
        XCTAssertEqual(pins(), ["a", "b"])
        XCTAssertEqual(orderedWorkspaces(in: a.projectId).map(\.name), order)
    }

    func testADropAppliesOnlyToTheTabThatWasDragged() throws {
        let (a, _, _, _) = try tabs()
        let dragged = Workspace.get(byName: "reused")
        try setWorkspaceSidebarTabFavorite(dragged, true)
        removeWorkspaceFromRegistry(dragged, reason: .deleted)
        let replacement = Workspace.get(byName: "reused")
        try setWorkspaceSidebarTabFavorite(replacement, true)
        XCTAssertFalse(replacement === dragged)
        XCTAssertEqual(pins(), ["a", "b", "c", "reused"])
        try applyWorkspaceSidebarPinnedTabDrop(dragged, .rearrange(.init(workspaceName: a.name, isAfter: false)))
        XCTAssertEqual(pins(), ["a", "b", "c", "reused"], "Another tab that took the name isn't moved in its place")
    }

    func testATabThatTakesTheDraggedPinsNameMidDragGetsNoDrop() throws {
        _ = try tabs()
        let dragged = Workspace.get(byName: "reused")
        try setWorkspaceSidebarTabFavorite(dragged, true)
        updateSidebarPinnedTabDrag("reused", pointer: .zero)
        XCTAssertEqual(WorkspaceSidebarTabDragState.shared.draggedPinnedTab, "reused")
        removeWorkspaceFromRegistry(dragged, reason: .deleted)
        try setWorkspaceSidebarTabFavorite(Workspace.get(byName: "reused"), true)
        updateSidebarPinnedTabDrag("reused", pointer: .zero)
        XCTAssertNil(WorkspaceSidebarTabDragState.shared.draggedPinnedTab, "The drag stops showing, rather than carry the new tab")
        XCTAssertNil(WindowDragCursorProxyPanel.shared.currentContent)
        finishSidebarPinnedTabDrag("reused", pointer: .zero)
        XCTAssertEqual(pins(), ["a", "b", "c", "reused"])
    }

    func testAPinDroppedInAGroupThatWentMeanwhileStaysPut() throws {
        let (a, _, _, d) = try tabs()
        try applyWorkspaceSidebarPinnedTabDrop(a, .list(projectId: a.projectId,
            monitorScopeId: workspaceSidebarMonitorScopeId(for: a.workspaceMonitor),
            gap: .init(workspaceName: d.name, isAfter: true, collectionId: "ungrouped-meanwhile")))
        XCTAssertEqual(pins(), ["a", "b", "c"])
    }

    func testUndoPutsThePinsBackInTheirOrder() throws {
        let (a, _, c, _) = try tabs()
        let before = WorkspaceSidebarTabUndoSnapshot()
        try applyWorkspaceSidebarPinnedTabDrop(c, .rearrange(.init(workspaceName: a.name, isAfter: false)))
        WorkspaceSidebarTabUndo.shared.record(workspaceSidebarPinnedTabDropUndoTitle(.rearrange(.init(workspaceName: a.name,
            isAfter: false))), before: before)
        XCTAssertEqual(WorkspaceSidebarTabUndo.shared.title, "Undo Move Tab")
        try WorkspaceSidebarTabUndo.shared.undo()
        XCTAssertEqual(pins(), ["a", "b", "c"])
    }

    func testArrangedPinsSurviveReloadAndOlderFilesStillLoad() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("organization.json")
        let store = WorkspaceSidebarOrganizationStore(url: url)
        try store.update { $0.workspaces["a"] = .init(isFavorite: true, pinOrder: 1); $0.workspaces["b"] = .init(isFavorite: true, pinOrder: 0) }
        XCTAssertEqual(WorkspaceSidebarOrganizationStore.load(url: url).state, store.state)
        try Data(#"{"version":1,"collections":[],"workspaces":{"a":{"isFavorite":true}}}"#.utf8).write(to: url)
        let older = WorkspaceSidebarOrganizationStore.load(url: url)
        XCTAssertNil(older.readOnlyReason)
        XCTAssertEqual(older.state.workspaces["a"], .init(isFavorite: true))
    }

    func testEachPinnedTileTakesDropsAsATabAndTheRestOfTheLastRowPutsATabLast() throws {
        // Two columns of 96 points, 8 apart; c is alone on the second row.
        let frame = CGRect(x: 0, y: 0, width: 200, height: 116)
        let targets = workspaceSidebarPinnedDropTargets(names: ["a", "b", "c"], projectId: "p", monitorScopeId: "s",
            frame: frame, columns: 2)
        func hit(_ x: CGFloat, _ y: CGFloat) -> WorkspaceSidebarDropTargetFrame? {
            workspaceSidebarLocalDropTarget(at: CGPoint(x: x, y: y), targets: targets, surface: frame.insetBy(dx: -20, dy: -20))
        }
        XCTAssertEqual(hit(10, 20)?.kind, .workspace("a"))
        XCTAssertEqual(hit(99, 20)?.kind, .workspace("a"), "The space between tiles splits between them")
        XCTAssertEqual(hit(102, 20)?.kind, .workspace("b"))
        XCTAssertEqual(hit(20, 100)?.kind, .workspace("c"))
        XCTAssertEqual(hit(160, 100)?.kind, .pinnedTabs(projectId: "p", gap: .init(workspaceName: "c", isAfter: true),
            monitorScopeId: "s"),
            "The empty cell after the last pin puts a tab last")
        let tile = try XCTUnwrap(hit(10, 20))
        XCTAssertTrue(tile.acceptsSides, "A pause over a tile arms a split")
        XCTAssertEqual(tile.tabReorderDestination?.arrangesPins, true)
        XCTAssertEqual(tile.frame, CGRect(x: -4, y: -4, width: 104, height: 62))
        let rect = Rect(topLeftX: -4, topLeftY: -4, width: 104, height: 62)
        XCTAssertEqual(tile.tabReorderDestination?.reorderTarget(beside: "a", rect: rect, point: CGPoint(x: 20, y: 50)),
            .pinnedTabs(projectId: "p", gap: .init(workspaceName: "a", isAfter: false), monitorScopeId: "s"),
            "Moving past it goes by its nearer side")
        XCTAssertEqual(tile.tabReorderDestination?.reorderTarget(beside: "a", rect: rect, point: CGPoint(x: 80, y: 5)),
            .pinnedTabs(projectId: "p", gap: .init(workspaceName: "a", isAfter: true), monitorScopeId: "s"))
        let full = workspaceSidebarPinnedDropTargets(names: ["a", "b"], projectId: "p", monitorScopeId: "s",
            frame: CGRect(x: 0, y: 0, width: 200, height: 54), columns: 2)
        XCTAssertEqual(full.count, 2, "A full last row has no space after it")
    }

    func testAWindowFromTheScreenHitsThePinUnderThePointerDespiteTheSlop() {
        // A screen drag's slop (12 and 14 points) reaches past each tile into its neighbors.
        let frame = CGRect(x: 0, y: 0, width: 200, height: 116)
        let targets = workspaceSidebarPinnedDropTargets(names: ["a", "b", "c"], projectId: "p", monitorScopeId: "s",
            frame: frame, columns: 2)
        let slop = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        func screenHit(_ x: CGFloat, _ y: CGFloat) -> WorkspaceSidebarDropTargetKind? {
            workspaceSidebarLocalDropTarget(at: CGPoint(x: x, y: y), targets: targets, surface: frame.insetBy(dx: -40, dy: -40),
                hitSlop: slop, includesTabGaps: false)?.kind
        }
        XCTAssertEqual(screenHit(90, 20), .workspace("a"), "Not b, whose slop reaches in")
        XCTAssertEqual(screenHit(20, 50), .workspace("a"), "Not c below")
        XCTAssertEqual(screenHit(90, 100), .workspace("c"), "Not the space after it, which a screen window doesn't take")
        XCTAssertNil(screenHit(170, 100))
        XCTAssertEqual(screenHit(20, 124), .workspace("c"), "Just below the tiles, the slop still reaches the nearest")
    }

    func testAFullLastRowHasNoSpaceAfterItAtAnyWidth() {
        for width in stride(from: CGFloat(150), through: 330, by: 0.5) {
            let columns = WorkspaceSidebarPinnedGridLayout(workspaces: [], width: width).columns
            let names = (0..<(2 * columns)).map { "pin\($0)" }
            let targets = workspaceSidebarPinnedDropTargets(names: names, projectId: "p", monitorScopeId: "s",
                frame: CGRect(x: 0, y: 0, width: width, height: 116), columns: columns)
            XCTAssertFalse(targets.contains { $0.kind.isGap }, "width \(width), \(columns) columns")
        }
    }

    func testAWindowPausedOverAPinSplitsWithItAndMovingOnRearranges() async throws {
        let (a, _, _, d) = try tabs()
        let window = try XCTUnwrap(d.allLeafWindowsRecursive.first)
        let tile = pinTile(a)
        defer { WorkspaceSidebarTabSplitHoverController.shared.reset() }
        let moving = try XCTUnwrap(workspaceSidebarDeliberateTabDropTarget(tile, sourceWindow: window, point: CGPoint(x: 45, y: 27)))
        XCTAssertEqual(moving.kind, .pinnedTabs(projectId: a.projectId, gap: .init(workspaceName: a.name, isAfter: false),
            monitorScopeId: "s"),
            "Moving, it would be pinned before the tile")
        try await Task.sleep(for: .milliseconds(300))
        let armed = try XCTUnwrap(workspaceSidebarDeliberateTabDropTarget(tile, sourceWindow: window, point: CGPoint(x: 45, y: 27)))
        XCTAssertEqual(armed.kind, .workspace(a.name), "After a pause over its middle, it joins the pin")
        XCTAssertTrue(armed.acceptsSides)
        previewWorkspaceSidebarDrop(window.windowId, subject: .window, target: armed.kind, placement: .left)
        XCTAssertEqual(TrayMenuModel.shared.workspaceSidebarDropPreview?.targetWorkspaceName, a.name)
        XCTAssertEqual(TrayMenuModel.shared.workspaceSidebarDropPreview?.targetPlacement, .left)

        applyTabDrop(sourceNode: window, sourceWindow: window, targetWorkspace: a, placement: .left)
        XCTAssertEqual(a.allLeafWindowsRecursive.map(\.windowId), [4, 1], "Split on the side it was dropped")
        XCTAssertEqual(pins(), ["a", "b", "c"], "The pin keeps its place")

        let empty = Workspace.get(byName: "empty")
        try setWorkspaceSidebarTabFavorite(empty, true)
        _ = workspaceSidebarDeliberateTabDropTarget(pinTile(empty), sourceWindow: window, point: CGPoint(x: 60, y: 27))
        try await Task.sleep(for: .milliseconds(300))
        let intoEmpty = try XCTUnwrap(workspaceSidebarDeliberateTabDropTarget(pinTile(empty), sourceWindow: window,
            point: CGPoint(x: 60, y: 27)))
        XCTAssertEqual(intoEmpty.kind, .workspace(empty.name))
        XCTAssertFalse(intoEmpty.acceptsSides, "An empty pin has no window to go beside; the window goes into it")
    }

    func testAPinnedTabDraggedOverAnotherPinRearrangesInsteadOfSplitting() throws {
        let (a, b, _, _) = try tabs()
        let pin = WorkspaceSidebarTabReorderDestination(projectId: a.projectId, monitorScopeId: "s", collectionId: nil,
            arrangesPins: true)
        XCTAssertEqual(drop(b, .workspace(a.name), left: true, reorder: pin),
            .rearrange(.init(workspaceName: a.name, isAfter: false), monitorScopeId: "s"))
        XCTAssertNil(drop(b, .workspace(a.name), reorder: pin), "b already follows a")
    }

    // MARK: A list tab dropped among the pins

    /// Alan, October 2026: a tab dragged onto the pins split with a pin unless it was dropped on
    /// one precise spot. A hand slows down and rests a moment before it lets go, and that rest is
    /// the pause that arms a split. Near a tile's sides the tab is pinned beside the tile, however
    /// long it rests there, on the first row and the next alike.
    func testATabRestingNearAPinsSideIsPinnedBesideItInsteadOfSplittingIt() async throws {
        let (a, _, _, d) = try tabs()
        try pinE()
        let (targets, tiles) = try renderedPins(["a", "b", "c", "e"])
        let window = try XCTUnwrap(d.allLeafWindowsRecursive.first)
        defer { WorkspaceSidebarTabSplitHoverController.shared.reset() }
        let (tileA, tileB, tileC, tileE) = (tiles[0], tiles[1], tiles[2], tiles[3])
        XCTAssertEqual(tileE.minX, tileA.minX, "Three pins fit a row at the default width; e wraps")
        let ab = tileA.maxX, bc = tileB.maxX
        let places: [(CGPoint, String, Bool)] = [
            (CGPoint(x: tileA.minX + 12, y: tileA.midY), "a", false),
            (CGPoint(x: ab - 20, y: tileA.midY), "a", true),
            (CGPoint(x: ab - 10, y: tileA.midY), "a", true),
            (CGPoint(x: ab + 10, y: tileB.midY), "b", false),
            (CGPoint(x: ab + 20, y: tileB.midY), "b", false),
            (CGPoint(x: bc - 12, y: tileB.midY), "b", true),
            (CGPoint(x: bc + 12, y: tileC.midY), "c", false),
            (CGPoint(x: tileC.maxX - 12, y: tileC.midY), "c", true),
            (CGPoint(x: tileE.minX + 12, y: tileE.midY), "e", false),
        ]
        for (point, name, isAfter) in places {
            let drop = try await settledDrop(window, at: point, in: targets)
            XCTAssertEqual(drop?.kind, .pinnedTabs(projectId: a.projectId, gap: .init(workspaceName: name, isAfter: isAfter),
                monitorScopeId: pinScope), "Resting at \(point): pinned \(isAfter ? "after" : "before") \(name)")
        }
    }

    /// A hand's jitter where two tiles meet, near a tile's side, or where its middle begins never
    /// splits the pin. A pause over the middle does, as before; moving out to the side pins the tab
    /// beside the tile again, until the next pause over the middle.
    func testJitterNearAPinsSideNeverSplitsItButAPauseOverItsMiddleDoes() async throws {
        let (a, _, _, d) = try tabs()
        let (targets, tiles) = try renderedPins(["a", "b", "c"])
        let window = try XCTUnwrap(d.allLeafWindowsRecursive.first)
        defer { WorkspaceSidebarTabSplitHoverController.shared.reset() }
        let tileB = tiles[1]
        let afterA = WorkspaceSidebarDropTargetKind.pinnedTabs(projectId: a.projectId,
            gap: .init(workspaceName: "a", isAfter: true), monitorScopeId: pinScope)
        let beforeB = WorkspaceSidebarDropTargetKind.pinnedTabs(projectId: a.projectId,
            gap: .init(workspaceName: "b", isAfter: false), monitorScopeId: pinScope)
        // Under 2 points either way, a hand at rest, for half a second.
        for x in [tileB.minX, tileB.minX + 10, tileB.minX + tileB.width / 3] {
            WorkspaceSidebarTabSplitHoverController.shared.reset()
            for step in 0 ..< 15 {
                let point = CGPoint(x: x + (step.isMultiple(of: 2) ? 0.75 : -0.75), y: tileB.midY)
                let kind = resolve(window, at: point, in: targets)?.kind
                XCTAssertTrue(kind == afterA || kind == beforeB, "Jittering at \(point): \(String(describing: kind))")
                try await Task.sleep(for: .milliseconds(35))
            }
        }
        let middle = CGPoint(x: tileB.midX - 6, y: tileB.midY)
        WorkspaceSidebarTabSplitHoverController.shared.reset()
        XCTAssertEqual(resolve(window, at: middle, in: targets)?.kind, beforeB, "Moving over the middle, it's still pinned beside b")
        try await Task.sleep(for: .milliseconds(300))
        let split = try XCTUnwrap(resolve(window, at: middle, in: targets))
        XCTAssertEqual(split.kind, .workspace("b"), "Paused over the middle, it tiles into b")
        XCTAssertTrue(split.acceptsSides)
        XCTAssertEqual(resolve(window, at: CGPoint(x: tileB.minX + 10, y: tileB.midY), in: targets)?.kind, beforeB,
            "Out at b's side, it's pinned beside b again")
        XCTAssertEqual(resolve(window, at: middle, in: targets)?.kind, beforeB, "Back over the middle, it needs another pause")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(resolve(window, at: middle, in: targets)?.kind, .workspace("b"))
    }

    /// The release makes the drop shown, though the hand slips a point as it lets go, and moves
    /// each window once: the tab pinned whole beside b, or, after a pause over b's middle, tiled into b.
    func testTheReleaseMakesTheDropShownAndMovesEachWindowOnce() async throws {
        for splits in [false, true] {
            try await setUp()
            let (_, b, _, d) = try tabs()
            let (targets, tiles) = try renderedPins(["a", "b", "c"])
            let window = try XCTUnwrap(d.allLeafWindowsRecursive.first)
            let tileB = tiles[1]
            let point = CGPoint(x: splits ? tileB.midX - 6 : tileB.minX + 10, y: tileB.midY)
            let settled = try await settledDrop(window, at: point, in: targets)
            let shown = try XCTUnwrap(settled)
            let placement: WorkspaceSidebarTabDropPlacement? = shown.acceptsSides
                ? (point.x < shown.rect.center.x ? .left : .right) : nil
            let controller = WorkspaceSidebarTabSplitHoverController.shared
            let hit = try XCTUnwrap(target(at: point, in: targets))
            controller.noteDisplayed(source: window.windowId, hitKind: hit.kind, target: shown, placement: placement)
            let release = CGPoint(x: point.x + 1, y: point.y + 1)
            let releaseHit = try XCTUnwrap(target(at: release, in: targets))
            let committed = try XCTUnwrap(controller.commitTarget(source: window.windowId, hitTarget: releaseHit, point: release))
            XCTAssertEqual(committed.kind, shown.kind, "The drop made is the one shown")
            let intent = try XCTUnwrap(WorkspaceSidebarDropIntent.captured(for: committed,
                source: .init(window: window, subject: .window)))
            _ = await queueWorkspaceSidebarDrop(window.windowId, subject: .window, target: committed.kind, placement: placement,
                intent: intent)?.value
            if splits {
                XCTAssertEqual(b.allLeafWindowsRecursive.map(\.windowId), [4, 2], "Tiled into b, on the left")
                XCTAssertEqual(pins(), ["a", "b", "c"], "b stays pinned in its place")
            } else {
                XCTAssertEqual(pins(), ["a", "d", "b", "c"], "Pinned before b")
                XCTAssertEqual(d.allLeafWindowsRecursive.map(\.windowId), [4], "Whole, in its own tab")
                XCTAssertEqual(b.allLeafWindowsRecursive.map(\.windowId), [2], "b isn't split")
            }
            let windows = ["a", "b", "c", "d"].flatMap { Workspace.existing(byName: $0)?.allLeafWindowsRecursive ?? [] }
            XCTAssertEqual(windows.map(\.windowId).sorted(), [1, 2, 3, 4], "Every window once")
            controller.reset()
        }
    }

    /// A drag given up with Escape after a pause armed a split changes nothing, and the next one
    /// needs its own pause.
    func testADragGivenUpChangesNothingAndTheNextOneNeedsItsOwnPause() async throws {
        let (a, b, _, d) = try tabs()
        let (targets, tiles) = try renderedPins(["a", "b", "c"])
        let window = try XCTUnwrap(d.allLeafWindowsRecursive.first)
        let middle = CGPoint(x: tiles[1].midX - 6, y: tiles[1].midY)
        WorkspaceSidebarDragSessions.shared.noteLeftMouseDown()
        XCTAssertTrue(WorkspaceSidebarDragSessions.shared.acceptUpdate())
        let armed = try await settledDrop(window, at: middle, in: targets)
        XCTAssertEqual(armed?.kind, .workspace("b"))
        XCTAssertTrue(cancelWorkspaceSidebarDragSession())
        XCTAssertEqual(pins(), ["a", "b", "c"])
        XCTAssertEqual(b.allLeafWindowsRecursive.map(\.windowId), [2])
        XCTAssertEqual(d.allLeafWindowsRecursive.map(\.windowId), [4])
        WorkspaceSidebarDragSessions.shared.noteLeftMouseDown()
        XCTAssertTrue(WorkspaceSidebarDragSessions.shared.acceptUpdate())
        defer { _ = cancelWorkspaceSidebarDragSession() }
        XCTAssertEqual(resolve(window, at: middle, in: targets)?.kind, .pinnedTabs(projectId: a.projectId,
            gap: .init(workspaceName: "b", isAfter: false), monitorScopeId: pinScope))
    }

    func testRenderedPinsTakeDropsBesideEachTileAndMarkWhereTheTabGoes() throws {
        var fixture = WorkspaceSidebarSnapshot.empty
        fixture.configuration = WorkspaceSidebarConfiguration(collapsedWidth: 44, expandedWidth: 280,
            topPadding: 12, showMonitorSelector: false, showsClock: false, showsSeconds: false,
            showsDate: false, showsWeekday: false, showsStatusPills: false, chromeStyle: .solid, solidChromeColor: .midnight,
            solidChromeCustomColor: "#191B20", showAppIcons: false, usesTabsList: true, alwaysExpanded: true)
        fixture.visibleWidth = 280
        fixture.targetMonitorScopeId = "monitor:0,0"
        fixture.projects = [.init(id: workspaceProjectDefaultId, displayName: "Research", colorHex: nil, emoji: nil)]
        fixture.workspaces = ["one", "two", "three"].enumerated().map { index, name in
            let window = WorkspaceSidebarWindowViewModel(windowId: UInt32(index + 1), workspaceName: name, appName: "Safari",
                appBundleId: "com.apple.Safari", appBundlePath: nil, title: name, isFocused: index == 2)
            return .init(name: name, projectId: workspaceProjectDefaultId, displayName: name, sidebarLabel: "",
                isGeneratedName: true, monitorScopeId: "monitor:0,0", monitorName: nil, isFocused: index == 2,
                isVisible: index == 2, items: [.init(kind: .window(window))],
                appearance: .init(isFavorite: index < 2, pinOrder: index == 0 ? 1 : 0))
        }
        let targets = try renderedDropTargets(fixture)
        let tiles = targets.filter { $0.tabReorderDestination?.arrangesPins == true }
        XCTAssertEqual(tiles.map(\.kind), [.workspace("two"), .workspace("one")], "In the arranged order")
        XCTAssertTrue(tiles.allSatisfy(\.acceptsSides))
        XCTAssertLessThan(tiles[0].frame.minX, tiles[1].frame.minX)
        XCTAssertEqual(tiles[0].tabReorderDestination?.monitorScopeId, "monitor:0,0")
        let last = try XCTUnwrap(targets.first { $0.kind == .pinnedTabs(projectId: workspaceProjectDefaultId,
            gap: .init(workspaceName: "one", isAfter: true), monitorScopeId: "monitor:0,0") },
            "The rest of the last row puts a tab last, on this display's list")
        XCTAssertGreaterThanOrEqual(last.frame.minX, tiles[1].frame.maxX)
        XCTAssertFalse(targets.contains { if case .pinnedTabs(_, nil, _, _) = $0.kind { true } else { false } },
            "Beside a pin is the only place among the pins")

        var preview = WorkspaceSidebarDropPreviewViewModel(sourceWindowId: 3, label: "three", appName: "Safari",
            targetWorkspaceName: nil, targetsNewWorkspace: false, targetProjectId: workspaceProjectDefaultId,
            isTabGroup: false, windowCount: 1)
        preview.targetsPinned = true
        preview.targetPinnedGap = .init(workspaceName: "one", isAfter: false)
        XCTAssertEqual(workspaceSidebarPinnedInsertionEdge(preview, workspaceName: "one", projectId: workspaceProjectDefaultId),
            .leading)
        XCTAssertNil(workspaceSidebarPinnedInsertionEdge(preview, workspaceName: "two", projectId: workspaceProjectDefaultId))
        XCTAssertNil(workspaceSidebarPinnedInsertionEdge(preview, workspaceName: "one", projectId: "another"))
    }

    func testWithEveryTabPinnedTheRenderedListStillTakesAPin() throws {
        var fixture = WorkspaceSidebarSnapshot.empty
        fixture.configuration = WorkspaceSidebarConfiguration(collapsedWidth: 44, expandedWidth: 280,
            topPadding: 12, showMonitorSelector: false, showsClock: false, showsSeconds: false,
            showsDate: false, showsWeekday: false, showsStatusPills: false, chromeStyle: .solid, solidChromeColor: .midnight,
            solidChromeCustomColor: "#191B20", showAppIcons: false, usesTabsList: true, alwaysExpanded: true)
        fixture.visibleWidth = 280
        fixture.targetMonitorScopeId = "monitor:0,0"
        fixture.projects = [.init(id: workspaceProjectDefaultId, displayName: "Research", colorHex: nil, emoji: nil)]
        fixture.workspaces = ["one", "two"].enumerated().map { index, name in
            let window = WorkspaceSidebarWindowViewModel(windowId: UInt32(index + 1), workspaceName: name, appName: "Safari",
                appBundleId: "com.apple.Safari", appBundlePath: nil, title: name, isFocused: index == 0)
            return .init(name: name, projectId: workspaceProjectDefaultId, displayName: name, sidebarLabel: "",
                isGeneratedName: true, monitorScopeId: "monitor:0,0", monitorName: nil, isFocused: index == 0,
                isVisible: index == 0, items: [.init(kind: .window(window))], appearance: .init(isFavorite: true))
        }
        let targets = try renderedDropTargets(fixture)
        let tail = try XCTUnwrap(targets.first { target in
            guard case .tabGap(workspaceProjectDefaultId, _, let gap) = target.kind else { return false }
            return gap == .init(workspaceName: "two", isAfter: true)
        }, "The empty list takes a pin, after the last one")
        XCTAssertGreaterThan(tail.frame.height, workspaceSidebarTabRowHeight - 1)
    }

    private func sidebarTabs(_ workspaces: [Workspace]) -> [WorkspaceSidebarWorkspaceViewModel] {
        workspaces.map { workspace in
            .init(name: workspace.name, projectId: workspace.projectId, displayName: workspace.name, sidebarLabel: "",
                isGeneratedName: true, monitorScopeId: "monitor:0,0", monitorName: nil, isFocused: false, isVisible: false,
                items: [], appearance: workspaceSidebarOrganizationStore.state.workspaces[workspace.name] ?? .init())
        }
    }

    private func renderedDropTargets(_ fixture: WorkspaceSidebarSnapshot) throws -> [WorkspaceSidebarDropTargetFrame] {
        let probe = PinnedDropTargetProbe()
        let view = WorkspaceSidebarView(snapshot: fixture, reduceMotionOverride: true, reduceTransparencyOverride: true)
        let host = NSHostingView(rootView: view.sidebarContent(expansionProgress: 1, layout: fixture.configuration)
            .coordinateSpace(name: "workspaceSidebarContent")
            .onPreferenceChange(WorkspaceSidebarDropTargetPreferenceKey.self) { probe.targets = $0 }
            .frame(width: 280, height: 620))
        host.frame = CGRect(x: 0, y: 0, width: 280, height: 620)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        host.layoutSubtreeIfNeeded()
        return probe.targets
    }

    private let pinScope = "monitor:0.0,0.0"

    /// Tab e, with window 5, pinned after a, b and c.
    @discardableResult
    private func pinE() throws -> Workspace {
        let e = Workspace.get(byName: "e")
        _ = TestWindow.new(id: 5, parent: e.rootTilingContainer)
        try setWorkspaceSidebarTabFavorite(e, true)
        return e
    }

    /// The drop targets of a Tabs sidebar at the default 280 points, with `names` pinned in that
    /// order and d in the list, and the pin tiles' frames among them.
    private func renderedPins(_ names: [String]) throws -> (targets: [WorkspaceSidebarDropTargetFrame], tiles: [CGRect]) {
        var fixture = WorkspaceSidebarSnapshot.empty
        fixture.configuration = WorkspaceSidebarConfiguration(collapsedWidth: 44, expandedWidth: 280,
            topPadding: 12, showMonitorSelector: false, showsClock: false, showsSeconds: false,
            showsDate: false, showsWeekday: false, showsStatusPills: false, chromeStyle: .solid, solidChromeColor: .midnight,
            solidChromeCustomColor: "#191B20", showAppIcons: false, usesTabsList: true, alwaysExpanded: true)
        fixture.visibleWidth = 280
        fixture.targetMonitorScopeId = pinScope
        fixture.projects = [.init(id: workspaceProjectDefaultId, displayName: "Research", colorHex: nil, emoji: nil)]
        fixture.workspaces = (names + ["d"]).enumerated().map { index, name in
            let window = WorkspaceSidebarWindowViewModel(windowId: UInt32(100 + index), workspaceName: name, appName: "Notes",
                appBundleId: "com.apple.Notes", appBundlePath: nil, title: name, isFocused: false)
            return .init(name: name, projectId: workspaceProjectDefaultId, displayName: name, sidebarLabel: "",
                isGeneratedName: true, monitorScopeId: pinScope, monitorName: nil, isFocused: false, isVisible: false,
                items: [.init(kind: .window(window))],
                appearance: name == "d" ? .init() : .init(isFavorite: true, pinOrder: index))
        }
        let targets = try renderedDropTargets(fixture)
        let tiles = targets.filter { $0.tabReorderDestination?.arrangesPins == true }
        XCTAssertEqual(tiles.map(\.kind), names.map { .workspace($0) })
        return (targets, tiles.map(\.frame))
    }

    /// What the sidebar finds under `point`, as a drag gets it.
    private func target(at point: CGPoint, in targets: [WorkspaceSidebarDropTargetFrame]) -> WorkspaceSidebarDropTarget? {
        workspaceSidebarLocalDropTarget(at: point, targets: targets, surface: CGRect(x: 0, y: 0, width: 280, height: 620)).map {
            WorkspaceSidebarDropTarget(kind: $0.kind, rect: Rect(topLeftX: $0.frame.minX, topLeftY: $0.frame.minY,
                width: $0.frame.width, height: $0.frame.height), acceptsSides: $0.acceptsSides,
                tabReorderDestination: $0.tabReorderDestination)
        }
    }

    /// The drop `window`'s drag shows with the pointer at `point`, as each drag event resolves it.
    private func resolve(_ window: AppBundle.Window, at point: CGPoint,
                         in targets: [WorkspaceSidebarDropTargetFrame]) -> WorkspaceSidebarDropTarget? {
        guard let target = target(at: point, in: targets) else {
            WorkspaceSidebarTabSplitHoverController.shared.reset()
            return nil
        }
        return workspaceSidebarDeliberateTabDropTarget(target, sourceWindow: window, point: point)
    }

    /// The drop shown once `window`'s tab, dragged up onto the pins, slows to a stop at `point` and
    /// rests there a moment, as a hand does before it lets go.
    private func settledDrop(_ window: AppBundle.Window, at point: CGPoint,
                             in targets: [WorkspaceSidebarDropTargetFrame]) async throws -> WorkspaceSidebarDropTarget? {
        WorkspaceSidebarTabSplitHoverController.shared.reset()
        for rise in [20, 12, 6, 3, 1.5, 0.5] as [CGFloat] {
            _ = resolve(window, at: CGPoint(x: point.x, y: point.y + rise), in: targets)
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = resolve(window, at: point, in: targets)
        try await Task.sleep(for: .milliseconds(300))
        return resolve(window, at: point, in: targets)
    }
}

private extension WorkspaceSidebarDropTargetKind {
    func withGap(_ gap: WorkspaceSidebarTabGap) -> Self {
        guard case .tabGap(let projectId, let monitorScopeId, _) = self else { return self }
        return .tabGap(projectId: projectId, monitorScopeId: monitorScopeId, gap: gap)
    }
}

@MainActor
private final class PinnedDropTargetProbe {
    var targets: [WorkspaceSidebarDropTargetFrame] = []
}
