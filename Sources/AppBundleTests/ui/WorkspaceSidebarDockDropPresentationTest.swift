import AppKit
@testable import AppBundle
import SwiftUI
import XCTest

@MainActor
final class WorkspaceSidebarDockDropPresentationTest: XCTestCase {
    private let app = WorkspaceSidebarAppViewModel(name: "Editor", bundleId: "test.editor", bundlePath: nil)

    func testPlaceholderSurvivesMouseUpUntilDestinationModelArrives() {
        let model = TrayMenuModel()
        model.workspaceSidebarAppearance.showAppIcons = true
        model.workspaceSidebarWorkspaces = [workspace("1", windowIds: [42]), workspace("2", windowIds: [])]
        var drag = presentation()
        drag.destination = preview()
        model.workspaceSidebarDockDrag = drag
        model.workspaceSidebarDropPreview = nil // Mouse-up clears driver intent immediately.
        var snapshot = workspaceSidebarSnapshot(from: model)
        XCTAssertEqual(snapshot.dropPreview, drag.destination)
        XCTAssertTrue(snapshot.dockDrag?.hidesIcon(workspaceName: "1", appId: app.id) == true)

        // Another window from the same app must not finish the handoff early.
        model.workspaceSidebarWorkspaces = [workspace("1", windowIds: [42]), workspace("2", windowIds: [99])]
        XCTAssertNotNil(workspaceSidebarSnapshot(from: model).dropPreview)

        // The app can remain in the source workspace when it has other windows there.
        model.workspaceSidebarWorkspaces = [workspace("1", windowIds: [43]), workspace("2", windowIds: [42, 99])]
        snapshot = workspaceSidebarSnapshot(from: model)
        XCTAssertNil(snapshot.dropPreview)
        XCTAssertNil(snapshot.dockDrag)
        XCTAssertEqual(snapshot.workspaces[0].apps, [app])
    }

    func testNewWorkspaceHandoffRequiresMovedWindowOutsideSource() {
        var drag = presentation()
        drag.destination = preview(newWorkspace: true)
        XCTAssertFalse(drag.hasArrived(in: [workspace("1", windowIds: [42])]))
        XCTAssertFalse(drag.hasArrived(in: [workspace("new", windowIds: [99])]))
        XCTAssertTrue(drag.hasArrived(in: [workspace("new", windowIds: [42])]))
        XCTAssertFalse(drag.hidesIcon(workspaceName: "2", appId: app.id))
    }

    func testCancellationRestoresSourceAndStaleCompletionCannotClearNewDrag() {
        let previous = TrayMenuModel.shared.workspaceSidebarDockDrag
        defer { TrayMenuModel.shared.workspaceSidebarDockDrag = previous }
        let first = presentation()
        let second = presentation()
        TrayMenuModel.shared.workspaceSidebarDockDrag = second
        finishWorkspaceSidebarDockLift(id: first.id)
        XCTAssertEqual(TrayMenuModel.shared.workspaceSidebarDockDrag, second)
        finishWorkspaceSidebarDockLift(id: second.id)
        XCTAssertNil(TrayMenuModel.shared.workspaceSidebarDockDrag)
    }

    func testSidebarModeNeverUsesDockLiftOrSettlementPlaceholder() {
        let model = TrayMenuModel()
        model.workspaceSidebarAppearance.showAppIcons = false
        var drag = presentation()
        drag.destination = preview()
        model.workspaceSidebarDockDrag = drag
        let snapshot = workspaceSidebarSnapshot(from: model)
        XCTAssertNil(snapshot.dockDrag)
        XCTAssertNil(snapshot.dropPreview)
    }

    func testGestureCleanupPreservesOnlyCommittedHandoffAndNextDragCancelsIt() {
        clearActiveWorkspaceSidebarDrag()
        defer {
            clearActiveWorkspaceSidebarDrag()
            TrayMenuModel.shared.workspaceSidebarDockDrag = nil
        }
        beginActiveWorkspaceSidebarDrag(windowId: 42, subject: .window, previewStyle: .appIcon(size: 40))
        TrayMenuModel.shared.workspaceSidebarDockDrag = presentation()
        clearActiveWorkspaceSidebarDrag()
        XCTAssertNil(TrayMenuModel.shared.workspaceSidebarDockDrag, "Cancellation restores the source")

        beginActiveWorkspaceSidebarDrag(windowId: 42, subject: .window, previewStyle: .appIcon(size: 40))
        var committed = presentation()
        committed.destination = preview()
        TrayMenuModel.shared.workspaceSidebarDockDrag = committed
        clearActiveWorkspaceSidebarDrag()
        XCTAssertEqual(TrayMenuModel.shared.workspaceSidebarDockDrag, committed)
        beginActiveWorkspaceSidebarDrag(windowId: 43, subject: .window, previewStyle: .appIcon(size: 40))
        XCTAssertNil(TrayMenuModel.shared.workspaceSidebarDockDrag, "A new gesture supersedes the old handoff")
    }

    func testLiftHidesOnlySourceIconWithoutChangingLayout() throws {
        let workspace = workspace("1", windowIds: [42])
        let layout = WorkspaceSidebarAppIconLayout(appCount: 1, availableWidth: 50)
        func render(lift: WorkspaceSidebarDockDragPresentation?) throws -> NSBitmapImageRep {
            let view = WorkspaceSidebarAppIconHeader(workspace: workspace, availableWidth: 50, isActive: true)
                .environment(\.workspaceSidebarDockDrag, lift)
            let host = NSHostingView(rootView: view)
            host.frame = CGRect(x: 0, y: 0, width: 50, height: layout.height)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.fittingSize.height, layout.height, accuracy: 1)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return bitmap
        }
        let normal = try render(lift: nil)
        let lifted = try render(lift: presentation())
        let scale = CGFloat(normal.pixelsWide) / 50
        let iconCenter = CGPoint(x: 25, y: 40 + 6 + 20)
        func alpha(_ image: NSBitmapImageRep, _ point: CGPoint) throws -> CGFloat {
            try XCTUnwrap(image.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))).alphaComponent
        }
        XCTAssertGreaterThan(try alpha(normal, iconCenter), 0.1)
        XCTAssertLessThan(try alpha(lifted, iconCenter), 0.01)
        XCTAssertEqual(try alpha(normal, CGPoint(x: 25, y: 20)), try alpha(lifted, CGPoint(x: 25, y: 20)), accuracy: 0.01)
    }

    private func presentation() -> WorkspaceSidebarDockDragPresentation {
        .init(id: UUID(), windowId: 42, sourceWorkspaceName: "1", appId: app.id)
    }

    private func preview(newWorkspace: Bool = false) -> WorkspaceSidebarDropPreviewViewModel {
        .init(sourceWindowId: 42, label: "Document", appName: app.name,
              targetWorkspaceName: newWorkspace ? nil : "2", targetsNewWorkspace: newWorkspace,
              targetProjectId: newWorkspace ? workspaceProjectDefaultId : nil, isTabGroup: false, windowCount: 1)
    }

    private func workspace(_ name: String, windowIds: [UInt32]) -> WorkspaceSidebarWorkspaceViewModel {
        .init(name: name, projectId: workspaceProjectDefaultId, displayName: name, sidebarLabel: name,
              isGeneratedName: false, monitorScopeId: workspaceSidebarDefaultScopeId, monitorName: nil,
              isFocused: name == "1", isVisible: name == "1",
              items: windowIds.map { id in .init(kind: .window(.init(windowId: id, workspaceName: name,
                  appName: app.name, appBundleId: app.bundleId, appBundlePath: nil, title: "Document", isFocused: false))) },
              apps: windowIds.isEmpty ? [] : [app])
    }
}
