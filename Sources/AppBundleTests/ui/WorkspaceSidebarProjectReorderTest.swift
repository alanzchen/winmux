import AppKit
@testable import AppBundle
import XCTest

@MainActor
final class WorkspaceSidebarProjectReorderTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testConfiguredOrderPlacesProjectsAndUnlistedOnesFollowInCreationOrder() {
        let projects = [
            WorkspaceProject(id: "late", name: "Late", order: 5),
            WorkspaceProject(id: workspaceProjectDefaultId, name: "Default", order: 0),
            WorkspaceProject(id: "alpha", name: "Alpha", order: 1),
            WorkspaceProject(id: "beta", name: "Beta", order: 2),
        ]
        XCTAssertEqual(workspaceProjectsInDisplayOrder(projects, configuredOrder: []).map(\.id.rawValue),
            ["default", "alpha", "beta", "late"])
        XCTAssertEqual(workspaceProjectsInDisplayOrder(projects, configuredOrder: ["beta", "default", "missing", "beta"])
            .map(\.id.rawValue), ["beta", "default", "alpha", "late"])
    }

    func testMovingAProjectReordersProjectsAndIndexesAndSavesTheOrder() throws {
        let first = createWorkspaceProject()
        let second = createWorkspaceProject()
        XCTAssertEqual(workspaceProjects().map(\.id), [workspaceProjectDefaultId, first.id, second.id])

        XCTAssertTrue(try moveWorkspaceProject(second.id, relativeTo: workspaceProjectDefaultId, after: false))
        XCTAssertEqual(workspaceProjects().map(\.id), [second.id, workspaceProjectDefaultId, first.id])
        XCTAssertEqual(config.workspaceSidebar.projectOrder, [second.id, workspaceProjectDefaultId, first.id].map(\.rawValue))
        XCTAssertEqual(workspaceProjects().map(\.name), ["Project 2", "Default", "Project 1"],
            "Reordering never renames an unnamed project")

        XCTAssertTrue(try moveWorkspaceProject(second.id, relativeTo: first.id, after: true))
        XCTAssertEqual(workspaceProjects().map(\.id), [workspaceProjectDefaultId, first.id, second.id])
        XCTAssertFalse(try moveWorkspaceProject(second.id, relativeTo: first.id, after: true), "Dropping in place changes nothing")
        XCTAssertFalse(try moveWorkspaceProject(first.id, relativeTo: first.id, after: false))
        XCTAssertFalse(try moveWorkspaceProject("missing", relativeTo: first.id, after: false))

        XCTAssertTrue(try moveWorkspaceProject(second.id, relativeTo: workspaceProjectDefaultId, after: false))
        try deleteWorkspaceProject(second.id)
        XCTAssertEqual(config.workspaceSidebar.projectOrder, [workspaceProjectDefaultId, first.id].map(\.rawValue),
            "A deleted project leaves the saved order")
        XCTAssertEqual(workspaceProjects().map(\.id), [workspaceProjectDefaultId, first.id])
    }

    func testDeletingAProjectFallsBackToTheNextOneInTheSavedOrder() throws {
        let first = createWorkspaceProject()
        let second = createWorkspaceProject()
        XCTAssertTrue(try moveWorkspaceProject(first.id, relativeTo: workspaceProjectDefaultId, after: false))
        XCTAssertTrue(try moveWorkspaceProject(second.id, relativeTo: first.id, after: true))
        XCTAssertEqual(workspaceProjects().map(\.id), [first.id, second.id, workspaceProjectDefaultId])
        let workspace = try XCTUnwrap(projectWorkspaces(projectId: first.id).first)
        let window = TestWindow.new(id: 951, parent: workspace.rootTilingContainer)

        try deleteWorkspaceProject(first.id)
        XCTAssertEqual(window.nodeWorkspace?.projectId, second.id,
            "The deleted project's windows move to the next project in the saved order")
        XCTAssertEqual(config.workspaceSidebar.projectOrder, [second.id, workspaceProjectDefaultId].map(\.rawValue))
    }

    func testClosingAProjectsWindowsAlsoRemovesItFromTheSavedOrder() async throws {
        let first = createWorkspaceProject()
        let second = createWorkspaceProject()
        XCTAssertTrue(try moveWorkspaceProject(second.id, relativeTo: workspaceProjectDefaultId, after: false))
        try await deleteWorkspaceProject(second.id, action: .closeWindows)
        XCTAssertEqual(config.workspaceSidebar.projectOrder, [workspaceProjectDefaultId, first.id].map(\.rawValue))
    }

    func testRestoredProjectsFollowTheSavedOrderThenTheirIds() {
        config.workspaceSidebar.projectLabels = ["project-b": "B", "project-c": "C", "project-a": "A"]
        config.workspaceSidebar.projectOrder = ["project-c", "project-a"]
        winMuxWorkspaceState.resetProjects(defaultProjectName: "Default")
        XCTAssertEqual(workspaceProjects().map(\.id.rawValue), ["project-c", "project-a", "default", "project-b"])
        let restoredOrder = winMuxWorkspaceState.projectsById.values.sorted(by: workspaceProjectOrderPrecedes).map(\.id.rawValue)
        XCTAssertEqual(restoredOrder, ["default", "project-c", "project-a", "project-b"],
            "Launch order must not depend on dictionary iteration")
    }

    func testProjectOrderConfigIsInsertedReplacedAndFolded() throws {
        let inserted = try XCTUnwrap(updateWorkspaceSidebarProjectOrderConfig(in: "[workspace-sidebar]\n    enabled = true\n",
            order: ["default", "project-1"]))
        XCTAssertEqual(inserted, "[workspace-sidebar]\n    project-order = [\"default\", \"project-1\"]\n    enabled = true\n")
        XCTAssertEqual(updateWorkspaceSidebarProjectOrderConfig(in: inserted, order: ["project-1", "default"]),
            "[workspace-sidebar]\n    project-order = [\"project-1\", \"default\"]\n    enabled = true\n")

        let multiLine = """
            [workspace-sidebar]
                project-order = [ # hand-sorted [by me]
                    'default', # see [notes]
                    'project-1',
                ]
                enabled = true

            [workspace-sidebar.project-labels]
                "project-1" = "Research"
            """
        let folded = try XCTUnwrap(updateWorkspaceSidebarProjectOrderConfig(in: multiLine, order: ["project-1", "default"]))
        XCTAssertEqual(folded, """
            [workspace-sidebar]
                project-order = ["project-1", "default"] # hand-sorted [by me]
                enabled = true

            [workspace-sidebar.project-labels]
                "project-1" = "Research"
            """)
        let (parsed, errors) = parseConfig(folded)
        XCTAssertTrue(errors.isEmpty, "\(errors)")
        XCTAssertEqual(parsed.workspaceSidebar.projectOrder, ["project-1", "default"])
        XCTAssertEqual(updateWorkspaceSidebarProjectOrderConfig(in: "", order: ["default"]),
            "[workspace-sidebar]\n    project-order = [\"default\"]")

        let quotedHash = "[workspace-sidebar]\n    project-order = [\"c#1\", \"default\"] # mine\n    enabled = true\n"
        XCTAssertEqual(updateWorkspaceSidebarProjectOrderConfig(in: quotedHash, order: ["default", "c#1"]),
            "[workspace-sidebar]\n    project-order = [\"default\", \"c#1\"] # mine\n    enabled = true\n",
            "A # inside a quoted id is not a comment")

        let bracketedIds = "[workspace-sidebar]\n    project-order = [\"a]b\",\n        \"c[d\",\n    ]\n    enabled = true\n"
        let rewritten = try XCTUnwrap(updateWorkspaceSidebarProjectOrderConfig(in: bracketedIds, order: ["c[d", "a]b"]))
        XCTAssertEqual(rewritten, "[workspace-sidebar]\n    project-order = [\"c[d\", \"a]b\"]\n    enabled = true\n",
            "Brackets inside quoted ids neither close nor open the list")
        XCTAssertEqual(parseConfig(rewritten).0.workspaceSidebar.projectOrder, ["c[d", "a]b"])

        // A line whose quote never closes is invalid TOML; its first # still counts as the comment.
        XCTAssertEqual(updateWorkspaceSidebarProjectDeletionActionConfig(
            in: "[workspace-sidebar]\n    project-deletion-action = 'close # keep\n", action: .moveWindowsToFallback),
            "[workspace-sidebar]\n    project-deletion-action = 'move-windows-to-fallback' # keep\n")

        let unclosed = "[workspace-sidebar]\n    project-order = [\n        'default',\n\n[workspace-sidebar.project-labels]\n    \"project-1\" = \"Research\"\n"
        XCTAssertNil(updateWorkspaceSidebarProjectOrderConfig(in: unclosed, order: ["default"]),
            "An unclosed list is left alone instead of deleting the next table")
        XCTAssertNil(updateWorkspaceSidebarProjectOrderConfig(
            in: unclosed.replacingOccurrences(of: "project-labels]", with: "project-labels] # labels"), order: ["default"]),
            "A commented table header also ends the search for the closing bracket")
    }

    func testProjectHeaderDropReordersOnlySideBySideColumns() async throws {
        let data = try XCTUnwrap(WorkspaceSidebarProjectDragPayload(projectId: "research").pasteboardItem?
            .data(forType: .init("public.data")))
        XCTAssertEqual(WorkspaceSidebarNativeDragItem.decode(data), .project("research"))
        let provider = NSItemProvider(item: data as NSData, typeIdentifier: "public.data")
        let moved = expectation(description: "A project header dropped on a column reorders projects")
        let column = WorkspaceSidebarProjectDropDelegate(projectId: workspaceProjectDefaultId, actions: .init(send: { action in
            XCTAssertEqual(action, .moveProject("research", relativeTo: workspaceProjectDefaultId, after: true))
            moved.fulfill()
        }), isTargeted: .constant(false), reorderWidth: 256)
        XCTAssertFalse(column.performDrop(provider: provider, insertsProjectAfter: true),
            "Ordinary data drags never reorder projects")

        let source = WorkspaceSidebarWorkspaceDragSourceView()
        source.projectId = "research"
        source.beginDrag()
        addTeardownBlock { @MainActor in source.finishDrag() }
        XCTAssertEqual(workspaceSidebarDraggedProjectId(), "research")
        XCTAssertTrue(isWorkspaceSidebarDragInProgress(), "A project drag keeps the floating view open")
        XCTAssertTrue(WorkspaceSidebarNativeDragState.shared.isActive, "Project columns cover their workspace rows")
        XCTAssertTrue(column.performDrop(provider: provider, insertsProjectAfter: true))
        await fulfillment(of: [moved], timeout: 3)

        let ignored = expectation(description: "The stacked project list does not reorder projects")
        ignored.isInverted = true
        let stacked = WorkspaceSidebarProjectDropDelegate(projectId: workspaceProjectDefaultId,
            actions: .init(send: { _ in ignored.fulfill() }), isTargeted: .constant(false))
        XCTAssertTrue(stacked.performDrop(provider: provider))
        await fulfillment(of: [ignored], timeout: 0.1)

        source.finishDrag()
        XCTAssertNil(workspaceSidebarDraggedProjectId())
        XCTAssertFalse(isWorkspaceSidebarDragInProgress())
        XCTAssertFalse(WorkspaceSidebarNativeDragState.shared.isActive)
    }

    func testOverlayClickRecoversADragThatOutlivedItsSession() {
        let source = WorkspaceSidebarWorkspaceDragSourceView()
        source.projectId = "research"
        source.beginDrag()
        XCTAssertTrue(WorkspaceSidebarNativeDragState.shared.isActive)
        recoverStaleWorkspaceSidebarNativeWorkspaceDrag()
        XCTAssertFalse(WorkspaceSidebarNativeDragState.shared.isActive, "Rows are clickable again")
        XCTAssertNil(workspaceSidebarDraggedProjectId())
        XCTAssertFalse(isWorkspaceSidebarDragInProgress())
        source.finishDrag()
        XCTAssertFalse(isWorkspaceSidebarNativeWorkspaceDragActive(), "The late release cannot underflow the count")
    }

    func testOnlyActivationsLongAfterEditingStartsCancelIt() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        XCTAssertFalse(workspaceSidebarInlineTextEditingCancelsForActivation(startedAt: start, now: start.addingTimeInterval(0.2)),
            "The first click of a double-click activating another app keeps the rename")
        XCTAssertTrue(workspaceSidebarInlineTextEditingCancelsForActivation(startedAt: start,
            now: start.addingTimeInterval(workspaceSidebarInlineTextActivationGrace)))
    }

    func testDoubleClickRenamesInsteadOfActivatingAgain() throws {
        let source = WorkspaceSidebarWorkspaceDragSourceView(frame: CGRect(x: 0, y: 0, width: 180, height: 28))
        var activations = 0
        var renames = 0
        source.onActivate = { activations += 1 }
        source.onDoubleClick = { renames += 1 }
        func click(_ count: Int) throws {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: 10, y: 10),
                    modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1,
                    clickCount: count, pressure: type == .leftMouseDown ? 1 : 0))
                type == .leftMouseDown ? source.mouseDown(with: event) : source.mouseUp(with: event)
            }
        }
        try click(1)
        try click(2)
        XCTAssertEqual(activations, 1)
        XCTAssertEqual(renames, 1)
        source.onDoubleClick = nil
        try click(2)
        XCTAssertEqual(activations, 2, "Without a rename action a second click still activates")
    }
}
