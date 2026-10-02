import AppKit

// Tabs mode: a pin is its project's, or in All Projects, shown in every project's sidebar. Moving a
// pin between the two keeps it pinned and keeps its tab, windows and display: it isn't unpinned and
// pinned again. A pin in All Projects keeps its own project as its home. One that comes back to a
// project's pins comes to the project the sidebar shows, as anything dropped there does.

/// The project the sidebar for `targetMonitorScopeId` shows; without one, the project `workspace`
/// is in as the sidebar shows it.
@MainActor
func workspaceSidebarContextProjectId(for workspace: Workspace, targetMonitorScopeId: String?) -> WorkspaceProjectId {
    targetMonitorScopeId.flatMap(workspaceSidebarMonitor(forScopeId:)).map(activeWorkspaceProjectId(for:))
        ?? workspaceContextProjectId(of: workspace)
}

/// Pins `workspace` among `scope`'s pins: those in All Projects, or `projectId`'s own, the project the
/// sidebar shows. A pin in All Projects that goes to the project's pins goes to that project's,
/// moving there from its home. `gap` puts it beside another pin there; otherwise it goes after the
/// arranged ones. The pins, the project move and its saved record change together, or not at all,
/// so one Undo puts everything back.
@MainActor
func setWorkspaceSidebarTabPinScope(_ workspace: Workspace, _ scope: WorkspaceSidebarPinScope?, projectId: WorkspaceProjectId,
                                    beside gap: WorkspaceSidebarTabGap? = nil) throws {
    guard config.usesBrowserTabs, Workspace.existing(byName: workspace.name) === workspace else { return }
    let store = workspaceSidebarOrganizationStore
    let appearance = store.state.workspaces[workspace.name] ?? .init()
    // Only a pin in All Projects changes project: any other tab is pinned in its own.
    let movesProject = scope == nil && workspace.projectId != projectId
    guard !movesProject || appearance.isPinnedInAllProjects else { return }
    guard !appearance.isFavorite || appearance.pinScope != scope || gap != nil else { return }
    if let reason = store.readOnlyReason { throw workspaceSidebarPinScopeError(reason) }
    let order = gap.flatMap {
        workspacePinnedTabOrder(moving: workspace, beside: $0, inAllProjects: scope == .allProjects, projectId: projectId)
    } ?? []
    try withWorkspaceSidebarDropTransaction {
        // Pinning saves the tab, which a failure further on takes back too.
        if !appearance.isFavorite { try saveWorkspaceSidebarIdentities([workspace]) }
        try store.update { state in
            state.workspaces[workspace.name, default: .init()].setPinScope(scope)
            // A pinned tab leaves its group, as pinning always has.
            for index in state.collections.indices { state.collections[index].workspaceNames.removeAll { $0 == workspace.name } }
            for (index, name) in order.enumerated() { state.workspaces[name, default: .init()].pinOrder = index }
        }
        guard movesProject else { return true }
        return moveWorkspaceToProject(workspaceName: workspace.name, projectId: projectId, syncsSavedRecord: true)
    }
}

/// Unpins `workspace`. A pin in All Projects becomes a tab of `projectId`, the project the sidebar
/// shows, where it's listed, rather than of its home, which would hide it from that sidebar.
@MainActor
func unpinWorkspaceSidebarTab(_ workspace: Workspace, into projectId: WorkspaceProjectId) throws {
    guard workspaceIsPinnedInAllProjects(workspace), workspace.projectId != projectId else {
        return try setWorkspaceSidebarTabFavorite(workspace, false)
    }
    try withWorkspaceSidebarDropTransaction {
        try setWorkspaceSidebarTabFavorite(workspace, false)
        return moveWorkspaceToProject(workspaceName: workspace.name, projectId: projectId, syncsSavedRecord: true)
    }
}

/// The title of the Undo for moving a pin to `scope`'s pins.
func workspaceSidebarPinScopeUndoTitle(_ scope: WorkspaceSidebarPinScope?) -> String {
    scope == .allProjects ? "Pin to All Projects" : "Pin to This Project"
}

private func workspaceSidebarPinScopeError(_ message: String) -> NSError {
    NSError(domain: "WinMux.SidebarOrganization", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}
