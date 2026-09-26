import Foundation

/// Reassign the workspace itself, preserving its identity, tree, focus and display.
@MainActor
@discardableResult
func moveWorkspaceToProject(workspaceName: String, projectId: WorkspaceProjectId) -> Bool {
    guard let workspace = Workspace.existing(byName: workspaceName),
          !workspace.isArchived,
          workspace.projectId != projectId,
          winMuxWorkspaceState.projectsById[projectId] != nil
    else { return false }

    let sourceProjectId = workspace.projectId
    let monitor = workspace.workspaceMonitor
    workspace.retainsEmptyAfterProjectMove = !workspaceHasLifecycleWindows(workspace) && !workspace.isVisible
    if let group = workspaceSidebarOrganizationStore.collection(containing: workspaceName), group.projectId != projectId {
        do { try workspaceSidebarOrganizationStore.assign(workspaceName, projectId: sourceProjectId, to: nil) }
        catch { showWorkspaceSidebarError(error.localizedDescription); return false }
    }
    workspace.assignProject(projectId)
    for (viewportId, var viewport) in winMuxWorkspaceState.monitorViewportsById {
        viewport.lastActiveWorkspaceByProject = viewport.lastActiveWorkspaceByProject.filter { project, id in
            id != workspace.id || project == projectId
        }
        if viewport.activeWorkspaceId == workspace.id {
            viewport.lastActiveWorkspaceByProject[projectId] = workspace.id
        }
        winMuxWorkspaceState.monitorViewportsById[viewportId] = viewport
    }
    ensureMinimumWorkspace(for: sourceProjectId, monitor: monitor)
    checkWorkspaceHierarchyInvariants()
    return true
}
