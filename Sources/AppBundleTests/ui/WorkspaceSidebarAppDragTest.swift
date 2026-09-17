@testable import AppBundle
import AppKit
import XCTest

@MainActor
final class WorkspaceSidebarAppDragTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }
    override func tearDown() async throws { setMonitorsForTests(nil) }

    func testDragPinsItsInitialWindowWhenFocusChanges() {
        var resolved: UInt32 = 1
        var resolutions = 0
        var changed: [UInt32] = []
        var ended: [UInt32] = []
        let actions = WorkspaceSidebarActions(
            resolveAppDragWindow: { workspace, app in
                XCTAssertEqual(workspace, "source")
                XCTAssertEqual(app, "bundle:test")
                resolutions += 1
                return resolved
            },
            windowDragChanged: { id, _ in changed.append(id) },
            windowDragEnded: { id, _ in ended.append(id) }
        )
        var drag = WorkspaceSidebarAppDragSession()
        drag.update(workspaceName: "source", appId: "bundle:test", pointer: .zero, actions: actions)
        resolved = 2
        drag.update(workspaceName: "source", appId: "bundle:test", pointer: CGPoint(x: 100, y: 100), actions: actions)
        drag.finish(pointer: CGPoint(x: 200, y: 100), actions: actions)
        drag.finish(pointer: .zero, actions: actions)
        XCTAssertEqual(resolutions, 1)
        XCTAssertEqual(changed, [1, 1])
        XCTAssertEqual(ended, [1])
        XCTAssertNil(drag.windowId)

        drag.update(workspaceName: "source", appId: "bundle:test", pointer: .zero, actions: actions)
        XCTAssertEqual(drag.windowId, 2, "A new gesture resolves the current window again")
    }

    func testMissingWindowDoesNotStartDraggingAnotherWindowMidGesture() {
        var candidate: UInt32?
        var changes = 0
        var finishes = 0
        let actions = WorkspaceSidebarActions(
            resolveAppDragWindow: { _, _ in candidate },
            windowDragChanged: { _, _ in changes += 1 },
            windowDragEnded: { _, _ in finishes += 1 }
        )
        var drag = WorkspaceSidebarAppDragSession()
        drag.update(workspaceName: "source", appId: "app", pointer: .zero, actions: actions)
        candidate = 3
        drag.update(workspaceName: "source", appId: "app", pointer: .zero, actions: actions)
        drag.finish(pointer: .zero, actions: actions)
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(finishes, 0)
    }

    func testAdapterResolvesTheSameWindowAsClickWithoutFocusingWorkspace() {
        let workspace = Workspace.get(byName: "source")
        let first = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let second = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        second.markAsMostRecentChild()
        let previousFocus = focus.workspace
        let actions = makeWorkspaceSidebarActionsAdapter()
        let appId = "bundle:bobko.WinMux.test-app"
        XCTAssertEqual(actions.resolveAppDragWindow(workspace.name, appId), second.windowId)
        XCTAssertEqual(focus.workspace, previousFocus)
        first.markAsMostRecentChild()
        XCTAssertEqual(actions.resolveAppDragWindow(workspace.name, appId), first.windowId)
        XCTAssertNil(actions.resolveAppDragWindow("missing", appId))
        XCTAssertNil(actions.resolveAppDragWindow(workspace.name, "bundle:missing"))
    }

    func testDisconnectedPanelCannotStartAppDrag() {
        let workspace = focus.workspace
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let actions = makeWorkspaceSidebarActionsAdapter(targetMonitorScopeId: "missing-display")
        XCTAssertNil(actions.resolveAppDragWindow(workspace.name, "bundle:bobko.WinMux.test-app"))
    }

    func testResolvedAppWindowUsesExistingWorkspaceMoveAndLeavesOtherWindows() {
        let source = focus.workspace
        let target = Workspace.get(byName: "target")
        let first = TestWindow.new(id: 1, parent: source.rootTilingContainer)
        let second = TestWindow.new(id: 2, parent: source)
        second.markAsMostRecentChild()
        let actions = makeWorkspaceSidebarActionsAdapter()
        let id = actions.resolveAppDragWindow(source.name, "bundle:bobko.WinMux.test-app")
        XCTAssertEqual(id, second.windowId)
        applySidebarWorkspaceMove(sourceNode: second, sourceWindow: second, targetWorkspace: target)
        XCTAssertTrue(second.nodeWorkspace === target)
        XCTAssertTrue(first.nodeWorkspace === source)
        XCTAssertTrue(second.isFloating, "Dragging a floating app keeps its layout")
    }
}
