import Foundation

/// Reassign the workspace itself, preserving its identity, tree, focus and display.
/// `syncsSavedRecord` writes its saved record's project now rather than at the next checkpoint,
/// so an Undo taken right after the move still matches what's saved.
@MainActor
@discardableResult
func moveWorkspaceToProject(workspaceName: String, projectId: WorkspaceProjectId, syncsSavedRecord: Bool = false) -> Bool {
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
    // A pin in All Projects that only changes its home stays remembered wherever it was shown.
    for (viewportId, var viewport) in winMuxWorkspaceState.monitorViewportsById where !workspaceIsPinnedInAllProjects(workspace) {
        viewport.lastActiveWorkspaceByProject = viewport.lastActiveWorkspaceByProject.filter { project, id in
            id != workspace.id || project == projectId
        }
        if viewport.activeWorkspaceId == workspace.id {
            viewport.lastActiveWorkspaceByProject[projectId] = workspace.id
            viewport.contextProjectId = projectId
        }
        winMuxWorkspaceState.monitorViewportsById[viewportId] = viewport
    }
    ensureMinimumWorkspace(for: sourceProjectId, monitor: monitor)
    if syncsSavedRecord { syncSavedWorkspaceRecordProject(workspace) }
    checkWorkspaceHierarchyInvariants()
    return true
}

/// Writes now what the next checkpoint would: the saved record's project, and the records in the
/// order the tabs are presented in. An Undo taken right after a move then still matches what's
/// saved once that checkpoint runs.
@MainActor
func syncSavedWorkspaceRecordProject(_ workspace: Workspace) {
    guard !savedWorkspaceStore.isReadOnly, let record = savedWorkspaceStore.record(named: workspace.name),
          savedWorkspaceProjectSyncAllowed(workspace, record: record) else { return }
    savedWorkspaceStore.update(named: workspace.name) { $0.projectId = workspace.projectId }
    savedWorkspaceStore.reorder(workspaceNamesInOrder: orderedWorkspacesForPresentation().map(\.name))
    savedWorkspaceStore.flushNow()
}
