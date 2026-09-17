import Foundation

@MainActor
func workspaceSidebarSnapshot(from model: TrayMenuModel) -> WorkspaceSidebarSnapshot {
    let drag = model.workspaceSidebarDockDrag.flatMap {
        model.workspaceSidebarAppearance.showAppIcons && !$0.hasArrived(in: model.workspaceSidebarWorkspaces) ? $0 : nil
    }
    return WorkspaceSidebarSnapshot(
        workspaces: model.workspaceSidebarWorkspaces,
        projects: model.workspaceSidebarProjects,
        activeProjectId: model.workspaceSidebarActiveProjectId,
        monitorScopes: model.workspaceSidebarMonitorScopes,
        selectedMonitorScopeId: model.workspaceSidebarSelectedMonitorScopeId,
        targetMonitorScopeId: model.workspaceSidebarTargetMonitorScopeId,
        focusedMonitorScopeId: model.workspaceSidebarFocusedMonitorScopeId,
        visibleWidth: model.workspaceSidebarVisibleWidth,
        hoveredWorkspaceName: model.workspaceSidebarHoveredWorkspaceName,
        dropPreview: model.workspaceSidebarDropPreview ?? drag?.destination,
        configuration: model.workspaceSidebarAppearance,
        dockDrag: drag,
    )
}
