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
        XCTAssertEqual(drop(c, .workspace(d.name), lower: true, reorder: row),
            .list(projectId: c.projectId, monitorScopeId: scope, gap: .init(workspaceName: d.name, isAfter: true)),
            "Over a tab, it goes by the nearer edge")
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
        XCTAssertEqual(drop(b, .newWorkspace(projectId: b.projectId, monitorScopeId: "s")), .unpin)
        XCTAssertNil(drop(b, .newWorkspace(projectId: "another", monitorScopeId: "s")))
        XCTAssertTrue(workspaceSidebarPinnedTabDropPreview(b, drop: .unpin).targetsNewWorkspace)
        try applyWorkspaceSidebarPinnedTabDrop(b, .unpin)
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
        XCTAssertEqual(hit(160, 100)?.kind, .pinnedTabs(projectId: "p", gap: .init(workspaceName: "c", isAfter: true)),
            "The empty cell after the last pin puts a tab last")
        let tile = try XCTUnwrap(hit(10, 20))
        XCTAssertTrue(tile.acceptsSides, "A pause over a tile arms a split")
        XCTAssertEqual(tile.tabReorderDestination?.arrangesPins, true)
        XCTAssertEqual(tile.frame, CGRect(x: -4, y: -4, width: 104, height: 62))
        let rect = Rect(topLeftX: -4, topLeftY: -4, width: 104, height: 62)
        XCTAssertEqual(tile.tabReorderDestination?.reorderTarget(beside: "a", rect: rect, point: CGPoint(x: 20, y: 50)),
            .pinnedTabs(projectId: "p", gap: .init(workspaceName: "a", isAfter: false)), "Moving past it goes by its nearer side")
        XCTAssertEqual(tile.tabReorderDestination?.reorderTarget(beside: "a", rect: rect, point: CGPoint(x: 80, y: 5)),
            .pinnedTabs(projectId: "p", gap: .init(workspaceName: "a", isAfter: true)))
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
        let moving = try XCTUnwrap(workspaceSidebarDeliberateTabDropTarget(tile, sourceWindow: window, point: CGPoint(x: 20, y: 27)))
        XCTAssertEqual(moving.kind, .pinnedTabs(projectId: a.projectId, gap: .init(workspaceName: a.name, isAfter: false)),
            "Moving, it would be pinned before the tile")
        try await Task.sleep(for: .milliseconds(300))
        let armed = try XCTUnwrap(workspaceSidebarDeliberateTabDropTarget(tile, sourceWindow: window, point: CGPoint(x: 20, y: 27)))
        XCTAssertEqual(armed.kind, .workspace(a.name), "After a pause, it joins the pin")
        XCTAssertTrue(armed.acceptsSides)
        previewWorkspaceSidebarDrop(window.windowId, subject: .window, target: armed.kind, placement: .left)
        XCTAssertEqual(TrayMenuModel.shared.workspaceSidebarDropPreview?.targetWorkspaceName, a.name)
        XCTAssertEqual(TrayMenuModel.shared.workspaceSidebarDropPreview?.targetPlacement, .left)

        applyTabDrop(sourceNode: window, sourceWindow: window, targetWorkspace: a, placement: .left)
        XCTAssertEqual(a.allLeafWindowsRecursive.map(\.windowId), [4, 1], "Split on the side it was dropped")
        XCTAssertEqual(pins(), ["a", "b", "c"], "The pin keeps its place")

        let empty = Workspace.get(byName: "empty")
        try setWorkspaceSidebarTabFavorite(empty, true)
        _ = workspaceSidebarDeliberateTabDropTarget(pinTile(empty), sourceWindow: window, point: CGPoint(x: 80, y: 27))
        try await Task.sleep(for: .milliseconds(300))
        let intoEmpty = try XCTUnwrap(workspaceSidebarDeliberateTabDropTarget(pinTile(empty), sourceWindow: window,
            point: CGPoint(x: 80, y: 27)))
        XCTAssertEqual(intoEmpty.kind, .workspace(empty.name))
        XCTAssertFalse(intoEmpty.acceptsSides, "An empty pin has no window to go beside; the window goes into it")
    }

    func testAPinnedTabDraggedOverAnotherPinRearrangesInsteadOfSplitting() throws {
        let (a, b, _, _) = try tabs()
        let pin = WorkspaceSidebarTabReorderDestination(projectId: a.projectId, monitorScopeId: "s", collectionId: nil,
            arrangesPins: true)
        XCTAssertEqual(drop(b, .workspace(a.name), left: true, reorder: pin), .rearrange(.init(workspaceName: a.name, isAfter: false)))
        XCTAssertNil(drop(b, .workspace(a.name), reorder: pin), "b already follows a")
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
            gap: .init(workspaceName: "one", isAfter: true)) }, "The rest of the last row puts a tab last")
        XCTAssertGreaterThanOrEqual(last.frame.minX, tiles[1].frame.maxX)
        XCTAssertFalse(targets.contains { $0.kind == .pinnedTabs(projectId: workspaceProjectDefaultId) },
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
