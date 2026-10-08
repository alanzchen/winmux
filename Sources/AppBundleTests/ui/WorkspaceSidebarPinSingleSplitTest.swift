import AppKit
@testable import AppBundle
import Common
import SwiftUI
import XCTest

/// Tabs mode: a pin with one window is the entry to that window alone. A split with it goes to an
/// ordinary tab, and the pin lends its window there, grey, until a click on it brings that same window
/// back. A pinned split is made only from a split tab's menu, and shares its windows with their pins.
@MainActor
final class WorkspaceSidebarPinSingleSplitTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.mode = .tabs
        workspaceSidebarOrganizationStore = .init()
    }

    override func tearDown() async throws {
        WorkspaceSidebarTabSplitHoverController.shared.reset()
        WorkspaceSidebarTabUndo.shared.clear()
        WorkspaceSidebarTabSelection.shared.clear()
        WorkspaceSidebarTabDragState.shared.set(false)
        clearWorkspaceSidebarDropPreview()
        workspaceSidebarOrganizationStore = .init()
        config = defaultConfig
        try await super.tearDown()
    }

    // MARK: 1 and 2: a split with a pin goes to an ordinary tab, and the pin turns grey

    func testAWindowSplitWithAPinGoesToAnOrdinaryTabAndThePinLendsItsWindow() async throws {
        let (a, b, d, e) = try tabs()
        let one = try XCTUnwrap(a.anyLeafWindowRecursive)
        let pinOrder = workspaceSidebarOrganizationStore.state.workspaces["a"]?.pinOrder
        await queueWorkspaceSidebarDrop(4, subject: .window, target: .workspace("a"), placement: .left, intent: .physical)?.value
        XCTAssertEqual(ids(d), [4, 1], "d's own tab takes the split, the dragged window on the half pointed at")
        XCTAssertFalse(workspaceSidebarIsPinned(d), "The split is an ordinary tab")
        XCTAssertEqual(ids(a), [], "The pin isn't turned into a pinned split")
        XCTAssertTrue(workspaceSidebarLentWindow(of: a) === one, "It lends its window, and shows grey")
        XCTAssertEqual(pins(), ["a", "b"], "It keeps its place")
        XCTAssertEqual(workspaceSidebarOrganizationStore.state.workspaces["a"]?.pinOrder, pinOrder)
        XCTAssertEqual(occurrences(of: 1), 1)

        // A window pulled out of a split gets a new ordinary tab with the pin's window.
        await queueWorkspaceSidebarDrop(6, subject: .window, target: .workspace("b"), placement: .right, intent: .physical)?.value
        XCTAssertEqual(ids(e), [5])
        let split = try XCTUnwrap(Workspace.all.first { ids($0) == [2, 6] }, "b's window, then the dragged one")
        XCTAssertFalse(workspaceSidebarIsPinned(split))
        XCTAssertEqual(ids(b), [])
        XCTAssertEqual(workspaceSidebarLentWindow(of: b)?.windowId, 2)

        XCTAssertEqual(WorkspaceSidebarTabUndo.shared.title, "Undo Split Tabs")
        await runWorkspaceSidebarSession { try WorkspaceSidebarTabUndo.shared.undo() }?.value
        XCTAssertEqual(ids(b), [2], "Undo gives the pin its window back")
        XCTAssertEqual(ids(e), [5, 6])
        XCTAssertNil(workspaceSidebarLentWindow(of: b))
    }

    func testAPinDroppedOnAListTabOrAnotherPinSplitsInAnOrdinaryTab() throws {
        let (a, b, d, _) = try tabs()
        try applyWorkspaceSidebarPinnedTabDrop(a, .join("d", placement: .right))
        XCTAssertEqual(ids(d), [4, 1], "a's window goes to d, which stays ordinary")
        XCTAssertFalse(workspaceSidebarIsPinned(d))
        XCTAssertEqual(ids(a), [])
        XCTAssertEqual(workspaceSidebarLentWindow(of: a)?.windowId, 1)

        let c = tab("c", 3)
        try setWorkspaceSidebarTabFavorite(c, true)
        try applyWorkspaceSidebarPinnedTabDrop(c, .split("b", placement: .left, projectId: c.projectId))
        let split = try XCTUnwrap(Workspace.all.first { ids($0) == [3, 2] }, "c's window on the half of b pointed at")
        XCTAssertFalse(workspaceSidebarIsPinned(split), "Two pins split in an ordinary tab, never a pinned split")
        XCTAssertEqual(ids(b), [])
        XCTAssertEqual(ids(c), [])
        XCTAssertEqual(workspaceSidebarLentWindow(of: b)?.windowId, 2)
        XCTAssertEqual(workspaceSidebarLentWindow(of: c)?.windowId, 3)
        XCTAssertEqual(pins(), ["a", "b", "c"])
        XCTAssertEqual([1, 2, 3, 4].map(occurrences(of:)), [1, 1, 1, 1])
    }

    /// Grey is a cue, not disabled: the tile is a button that brings the window back.
    func testAGreyPinIsStillAButtonThatBringsItsWindowBack() async throws {
        try skipWithoutWindowServer()
        var recalls: [UInt32?] = []
        var selects: [UInt32?] = []
        let lent = WorkspaceSidebarWindowViewModel(windowId: 1, workspaceName: "d", appName: "Notes", appBundleId: nil,
            appBundlePath: nil, title: nil, isFocused: false)
        var pin = WorkspaceSidebarWorkspaceViewModel(name: "a", projectId: workspaceProjectDefaultId, displayName: "a",
            sidebarLabel: "", isGeneratedName: true, monitorScopeId: "monitor:0.0,0.0", monitorName: nil, isFocused: false,
            isVisible: false, items: [], appearance: .init(isFavorite: true))
        pin.lentWindow = lent
        pin.recallsWindows = true
        let tile = WorkspaceSidebarPinnedTab(workspace: pin, badgeModel: WorkspaceSidebarDockBadgeModel(),
            onRecall: { recalls.append($0) }) { selects.append($0) }
            .frame(width: 90, height: 54)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 90, height: 54), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: tile)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: 45, y: 27), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(recalls, [nil], "A click brings the window back")
        XCTAssertEqual(selects, [], "Instead of only selecting the empty pin")
    }

    // MARK: 3: a click on a grey pin brings the same window back

    func testClickingAGreyPinBringsBackTheSameWindowAndLeavesTheRestOfTheSplit() async throws {
        let (a, _, d, _) = try tabs()
        let one = try XCTUnwrap(a.anyLeafWindowRecursive)
        _ = TestWindow.new(id: 7, parent: d.rootTilingContainer)
        try splitPinnedTabWindowWithTab(a, "d", placement: .right)
        XCTAssertEqual(ids(d), [4, 7, 1])
        let windowCount = Workspace.all.flatMap(\.allLeafWindowsRecursive).count

        recallPinWindowsFromSidebar("a", focusing: nil, targetMonitorScopeId: nil)
        try await waitUntil { ids(a) == [1] && focus.workspace === a }
        XCTAssertTrue(a.anyLeafWindowRecursive === one, "The same window, not another one")
        XCTAssertEqual(ids(d), [4, 7], "The rest of the split stays, in its order, in its ordinary tab")
        XCTAssertFalse(workspaceSidebarIsPinned(d))
        XCTAssertNil(workspaceSidebarLentWindow(of: a), "No longer grey")
        XCTAssertEqual(Workspace.all.flatMap(\.allLeafWindowsRecursive).count, windowCount, "Nothing opened")
        XCTAssertEqual(occurrences(of: 1), 1)
    }

    func testAnOrdinaryTabTheWindowLeavesEmptyCloses() throws {
        let (a, _, _, _) = try tabs()
        let f = tab("f", 8)
        try splitPinnedTabWindowWithTab(a, "f", placement: .right)
        XCTAssertEqual(ids(f), [8, 1])
        Window.get(byId: 8)?.unbindFromParent()
        XCTAssertEqual(try recallWorkspaceSidebarPinWindows(a), .returned(try XCTUnwrap(Window.get(byId: 1))))
        XCTAssertEqual(ids(a), [1])
        XCTAssertFalse(Workspace.existing(byName: "f").map(workspaceTabIsShown) ?? false, "No empty ordinary tab is listed")
    }

    // MARK: 4: only a split tab's menu pins a split

    func testOnlyTheSplitTabsMenuPinsASplit() async throws {
        let (a, b, d, e) = try tabs()
        let projectId = a.projectId
        // Chosen with another tab, a split dragged onto the pins goes nowhere.
        for name in ["d", "e"] {
            XCTAssertTrue(WorkspaceSidebarTabSelection.shared.handleClick(on: name, modifiers: [.command], order: ["d", "e"],
                active: nil))
        }
        let batch = try XCTUnwrap(WorkspaceSidebarDragBatch(startingWith: "d"))
        XCTAssertFalse(isActionableWorkspaceSidebarBatchDropTarget(batch, target: .pinnedTabs(projectId: projectId,
            gap: .init(workspaceName: "b", isAfter: true))))
        WorkspaceSidebarTabSelection.shared.clear()
        // A tab with one window still pins as it always has.
        await queueWorkspaceSidebarDrop(4, subject: .window, target: .pinnedTabs(projectId: projectId,
            gap: .init(workspaceName: "b", isAfter: true)), placement: nil, intent: .physical)?.value
        XCTAssertEqual(pins(), ["a", "b", "d"])
        XCTAssertEqual(ids(d), [4])

        // The menu's Pin makes a pinned split.
        try setWorkspaceSidebarTabFavorite(e, true)
        XCTAssertEqual(pins(), ["a", "b", "d", "e"])
        XCTAssertEqual(ids(e), [5, 6])
        // A window dropped on it, or a pin paused over it, makes no other.
        XCTAssertFalse(workspaceSidebarTakesSplit(e))
        await queueWorkspaceSidebarDrop(1, subject: .window, target: .workspace("e"), placement: .left, intent: .physical)?.value
        XCTAssertEqual(ids(e), [5, 6])
        XCTAssertEqual(ids(a), [1])
        try applyWorkspaceSidebarPinnedTabDrop(b, .split("e", placement: .left, projectId: projectId))
        XCTAssertEqual(ids(e), [5, 6])
        XCTAssertEqual(ids(b), [2])
    }

    // MARK: 5: a pinned split and the pin of one of its windows share that window

    func testAPinnedSplitAndThePinOfItsWindowShareThatOneWindow() throws {
        let (a, _, d, _) = try tabs()
        let one = try XCTUnwrap(a.anyLeafWindowRecursive)
        try splitPinnedTabWindowWithTab(a, "d", placement: .right)
        try setWorkspaceSidebarTabFavorite(d, true)
        XCTAssertEqual(pins(), ["a", "b", "d"], "The single pin stays beside the pinned split")
        XCTAssertTrue(workspaceSidebarLentWindow(of: a) === one, "Grey while its window is in the pinned split")
        XCTAssertEqual(occurrences(of: 1), 1)

        XCTAssertEqual(try recallWorkspaceSidebarPinWindows(a), .returned(one), "The pin brings back its window alone")
        XCTAssertEqual(ids(a), [1])
        XCTAssertEqual(ids(d), [4], "The pinned split keeps its other window")
        XCTAssertTrue(workspaceSidebarIsPinned(d))
        XCTAssertTrue(workspaceSidebarPinRecallsWindows(d))

        XCTAssertEqual(try recallWorkspaceSidebarPinWindows(d), .recalled([one]), "The pinned split brings it back")
        XCTAssertEqual(ids(d), [4, 1], "Where it was")
        XCTAssertEqual(ids(a), [])
        XCTAssertTrue(workspaceSidebarLentWindow(of: a) === one, "Grey again")
        XCTAssertEqual(occurrences(of: 1), 1, "Never two")

        // A window closed while away is forgotten; the split never opens another.
        XCTAssertEqual(try recallWorkspaceSidebarPinWindows(a), .returned(one))
        one.unbindFromParent()
        XCTAssertFalse(workspaceSidebarPinRecallsWindows(d))
        XCTAssertEqual(try recallWorkspaceSidebarPinWindows(d), .nothing)
        XCTAssertEqual(ids(d), [4])
    }

    // MARK: Reordering stays as it was

    func testAGreyPinRearrangesAndTakesNoSplit() throws {
        let (a, b, d, _) = try tabs()
        try splitPinnedTabWindowWithTab(a, "d", placement: .right)
        try applyWorkspaceSidebarPinnedTabDrop(a, .rearrange(.init(workspaceName: "b", isAfter: true)))
        XCTAssertEqual(pins(), ["b", "a"], "A grey pin rearranges as any pin does")
        XCTAssertEqual(workspaceSidebarLentWindow(of: a)?.windowId, 1)
        XCTAssertFalse(workspaceSidebarTakesSplit(a), "It takes no other window in")
        XCTAssertEqual(workspaceSidebarPinSplitRole(a), .refuses)
        try applyWorkspaceSidebarPinnedTabDrop(b, .split("a", placement: .left, projectId: b.projectId))
        XCTAssertEqual(ids(b), [2])
        XCTAssertEqual(ids(d), [4, 1])
    }

    // MARK: Helpers

    /// Pins a and b, with windows 1 and 2; ordinary tabs d, with window 4, and e, a split of 5 and 6.
    private func tabs() throws -> (a: Workspace, b: Workspace, d: Workspace, e: Workspace) {
        let a = tab("a", 1), b = tab("b", 2), d = tab("d", 4), e = tab("e", 5, 6)
        try setWorkspaceSidebarTabsFavorite([a, b], true)
        return (a, b, d, e)
    }

    private func tab(_ name: String, _ windowIds: UInt32...) -> Workspace {
        let tab = Workspace.get(byName: name)
        for id in windowIds { _ = TestWindow.new(id: id, parent: tab.rootTilingContainer) }
        return tab
    }

    private func pins() -> [String] { workspacePinnedTabs(in: workspaceProjectDefaultId).map(\.name) }

    private func occurrences(of windowId: UInt32) -> Int {
        Workspace.all.flatMap(\.allLeafWindowsRecursive).filter { $0.windowId == windowId }.count
    }

    private func skipWithoutWindowServer() throws {
        _ = NSApplication.shared
        try XCTSkipIf(NSScreen.screens.isEmpty, "Requires a native macOS window server")
    }

    private func waitUntil(_ condition: () -> Bool, timeout: Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
private func ids(_ workspace: Workspace) -> [UInt32] { workspace.allLeafWindowsRecursive.map(\.windowId) }
