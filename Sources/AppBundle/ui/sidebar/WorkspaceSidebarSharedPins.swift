import Foundation

// Tabs mode: a project's pins are one collection, saved by tab name, in one order across every
// display (`workspacePinnedTabs(in:)`). Each display's list shows the tabs on that display, its
// pins among them. With shared pins it shows its project's pins from every display too, so every
// display has the same tiles in the same order. Nothing is kept per display: sharing changes only
// what a list shows, and each pin stays on the display it's on.

/// Whether a list of `selectedScopeId`'s tabs shows `workspace`: the tabs the scope selects, and,
/// with shared pins, every pinned tab when the scope is a display. All Displays already shows
/// every pin; Focused shows only the focused tab.
func workspaceSidebarTabIsListed(_ workspace: WorkspaceSidebarWorkspaceViewModel, selectedScopeId: String,
                                 focusedMonitorScopeId: String, sharesPinnedTabs: Bool) -> Bool {
    if sharesPinnedTabs, workspace.appearance.isFavorite, workspaceSidebarMonitorScopePoint(selectedScopeId) != nil {
        return true
    }
    return workspaceSidebarWorkspaceMatchesScope(workspace, selectedScopeId: selectedScopeId,
        focusedMonitorScopeId: focusedMonitorScopeId)
}

/// Tabs mode: what a list of `selectedScopeId`'s tabs shows, by project and in order: the pinned
/// tiles in the pins' order, then the other tabs, groups at their first member. Tabs left empty
/// aren't listed.
func workspaceSidebarTabsListedWorkspacesByProject(_ workspaces: [WorkspaceSidebarWorkspaceViewModel],
                                                   selectedScopeId: String, focusedMonitorScopeId: String,
                                                   collections: [WorkspaceTabCollection], sharesPinnedTabs: Bool)
    -> [WorkspaceProjectId: [WorkspaceSidebarWorkspaceViewModel]] {
    var result: [WorkspaceProjectId: [WorkspaceSidebarWorkspaceViewModel]] = [:]
    for workspace in workspaces where !workspace.isLeftEmpty && workspaceSidebarTabIsListed(workspace,
        selectedScopeId: selectedScopeId, focusedMonitorScopeId: focusedMonitorScopeId, sharesPinnedTabs: sharesPinnedTabs)
    {
        result[workspace.projectId, default: []].append(workspace)
    }
    return result.mapValues { workspaceSidebarOrderedTabs($0, collections: collections) }
}

/// One project's tabs as a list of `selectedScopeId`'s tabs shows them, pins first.
func workspaceSidebarTabsListedWorkspaces(_ workspaces: [WorkspaceSidebarWorkspaceViewModel], projectId: WorkspaceProjectId,
                                          selectedScopeId: String, focusedMonitorScopeId: String,
                                          collections: [WorkspaceTabCollection], sharesPinnedTabs: Bool)
    -> [WorkspaceSidebarWorkspaceViewModel] {
    workspaceSidebarOrderedTabs(workspaces.filter {
        $0.projectId == projectId && !$0.isLeftEmpty && workspaceSidebarTabIsListed($0, selectedScopeId: selectedScopeId,
            focusedMonitorScopeId: focusedMonitorScopeId, sharesPinnedTabs: sharesPinnedTabs)
    }, collections: collections)
}

/// The pinned tiles a list of `selectedScopeId`'s tabs shows for `projectId`, in order.
func workspaceSidebarTabsPinnedWorkspaces(_ workspaces: [WorkspaceSidebarWorkspaceViewModel], projectId: WorkspaceProjectId,
                                          selectedScopeId: String, focusedMonitorScopeId: String,
                                          collections: [WorkspaceTabCollection], sharesPinnedTabs: Bool)
    -> [WorkspaceSidebarWorkspaceViewModel] {
    workspaceSidebarTabsListedWorkspaces(workspaces, projectId: projectId, selectedScopeId: selectedScopeId,
        focusedMonitorScopeId: focusedMonitorScopeId, collections: collections, sharesPinnedTabs: sharesPinnedTabs)
        .filter(\.appearance.isFavorite)
}

extension WorkspaceSidebarSnapshot {
    /// The Tabs list this snapshot shows, from its own display scope and settings.
    var tabsListedWorkspacesByProject: [WorkspaceProjectId: [WorkspaceSidebarWorkspaceViewModel]] {
        workspaceSidebarTabsListedWorkspacesByProject(workspaces, selectedScopeId: selectedMonitorScopeId,
            focusedMonitorScopeId: focusedMonitorScopeId, collections: configuration.tabCollections,
            sharesPinnedTabs: configuration.sharesPinnedTabs)
    }

    /// One project's tabs as this snapshot lists them, pins first.
    func tabsListedWorkspaces(for projectId: WorkspaceProjectId) -> [WorkspaceSidebarWorkspaceViewModel] {
        workspaceSidebarTabsListedWorkspaces(workspaces, projectId: projectId, selectedScopeId: selectedMonitorScopeId,
            focusedMonitorScopeId: focusedMonitorScopeId, collections: configuration.tabCollections,
            sharesPinnedTabs: configuration.sharesPinnedTabs)
    }

    /// The pinned tiles this snapshot shows for `projectId`. A snapshot made for another display
    /// names that display's project: its own `activeProjectId` may be another display's.
    func tabsPinnedWorkspaces(for projectId: WorkspaceProjectId) -> [WorkspaceSidebarWorkspaceViewModel] {
        tabsListedWorkspaces(for: projectId).filter(\.appearance.isFavorite)
    }
}
