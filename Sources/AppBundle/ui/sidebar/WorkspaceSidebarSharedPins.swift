import Foundation

// Tabs mode: a project's pins are one collection, saved by tab name, in one order across every
// display (`workspacePinnedTabs(in:)`). Each display's list shows the tabs on that display, its
// pins among them. With shared pins it shows its project's pins from every display too, so every
// display has the same tiles in the same order. Nothing is kept per display: sharing changes only
// what a list shows. Showing a pin moves nothing; clicking one brings it to the display clicked.

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

/// Where a shared pin is, for a badge on its tile, when that's another display than the one the
/// list shows: on screen there, or kept there while hidden.
struct WorkspaceSidebarSharedPinLocation: Equatable {
    let displayName: String
    let isOnScreen: Bool
    /// False for one held to its display, which a click doesn't bring.
    var comesToClick = true

    /// "On" only for a pin on screen there; a hidden one is assigned there.
    var description: String {
        "\(isOnScreen ? "On" : "Assigned to") “\(displayName)”"
    }

    func help(clickMovesHere: Bool = true) -> String {
        clickMovesHere && comesToClick ? "\(description) · Click to move to this display" : description
    }
}

/// The badge a shared pin's tile shows in a list representing `representedMonitorScopeId`'s
/// display: its own panel's display, or the display a destination panel stands for. Nil for a pin
/// on that display, or whose display isn't known or is gone, and for one with no windows open,
/// which isn't anywhere yet.
func workspaceSidebarSharedPinLocation(_ workspace: WorkspaceSidebarWorkspaceViewModel, representedMonitorScopeId: String,
                                       sharesPinnedTabs: Bool) -> WorkspaceSidebarSharedPinLocation? {
    guard sharesPinnedTabs, workspace.appearance.isFavorite, let display = workspace.knownDisplay,
          workspaceSidebarMonitorScopePoint(representedMonitorScopeId) != nil,
          display.monitorScopeId != representedMonitorScopeId,
          workspace.isVisible || !workspaceSidebarPinnedTabWindows(workspace).isEmpty
    else { return nil }
    return .init(displayName: display.displayName, isOnScreen: workspace.isVisible,
        comesToClick: workspace.heldMonitorScopeId.map { $0 == representedMonitorScopeId } ?? true)
}

extension WorkspaceSidebarSnapshot {
    /// The badge a shared pin's tile shows in this list, which represents its target display.
    func sharedPinLocation(of workspace: WorkspaceSidebarWorkspaceViewModel) -> WorkspaceSidebarSharedPinLocation? {
        workspaceSidebarSharedPinLocation(workspace, representedMonitorScopeId: targetMonitorScopeId,
            sharesPinnedTabs: configuration.sharesPinnedTabs)
    }
}
