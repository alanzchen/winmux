import AppKit
@testable import AppBundle
import SwiftUI
import XCTest

@MainActor
final class WorkspaceSidebarDockDropPresentationTest: XCTestCase {
    private let app = WorkspaceSidebarAppViewModel(name: "Editor", bundleId: "test.editor", bundlePath: nil)

    func testEndingGestureClearsLivePreviewButPreservesCommittedHandoff() {
        clearActiveWorkspaceSidebarDrag()
        defer {
            clearActiveWorkspaceSidebarDrag()
            TrayMenuModel.shared.workspaceSidebarDockDrag = nil
        }
        beginActiveWorkspaceSidebarDrag(windowId: 42, subject: .window, previewStyle: .appIcon(size: 40))
        var committed = presentation()
        committed.destination = preview(newWorkspace: true)
        TrayMenuModel.shared.workspaceSidebarDockDrag = committed
        TrayMenuModel.shared.workspaceSidebarDropPreview = committed.destination
        clearActiveWorkspaceSidebarDrag()
        XCTAssertNil(TrayMenuModel.shared.workspaceSidebarDropPreview, "The faded create-workspace preview must not survive mouse-up")
        XCTAssertEqual(TrayMenuModel.shared.workspaceSidebarDockDrag, committed, "The destination may still be waiting for its model update")
    }

    func testMissedMouseUpCleansDockSessionAfterSourceViewDisappears() async {
        let driver = WindowMouseInteractionDriver.shared
        clearActiveWorkspaceSidebarDrag()
        resetWorkspaceSidebarItemDrag()
        driver.stop()
        defer {
            clearActiveWorkspaceSidebarDrag()
            resetWorkspaceSidebarItemDrag()
            driver.stop()
        }
        // Simulate an icon removed by the lift projection: its SwiftUI onEnded
        // never fires, leaving only the native display-loop mouse-up fallback.
        beginActiveWorkspaceSidebarDrag(windowId: 42, subject: .window, previewStyle: .appIcon(size: 40))
        beginWorkspaceSidebarItemDrag()
        TrayMenuModel.shared.workspaceSidebarDockDrag = presentation()
        TrayMenuModel.shared.workspaceSidebarDropPreview = preview(newWorkspace: true)
        driver.moveSession = .init(windowId: 42, subject: .window, detachOrigin: .window, startedInSidebar: true)
        driver.finishAfterMissedMouseUpIfNeeded()
        for _ in 0..<100 where driver.isMouseUpResetScheduled { await Task.yield() }
        XCTAssertFalse(driver.isMouseUpResetScheduled)
        XCTAssertNil(currentActiveWorkspaceSidebarDrag())
        XCTAssertFalse(isWorkspaceSidebarItemDragActive())
        XCTAssertNil(TrayMenuModel.shared.workspaceSidebarDockDrag)
        XCTAssertNil(TrayMenuModel.shared.workspaceSidebarDropPreview)
        XCTAssertNil(WindowDragCursorProxyPanel.shared.currentContent)
        // A duplicate SwiftUI/global mouse-up must remain harmless.
        finishWorkspaceSidebarDragAfterMouseUp()
        XCTAssertNil(TrayMenuModel.shared.workspaceSidebarDropPreview)
    }

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
        XCTAssertTrue(snapshot.workspaces[0].apps.isEmpty)
        XCTAssertEqual(snapshot.workspaces[1].apps, [app])

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

    func testMissedMouseUpStillCleansLiftAfterGenericDriverWasReset() async throws {
        let driver = WindowMouseInteractionDriver.shared
        clearActiveWorkspaceSidebarDrag()
        resetWorkspaceSidebarItemDrag()
        driver.stop()
        defer {
            clearActiveWorkspaceSidebarDrag()
            resetWorkspaceSidebarItemDrag()
            driver.stop()
        }
        beginActiveWorkspaceSidebarDrag(windowId: 42, subject: .window, previewStyle: .appIcon(size: 40))
        beginWorkspaceSidebarItemDrag()
        TrayMenuModel.shared.workspaceSidebarDockDrag = presentation()
        TrayMenuModel.shared.workspaceSidebarDropPreview = preview(newWorkspace: true)
        driver.moveSession = .init(windowId: 42, subject: .window, detachOrigin: .window, startedInSidebar: true)
        // Provider completion can reset the native move before the final display callback.
        try await resetManipulatedWithMouseIfPossible()
        XCTAssertNil(driver.moveSession)
        driver.finishAfterMissedMouseUpIfNeeded()
        XCTAssertNil(currentActiveWorkspaceSidebarDrag())
        XCTAssertFalse(isWorkspaceSidebarItemDragActive())
        XCTAssertNil(TrayMenuModel.shared.workspaceSidebarDockDrag)
        XCTAssertNil(TrayMenuModel.shared.workspaceSidebarDropPreview)
    }

    func testNewWorkspaceHandoffRequiresMovedWindowOutsideSource() {
        var drag = presentation()
        drag.destination = preview(newWorkspace: true)
        XCTAssertFalse(drag.hasArrived(in: [workspace("1", windowIds: [42])]))
        XCTAssertFalse(drag.hasArrived(in: [workspace("new", windowIds: [99])]))
        XCTAssertTrue(drag.hasArrived(in: [workspace("new", windowIds: [42])]))
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

    func testLiftClosesSourceSlotAndCancellationRestoresIt() {
        let source = workspace("1", windowIds: [42])
        let lifted = workspaceSidebarDockDragWorkspaces([source], drag: presentation(), preview: nil)
        XCTAssertTrue(lifted[0].apps.isEmpty)
        let before = WorkspaceSidebarAppIconLayout(appCount: source.apps.count, availableWidth: 50)
        let after = WorkspaceSidebarAppIconLayout(appCount: lifted[0].apps.count, availableWidth: 50)
        XCTAssertEqual(before.height - after.height, 46)
        XCTAssertEqual(workspaceSidebarDockDragWorkspaces([source], drag: nil, preview: nil), [source])
    }

    func testOtherWindowsKeepTheirAppIconAndDestinationUsesOneNormalSlot() {
        let source = workspace("1", windowIds: [42, 43])
        let destination = workspace("2", windowIds: [99])
        let projected = workspaceSidebarDockDragWorkspaces([source, destination], drag: presentation(), preview: preview())
        XCTAssertEqual(projected[0].apps, [app])
        XCTAssertEqual(projected[1].apps, [app], "An existing destination app must not gain a duplicate preview slot")
        XCTAssertEqual(projected[0].items, source.items, "The drag projection must not move real windows")
        XCTAssertEqual(projected[1].items, destination.items)
    }

    private func presentation() -> WorkspaceSidebarDockDragPresentation {
        .init(id: UUID(), windowId: 42, sourceWorkspaceName: "1", appId: app.id)
    }

    private func preview(newWorkspace: Bool = false) -> WorkspaceSidebarDropPreviewViewModel {
        .init(sourceWindowId: 42, label: "Document", appName: app.name, appBundleIdentifier: app.bundleId,
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
