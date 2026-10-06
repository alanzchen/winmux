@MainActor
func orderedUserFacingWorkspaces(in scope: WorkspaceScope, focusedWorkspace: Workspace? = nil) -> [Workspace] {
    userFacingWorkspaces(orderedWorkspaces(in: scope), focusedWorkspace: focusedWorkspace)
}

@MainActor
func orderedUserFacingWorkspaces(in projectId: WorkspaceProjectId, focusedWorkspace: Workspace? = nil) -> [Workspace] {
    userFacingWorkspaces(orderedWorkspaces(in: projectId), focusedWorkspace: focusedWorkspace)
}

@MainActor
func workspaceHasSidebarVisibleWindows(_ workspace: Workspace) -> Bool {
    !workspace.rootTilingContainer.isEffectivelyEmpty ||
        !workspace.floatingWindows.isEmpty
}

@MainActor
func workspaceOwnedMinimizedWindows(_ workspace: Workspace) -> [Window] {
    macosMinimizedWindowsContainer.children.filterIsInstance(of: Window.self).filter {
        switch $0.layoutReason {
            case .macos(_, let prevWorkspaceName): prevWorkspaceName == workspace.name
            case .standard: false
        }
    }
}

@MainActor
func workspaceHasLifecycleWindows(_ workspace: Workspace) -> Bool {
    !workspace.isEffectivelyEmpty || !workspaceOwnedMinimizedWindows(workspace).isEmpty
}

/// Tabs mode: whether a tab is shown. The one rule for the list and everything that goes by it:
/// search, groups and their counts, drop targets, tab navigation and numbering, and the tab another
/// gives way to. A pin always is; any other tab only while a window belongs to it, which may be
/// minimized, hidden with its app or in native full screen. An empty one stays as it is, with all
/// that's saved about it, only unlisted: a new tab waiting for its window, a saved tab waiting for
/// its windows to come back, the tab left on screen when its last window went. It shows again as
/// soon as a window belongs to it.
@MainActor
func workspaceTabIsShown(_ tab: Workspace) -> Bool {
    !tab.isArchived && (workspaceSidebarOrganizationStore.state.workspaces[tab.name]?.isFavorite == true ||
        workspaceHasLifecycleWindows(tab))
}

@MainActor
func isUserFacingWorkspace(_ workspace: Workspace, focusedWorkspace: Workspace? = nil) -> Bool {
    !workspace.isArchived &&
        (
            workspaceHasSidebarVisibleWindows(workspace) ||
                workspace.isVisible ||
                workspace.retainsEmptyAfterProjectMove ||
                workspace.isKeptWhenEmpty ||
                !workspaceOwnedMinimizedWindows(workspace).isEmpty ||
                workspaceIsRetainedEmptySlot(workspace)
        )
}

@MainActor
func userFacingWorkspaces(_ workspaces: [Workspace], focusedWorkspace: Workspace? = nil) -> [Workspace] {
    workspaces.filter { isUserFacingWorkspace($0, focusedWorkspace: focusedWorkspace) }
}

@MainActor
func shouldShowWorkspaceInSidebar(_ workspace: Workspace, currentFocus: LiveFocus, isEditingWorkspace: Bool) -> Bool {
    isEditingWorkspace || isUserFacingWorkspace(workspace, focusedWorkspace: currentFocus.workspace)
}
