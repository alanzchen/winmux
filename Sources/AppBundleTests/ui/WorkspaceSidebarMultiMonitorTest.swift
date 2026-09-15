import AppKit
@testable import AppBundle
import SwiftUI
import XCTest

@MainActor
final class WorkspaceSidebarMultiMonitorTest: XCTestCase {
    func testCompactSelectorRequiresMultiplePhysicalDisplays() {
        var snapshot = WorkspaceSidebarSnapshot.empty
        snapshot.monitorScopes = [scope("default"), scope("focused"), scope("monitor:0.0,0.0")]
        XCTAssertFalse(WorkspaceSidebarView(snapshot: snapshot).shouldShowCompactMonitorSelector)

        snapshot.monitorScopes.append(scope("monitor:1920.0,0.0"))
        XCTAssertTrue(WorkspaceSidebarView(snapshot: snapshot).shouldShowCompactMonitorSelector)

        snapshot.monitorScopes.append(scope("monitor:3840.0,0.0"))
        XCTAssertTrue(WorkspaceSidebarView(snapshot: snapshot).shouldShowCompactMonitorSelector)
        snapshot.monitorScopes.removeAll { $0.id == "monitor:1920.0,0.0" }
        XCTAssertTrue(WorkspaceSidebarView(snapshot: snapshot).shouldShowCompactMonitorSelector)
        snapshot.monitorScopes.removeAll { $0.id == "monitor:3840.0,0.0" }
        XCTAssertFalse(WorkspaceSidebarView(snapshot: snapshot).shouldShowCompactMonitorSelector)
    }

    func testCompactMenuChangesOnlyItsPanelFilterAndHandlesDisconnectedSelection() {
        let primary = TrayMenuModel()
        let secondary = TrayMenuModel()
        let scopes = [scope("default"), scope("focused"), scope("monitor:0.0,0.0"), scope("monitor:1920.0,0.0"), scope("monitor:3840.0,0.0")]
        primary.workspaceSidebarMonitorScopes = scopes
        secondary.workspaceSidebarMonitorScopes = scopes
        let actions = makeWorkspaceSidebarActionsAdapter(viewModel: primary)
        let menu = WorkspaceSidebarCompactMonitorSelector(
            scopes: scopes,
            selectedScopeId: primary.workspaceSidebarSelectedMonitorScopeId,
            sectionWidth: 16,
            onSelectScope: { actions.send(.selectMonitorScope($0)) },
        )

        menu.onSelectScope("monitor:1920.0,0.0")
        XCTAssertEqual(primary.workspaceSidebarSelectedMonitorScopeId, "monitor:1920.0,0.0")
        XCTAssertEqual(secondary.workspaceSidebarSelectedMonitorScopeId, workspaceSidebarDefaultScopeId)
        menu.onSelectScope("monitor:3840.0,0.0")
        XCTAssertEqual(primary.workspaceSidebarSelectedMonitorScopeId, "monitor:3840.0,0.0")
        XCTAssertEqual(secondary.workspaceSidebarSelectedMonitorScopeId, workspaceSidebarDefaultScopeId)

        let disconnectedMenu = WorkspaceSidebarCompactMonitorSelector(
            scopes: Array(scopes.dropLast()),
            selectedScopeId: primary.workspaceSidebarSelectedMonitorScopeId,
            sectionWidth: 16,
            onSelectScope: menu.onSelectScope,
        )
        XCTAssertEqual(disconnectedMenu.selectedScope?.id, workspaceSidebarDefaultScopeId)
    }

    func testCompactOccupiedWorkspaceExpandsBeforeExplicitOverride() {
        resetWorkspaceSidebarItemDrag()
        var pending: String?
        var sent: [WorkspaceSidebarAction] = []
        let binding = Binding(get: { pending }, set: { pending = $0 })
        let actions = WorkspaceSidebarActions(send: { sent.append($0) })
        let compact = section(progress: 0, pending: binding, actions: actions)

        compact.handleSectionClick()
        XCTAssertEqual(pending, "other")
        XCTAssertEqual(sent, [.expandForWorkspaceOverride])
        XCTAssertFalse(compact.showsInUseOverride)
        compact.commitWorkspaceOverride()
        XCTAssertEqual(sent, [.expandForWorkspaceOverride])

        let expanding = section(progress: 0.9, pending: binding, actions: actions)
        XCTAssertFalse(expanding.showsInUseOverride)
        let expanded = section(progress: 1, pending: binding, actions: actions)
        XCTAssertTrue(expanded.showsInUseOverride)
        XCTAssertEqual(expanded.sectionMinHeight, workspaceSidebarInUseOverrideEmptySectionMinHeight)
        expanded.commitWorkspaceOverride()
        XCTAssertNil(pending)
        XCTAssertEqual(sent, [.expandForWorkspaceOverride, .overrideWorkspaceInUse("other")])
    }

    func testExpandedWarningDoesNotExpandAgainAndStaleWarningCannotOverride() {
        resetWorkspaceSidebarItemDrag()
        var pending: String?
        var sent: [WorkspaceSidebarAction] = []
        let binding = Binding(get: { pending }, set: { pending = $0 })
        let actions = WorkspaceSidebarActions(send: { sent.append($0) })
        section(progress: 1, pending: binding, actions: actions).handleSectionClick()
        XCTAssertEqual(pending, "other")
        XCTAssertTrue(sent.isEmpty)

        let noLongerOccupied = section(progress: 1, isInUse: false, pending: binding, actions: actions)
        XCTAssertFalse(noLongerOccupied.showsInUseOverride)
        noLongerOccupied.commitWorkspaceOverride()
        XCTAssertTrue(sent.isEmpty)

        let cancelled = section(progress: 1, pending: binding, actions: actions)
        cancelled.cancelWorkspaceOverride()
        XCTAssertNil(pending)
        XCTAssertFalse(cancelled.showsInUseOverride)
        cancelled.commitWorkspaceOverride()
        XCTAssertTrue(sent.isEmpty)
    }

    func testWorkspaceDragDoesNotOpenOccupiedWarning() {
        resetWorkspaceSidebarItemDrag()
        beginWorkspaceSidebarItemDrag()
        defer { resetWorkspaceSidebarItemDrag() }
        var pending: String?
        var sent: [WorkspaceSidebarAction] = []
        section(
            progress: 0,
            pending: Binding(get: { pending }, set: { pending = $0 }),
            actions: WorkspaceSidebarActions(send: { sent.append($0) }),
        ).handleSectionClick()
        XCTAssertNil(pending)
        XCTAssertTrue(sent.isEmpty)
    }

    private func scope(_ id: String) -> WorkspaceSidebarMonitorScopeViewModel {
        WorkspaceSidebarMonitorScopeViewModel(
            id: id,
            displayName: id,
            subtitle: nil,
            systemImageName: id == workspaceSidebarFocusedScopeId ? "scope" : "display",
            isFocusedMonitor: false,
        )
    }

    private func section(
        progress: CGFloat,
        isInUse: Bool = true,
        pending: Binding<String?>,
        actions: WorkspaceSidebarActions,
    ) -> WorkspaceSidebarWorkspaceSection {
        var layout = WorkspaceSidebarConfiguration.empty
        layout.collapsedWidth = 28
        layout.expandedWidth = 240
        return WorkspaceSidebarWorkspaceSection(
            workspace: WorkspaceSidebarWorkspaceViewModel(
                name: "other",
                projectId: workspaceProjectDefaultId,
                displayName: "Other workspace",
                sidebarLabel: "Other workspace",
                isGeneratedName: false,
                monitorScopeId: "monitor:1920.0,0.0",
                monitorName: "External display with a long descriptive name",
                isFocused: false,
                isVisible: isInUse,
                items: [],
            ),
            dragPreview: nil,
            expansionProgress: progress,
            layout: layout,
            emitsDropTarget: false,
            isFromOtherDisplay: false,
            isInUseOnOtherDisplay: isInUse,
            isOnFocusedMonitor: false,
            allowsWorkspaceActivation: true,
            isPinnedActiveWorkspace: false,
            isActiveOnTargetMonitor: false,
            projectContextLabel: nil,
            projectContextColor: nil,
            renamingWorkspaceName: .constant(nil),
            renamingWorkspaceText: .constant(""),
            onBeginRenameWorkspace: {},
            onCommitRenameWorkspace: {},
            onCancelRenameWorkspace: {},
            selectedSearchTarget: nil,
            isSearchFiltering: false,
            activeInUseOverrideWorkspaceName: pending,
            actions: actions,
        )
    }
}
