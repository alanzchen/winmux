@MainActor
func automaticWorkspaceDisplayIndex(_ workspace: Workspace, focusedWorkspace: Workspace?) -> Int? {
    if config.usesBrowserTabs {
        return workspaceNavigationTabs(current: workspace).firstIndex(of: workspace).map { $0 + 1 }
    }
    return orderedWorkspacesForPresentation()
        .filter { $0.projectId == workspace.projectId }
        .filter { userFacingWorkspaces([$0], focusedWorkspace: focusedWorkspace).contains($0) }
        .filter(\.usesAutomaticDisplayName)
        .firstIndex(of: workspace)
        .map { $0 + 1 }
}

func automaticWorkspaceDisplayIndexFallback(_ workspaceName: String) -> Int? {
    sidebarDraftWorkspaceIndex(workspaceName) ?? automaticWorkspaceIndex(workspaceName)
}

@MainActor
func scopedAutomaticDisplayWorkspaces(current: Workspace) -> [Workspace] {
    orderedWorkspacesForPresentation()
        .filter { $0.projectId == current.projectId }
        .filter { userFacingWorkspaces([$0], focusedWorkspace: current).contains($0) }
        .filter(\.usesAutomaticDisplayName)
}

@MainActor
func createAdjacentTransientBlankWorkspaceIfAllowed(named workspaceName: String, from current: Workspace) -> Workspace? {
    guard let targetIndex = parsePositiveWorkspaceDisplayIndex(workspaceName) else {
        return nil
    }
    let automaticDisplayWorkspaces = numberedWorkspaceNavigationTabs(current: current)
    guard targetIndex == automaticDisplayWorkspaces.count + 1 else { return nil }
    if let lastWorkspace = automaticDisplayWorkspaces.last,
       automaticDisplayWorkspaces.count > 1,
       lastWorkspace.isOrdinaryEmptySlot {
        return nil
    }

    // From a pin in All Projects, the project its display is in.
    let projectId = workspaceContextProjectId(of: current)
    let workspace = Workspace.get(byName: nextSidebarCreatedWorkspaceName(projectId: projectId, monitor: current.workspaceMonitor))
    workspace.markAsTransientBlank()
    workspace.assignProject(projectId)
    return workspace
}
