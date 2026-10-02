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

/// The title of the Undo for moving several chosen tabs to `scope`'s pins.
func workspaceSidebarTabsPinScopeUndoTitle(_ scope: WorkspaceSidebarPinScope?) -> String {
    scope == .allProjects ? "Pin Tabs to All Projects" : "Pin Tabs to This Project"
}

private func workspaceSidebarPinScopeError(_ message: String) -> NSError {
    NSError(domain: "WinMux.SidebarOrganization", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

/// The pins in `section` that a list of `projectId` shows, in their tiles' order.
@MainActor
func workspaceSidebarPinnedTabs(in section: WorkspaceSidebarPinSection, of projectId: WorkspaceProjectId) -> [Workspace] {
    section == .allProjects ? workspacePinnedTabsInAllProjects() : workspacePinnedTabs(in: projectId)
}

/// Several chosen tabs pinned among `scope`'s pins at once, after those arranged there, in their
/// order: those in All Projects, or `projectId`'s, the project the sidebar shows, which pins back
/// from All Projects come to. One write of the pins, with the project moves: all or nothing.
@MainActor
func setWorkspaceSidebarTabsPinScope(_ workspaces: [Workspace], _ scope: WorkspaceSidebarPinScope?,
                                     projectId: WorkspaceProjectId) throws {
    guard config.usesBrowserTabs else { return }
    let store = workspaceSidebarOrganizationStore
    // Only tabs the sidebar lists there: its own, and pins in All Projects.
    let tabs = workspaces.filter { Workspace.existing(byName: $0.name) === $0 && workspaceIsListed($0, inProject: projectId) }
    let changing = tabs.filter { store.state.workspaces[$0.name].map { !$0.isFavorite || $0.pinScope != scope } ?? true }
    guard !changing.isEmpty else { return }
    if let reason = store.readOnlyReason { throw workspaceSidebarPinScopeError(reason) }
    let section = WorkspaceSidebarPinSection(scope)
    let names = changing.map(\.name)
    let order = workspaceSidebarPinnedTabs(in: section, of: projectId).map(\.name).filter { !names.contains($0) } + names
    try withWorkspaceSidebarDropTransaction {
        try saveWorkspaceSidebarIdentities(changing.filter { store.state.workspaces[$0.name]?.isFavorite != true })
        try store.update { state in
            for name in names { state.workspaces[name, default: .init()].setPinScope(scope) }
            for index in state.collections.indices { state.collections[index].workspaceNames.removeAll(where: names.contains) }
            for (index, name) in order.enumerated() { state.workspaces[name, default: .init()].pinOrder = index }
        }
        guard scope == nil else { return true }
        for tab in changing where tab.projectId != projectId {
            guard moveWorkspaceToProject(workspaceName: tab.name, projectId: projectId, syncsSavedRecord: true) else { return false }
        }
        return true
    }
}

/// Unpins several tabs at once. Pins in All Projects become tabs of `projectId`, the project the
/// sidebar shows, where they're listed. One write, with the project moves: all or nothing.
@MainActor
func unpinWorkspaceSidebarTabs(_ workspaces: [Workspace], into projectId: WorkspaceProjectId) throws {
    let moving = workspaces.filter { workspaceIsPinnedInAllProjects($0) && $0.projectId != projectId }
    guard !moving.isEmpty else { return try setWorkspaceSidebarTabsFavorite(workspaces, false) }
    try withWorkspaceSidebarDropTransaction {
        try setWorkspaceSidebarTabsFavorite(workspaces, false)
        for tab in moving {
            guard moveWorkspaceToProject(workspaceName: tab.name, projectId: projectId, syncsSavedRecord: true) else { return false }
        }
        return true
    }
}
