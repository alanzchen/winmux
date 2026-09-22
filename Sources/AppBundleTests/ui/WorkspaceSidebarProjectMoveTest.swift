import AppKit
@testable import AppBundle
import Combine
import SwiftUI
import XCTest

@MainActor
final class WorkspaceSidebarProjectMoveTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testMovePreservesWorkspaceIdentityTreeLabelAndFocus() throws {
        let workspace = focus.workspace
        let sourceProject = workspace.projectId
        let root = workspace.rootTilingContainer
        let first = TestWindow.new(id: 701, parent: root)
        let second = TestWindow.new(id: 702, parent: root)
        _ = first.focusWindow()
        try renameWorkspaceForSidebar(workspaceName: workspace.name, displayName: "My Workspace")
        let target = createWorkspaceProject()
        let targetOrder = winMuxWorkspaceState.projectsById[target.id]!.workspaceOrder
        let monitorPoint = workspace.workspaceMonitor.rect.topLeftCorner

        XCTAssertTrue(moveWorkspaceToProject(workspaceName: workspace.name, projectId: target.id))

        XCTAssertTrue(Workspace.existing(byName: workspace.name) === workspace)
        XCTAssertTrue(workspace.rootTilingContainer === root)
        XCTAssertTrue(first.nodeWorkspace === workspace)
        XCTAssertTrue(second.nodeWorkspace === workspace)
        XCTAssertEqual(root.children.map(ObjectIdentifier.init), [first, second].map(ObjectIdentifier.init))
        XCTAssertEqual(config.workspaceSidebar.workspaceLabels[workspace.name], "My Workspace")
        XCTAssertTrue(focus.workspace === workspace)
        XCTAssertEqual(focus.windowOrNil?.windowId, first.windowId)
        XCTAssertEqual(workspace.workspaceMonitor.rect.topLeftCorner, monitorPoint)
        XCTAssertEqual(workspace.projectId, target.id)
        XCTAssertEqual(winMuxWorkspaceState.projectsById[target.id]?.workspaceOrder, targetOrder + [workspace.id])
        XCTAssertFalse(winMuxWorkspaceState.projectsById[sourceProject]!.workspaceOrder.contains(workspace.id))
        XCTAssertEqual(projectWorkspaces(projectId: sourceProject).count, 1,
            "Moving the final workspace leaves a usable empty source project")
        let viewportId = MonitorViewportId(workspace.workspaceMonitor)
        XCTAssertNil(winMuxWorkspaceState.monitorViewportsById[viewportId]?.lastActiveWorkspaceByProject[sourceProject])
        XCTAssertEqual(winMuxWorkspaceState.monitorViewportsById[viewportId]?.lastActiveWorkspaceByProject[target.id], workspace.id)
        Workspace.reconcileWorkspaceState()
        XCTAssertTrue(focus.workspace === workspace)
        XCTAssertEqual(switchWorkspaceProject(sourceProject, on: mainMonitor)?.projectId, sourceProject)
        XCTAssertTrue(switchWorkspaceProject(target.id, on: mainMonitor) === workspace)
    }

    func testMovingHiddenWorkspaceDoesNotActivateItOrReplaceTargetProjectHistory() throws {
        let hidden = focus.workspace
        _ = TestWindow.new(id: 703, parent: hidden.rootTilingContainer)
        let sourceProject = hidden.projectId
        let target = createWorkspaceProject()
        let visible = try XCTUnwrap(switchWorkspaceProject(target.id, on: mainMonitor))
        _ = TestWindow.new(id: 704, parent: visible.rootTilingContainer)
        _ = visible.focusWorkspace()
        let viewportId = MonitorViewportId(mainMonitor)

        XCTAssertTrue(moveWorkspaceToProject(workspaceName: hidden.name, projectId: target.id))

        XCTAssertFalse(hidden.isVisible)
        XCTAssertTrue(mainMonitor.activeWorkspace === visible)
        XCTAssertTrue(focus.workspace === visible)
        XCTAssertEqual(winMuxWorkspaceState.monitorViewportsById[viewportId]?.lastActiveWorkspaceByProject[target.id], visible.id)
        XCTAssertNil(winMuxWorkspaceState.monitorViewportsById[viewportId]?.lastActiveWorkspaceByProject[sourceProject])
        XCTAssertEqual(switchWorkspaceProject(sourceProject, on: mainMonitor)?.projectId, sourceProject)
    }

    func testMoveOnAnotherMonitorKeepsBothVisibleWorkspacesAndCurrentFocus() {
        let main = TestMonitor(monitorAppKitNsScreenScreensId: 1, name: "Main",
            rect: Rect(topLeftX: 0, topLeftY: 0, width: 1600, height: 1000),
            visibleRect: Rect(topLeftX: 0, topLeftY: 0, width: 1600, height: 1000), isMain: true)
        let other = TestMonitor(monitorAppKitNsScreenScreensId: 2, name: "Other",
            rect: Rect(topLeftX: 1600, topLeftY: 0, width: 1600, height: 1000),
            visibleRect: Rect(topLeftX: 1600, topLeftY: 0, width: 1600, height: 1000), isMain: false)
        setMonitorsForTests([main, other])
        defer { setMonitorsForTests(nil) }
        let focused = focus.workspace
        _ = TestWindow.new(id: 705, parent: focused.rootTilingContainer)
        XCTAssertTrue(main.setActiveWorkspace(focused))
        let moved = Workspace.get(byName: "other-display")
        _ = TestWindow.new(id: 706, parent: moved.rootTilingContainer)
        XCTAssertTrue(other.setActiveWorkspace(moved))
        let target = createWorkspaceProject()

        XCTAssertTrue(moveWorkspaceToProject(workspaceName: moved.name, projectId: target.id))
        Workspace.reconcileWorkspaceState()

        XCTAssertTrue(main.activeWorkspace === focused)
        XCTAssertTrue(other.activeWorkspace === moved)
        XCTAssertTrue(focus.workspace === focused)
        XCTAssertEqual(activeWorkspaceProjectId(for: other), target.id)
        XCTAssertEqual(activeWorkspaceProjectId(for: main), workspaceProjectDefaultId)
    }

    func testSameProjectAndStaleDropsAreNoOps() {
        let workspace = focus.workspace
        let order = winMuxWorkspaceState.projectsById[workspace.projectId]?.workspaceOrder
        XCTAssertFalse(moveWorkspaceToProject(workspaceName: workspace.name, projectId: workspace.projectId))
        XCTAssertFalse(moveWorkspaceToProject(workspaceName: workspace.name, projectId: "deleted-project"))
        XCTAssertFalse(moveWorkspaceToProject(workspaceName: "missing-workspace", projectId: workspace.projectId))
        XCTAssertNil(winMuxWorkspaceState.projectsById["deleted-project"])
        XCTAssertEqual(winMuxWorkspaceState.projectsById[workspace.projectId]?.workspaceOrder, order)
        let target = createWorkspaceProject()
        workspace.lifecycle = .archived
        XCTAssertFalse(moveWorkspaceToProject(workspaceName: workspace.name, projectId: target.id))
        workspace.lifecycle = .durable
    }

    func testMovedHiddenBlankSurvivesUntilVisitedThenResumesNormalEmptyCleanup() throws {
        let occupied = focus.workspace
        _ = TestWindow.new(id: 707, parent: occupied.rootTilingContainer)
        let source = createWorkspaceProject()
        let blank = try XCTUnwrap(projectWorkspaces(projectId: source.id).first)
        try renameWorkspaceForSidebar(workspaceName: blank.name, displayName: "Next task")

        XCTAssertTrue(moveWorkspaceToProject(workspaceName: blank.name, projectId: occupied.projectId))
        for _ in 0..<2 { Workspace.reconcileWorkspaceState() }

        XCTAssertTrue(Workspace.existing(byName: blank.name) === blank)
        XCTAssertTrue(isUserFacingWorkspace(blank))
        XCTAssertTrue(focus.workspace === occupied)
        XCTAssertEqual(config.workspaceSidebar.workspaceLabels[blank.name], "Next task")
        XCTAssertEqual(projectWorkspaces(projectId: source.id).count, 1)
        _ = blank.focusWorkspace()
        Workspace.reconcileWorkspaceState()
        XCTAssertFalse(blank.retainsEmptyAfterProjectMove)
        _ = occupied.focusWorkspace()
        Workspace.reconcileWorkspaceState()
        XCTAssertNil(Workspace.existing(byName: blank.name))
    }

    func testWorkspaceProviderRoundTripAndWindowPayloadIsolation() async {
        let payload = WorkspaceSidebarWorkspaceDragPayload(workspaceName: "research: 中文 / 2")
        let provider = payload.itemProvider
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(workspaceSidebarWorkspaceDragType))
        XCTAssertFalse(provider.hasItemConformingToTypeIdentifier(workspaceSidebarDragPayloadType.identifier))
        XCTAssertFalse(WorkspaceSidebarDragPayload.window(701).itemProvider
            .hasItemConformingToTypeIdentifier(workspaceSidebarWorkspaceDragType))
        let loaded = expectation(description: "Workspace provider loads on the main actor")
        WorkspaceSidebarWorkspaceDragPayload.load(from: provider) { decoded in
            XCTAssertEqual(decoded, payload)
            loaded.fulfill()
        }
        await fulfillment(of: [loaded], timeout: 3)
    }

    func testProjectDropRevealsDestinationAndRoutesWholeWorkspaceMove() async {
        var collapsed: Set<WorkspaceProjectId> = ["research"]
        let routed = expectation(description: "Drop reveals destination before moving workspace")
        let delegate = WorkspaceSidebarProjectDropDelegate(projectId: "research", actions: .init(send: { action in
            XCTAssertFalse(collapsed.contains("research"))
            XCTAssertEqual(action, .moveWorkspace("workspace: 中文", toProject: "research"))
            routed.fulfill()
        }), isTargeted: .constant(false), onWorkspaceDrop: { collapsed.remove("research") })
        XCTAssertFalse(delegate.performDrop(provider: WorkspaceSidebarDragPayload.window(701).itemProvider))
        XCTAssertTrue(delegate.performDrop(provider:
            WorkspaceSidebarWorkspaceDragPayload(workspaceName: "workspace: 中文").itemProvider))
        await fulfillment(of: [routed], timeout: 3)
    }

    func testAdapterPublishesMovedWorkspaceAndNewActiveProject() async throws {
        let model = TrayMenuModel.shared
        let wasEnabled = model.isEnabled
        let sidebarWasEnabled = config.workspaceSidebar.enabled
        let previousApp = appForTests
        model.isEnabled = true
        config.workspaceSidebar.enabled = true
        appForTests = TestApp.shared
        setScheduledRefreshOverrideForTests { _, _, _ in }
        defer {
            model.isEnabled = wasEnabled
            config.workspaceSidebar.enabled = sidebarWasEnabled
            appForTests = previousApp
            setScheduledRefreshOverrideForTests(nil)
        }
        let workspace = focus.workspace
        let window = TestWindow.new(id: 708, parent: workspace.rootTilingContainer)
        _ = window.focusWindow()
        window.nativeFocus()
        let target = createWorkspaceProject()
        await updateWorkspaceSidebarModel()
        let published = expectation(description: "Sidebar snapshot reflects the move")
        let subscription = model.$workspaceSidebarWorkspaces.first { workspaces in
            workspaces.contains { $0.name == workspace.name && $0.projectId == target.id }
        }.sink { _ in published.fulfill() }
        defer { subscription.cancel() }

        handleWorkspaceSidebarAction(.moveWorkspace(workspace.name, toProject: target.id))
        await fulfillment(of: [published], timeout: 3)

        XCTAssertEqual(model.workspaceSidebarActiveProjectId, target.id)
        XCTAssertEqual(workspace.projectId, target.id)
    }

    func testNativeDragSourcePreservesClicksAndReleasesExpansionLockAfterCancellation() throws {
        let source = WorkspaceSidebarWorkspaceDragSourceView(frame: CGRect(x: 0, y: 0, width: 180, height: 28))
        var activations = 0
        source.onActivate = { activations += 1 }
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 10, y: 10),
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: CGPoint(x: 10, y: 10),
            modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        source.mouseDown(with: down)
        source.mouseUp(with: up)
        XCTAssertEqual(activations, 1)
        source.mouseDown(with: down)
        source.beginDrag()
        source.beginDrag()
        XCTAssertTrue(isWorkspaceSidebarDragInProgress())
        resetWorkspaceSidebarItemDrag()
        XCTAssertTrue(isWorkspaceSidebarDragInProgress(), "Window mouse-up cleanup cannot release the native drag lock")
        XCTAssertTrue(WorkspaceSidebarPanel.shared.shouldLockExpansionForSidebarDrag())
        XCTAssertFalse(source.accessibilityPerformPress())
        source.finishDrag()
        source.finishDrag()
        source.mouseUp(with: up)
        XCTAssertFalse(isWorkspaceSidebarDragInProgress())
        XCTAssertEqual(activations, 1, "Dropping or cancelling a drag must not also activate the workspace")
        XCTAssertTrue(source.accessibilityPerformPress())
        XCTAssertEqual(activations, 2)
    }

    func testWorkspaceDragTypeIsDeclaredInAppBundle() throws {
        let data = try Data(contentsOf: projectRoot.appendingPathComponent("resources/WinMux-Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let declarations = try XCTUnwrap(plist["UTExportedTypeDeclarations"] as? [[String: Any]])
        let workspaceType = try XCTUnwrap(declarations.first {
            $0["UTTypeIdentifier"] as? String == workspaceSidebarWorkspaceDragType
        })
        XCTAssertEqual(workspaceType["UTTypeConformsTo"] as? [String], ["public.data"])
    }

    func testNativeDragSourceTeardownReleasesOnlyItsOwnExpansionLock() {
        var source: WorkspaceSidebarWorkspaceDragSourceView? = WorkspaceSidebarWorkspaceDragSourceView()
        source?.beginDrag()
        beginWorkspaceSidebarItemDrag()
        source = nil
        XCTAssertTrue(isWorkspaceSidebarDragInProgress(), "Teardown must preserve another drag's claim")
        endWorkspaceSidebarItemDrag()
        XCTAssertFalse(isWorkspaceSidebarDragInProgress())
    }

    func testNativeDragKeepsExpansionLockWhenSwiftUIRemovesItsSource() {
        let source = WorkspaceSidebarWorkspaceDragSourceView()
        source.beginDrag()
        WorkspaceSidebarWorkspaceDragSource.dismantleNSView(source, coordinator: ())
        XCTAssertTrue(isWorkspaceSidebarNativeWorkspaceDragActive())
        XCTAssertTrue(source.isDraggingWorkspace)
        source.finishDrag()
        XCTAssertFalse(isWorkspaceSidebarNativeWorkspaceDragActive())
    }

    func testGenericDataFallbackRequiresNativeDragAndWorkspaceTag() async throws {
        let payload = WorkspaceSidebarWorkspaceDragPayload(workspaceName: "workspace: 中文")
        let data = try XCTUnwrap(payload.pasteboardItem?.data(forType: .init("public.data")))
        let provider = NSItemProvider(item: data as NSData, typeIdentifier: "public.data")
        let moved = expectation(description: "SwiftUI data fallback routes the workspace")
        let delegate = WorkspaceSidebarProjectDropDelegate(projectId: "research", actions: .init(send: { action in
            XCTAssertEqual(action, .moveWorkspace("workspace: 中文", toProject: "research"))
            moved.fulfill()
        }), isTargeted: .constant(false))
        XCTAssertFalse(delegate.performDrop(provider: provider), "Ordinary data drags must not move workspaces")
        let source = WorkspaceSidebarWorkspaceDragSourceView()
        source.beginDrag()
        defer { source.finishDrag() }
        XCTAssertTrue(delegate.performDrop(provider: provider))
        await fulfillment(of: [moved], timeout: 3)

        let unrelatedData = NSItemProvider(item: Data(#"{"kind":"another-app","workspaceName":"1"}"#.utf8) as NSData,
            typeIdentifier: "public.data")
        let rejected = expectation(description: "Unrelated data never moves a workspace")
        rejected.isInverted = true
        let rejectingDelegate = WorkspaceSidebarProjectDropDelegate(projectId: "research",
            actions: .init(send: { _ in rejected.fulfill() }), isTargeted: .constant(false))
        XCTAssertTrue(rejectingDelegate.performDrop(provider: unrelatedData))
        await fulfillment(of: [rejected], timeout: 0.1)
    }
}
