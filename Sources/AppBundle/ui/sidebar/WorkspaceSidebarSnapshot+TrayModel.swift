import Foundation

@MainActor
func workspaceSidebarSnapshot(from model: TrayMenuModel) -> WorkspaceSidebarSnapshot {
    let drag = model.workspaceSidebarDockDrag.flatMap {
        model.workspaceSidebarAppearance.showAppIcons && !$0.hasArrived(in: model.workspaceSidebarWorkspaces) ? $0 : nil
    }
    let preview = model.workspaceSidebarDropPreview ?? drag?.destination
    let workspaces = model.workspaceSidebarAppearance.showAppIcons
        ? workspaceSidebarDockDragWorkspaces(model.workspaceSidebarWorkspaces, drag: drag, preview: preview)
        : model.workspaceSidebarWorkspaces
    return WorkspaceSidebarSnapshot(
        workspaces: workspaces,
        projects: model.workspaceSidebarProjects,
        activeProjectId: model.workspaceSidebarActiveProjectId,
        monitorScopes: model.workspaceSidebarMonitorScopes,
        selectedMonitorScopeId: model.workspaceSidebarSelectedMonitorScopeId,
        targetMonitorScopeId: model.workspaceSidebarTargetMonitorScopeId,
        focusedMonitorScopeId: model.workspaceSidebarFocusedMonitorScopeId,
        visibleWidth: model.workspaceSidebarVisibleWidth,
        hoveredWorkspaceName: model.workspaceSidebarHoveredWorkspaceName,
        dropPreview: preview,
        configuration: model.workspaceSidebarAppearance,
        dockDrag: drag,
    )
}
