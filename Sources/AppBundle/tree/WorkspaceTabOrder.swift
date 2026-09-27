import Foundation

/// The tab order is a presentation of the saved workspace order: pins first, then
/// complete groups at their first member. Removing a pin restores its old position.
func workspaceTabOrder<T>(_ tabs: [T], name: (T) -> String, isPinned: (T) -> Bool,
                         collections: [WorkspaceTabCollection]) -> [T] {
    let pins = tabs.filter(isPinned)
    let ordinary = tabs.filter { !isPinned($0) }
    let groupByName = collections.reduce(into: [String: String]()) { result, group in
        for member in group.workspaceNames { result[member] = group.id }
    }
    var emitted: Set<String> = []
    return pins + ordinary.flatMap { tab -> [T] in
        guard let group = groupByName[name(tab)] else { return [tab] }
        guard emitted.insert(group).inserted else { return [] }
        return ordinary.filter { groupByName[name($0)] == group }
    }
}

func workspaceSidebarOrderedTabs(_ tabs: [WorkspaceSidebarWorkspaceViewModel],
                                 collections: [WorkspaceTabCollection]) -> [WorkspaceSidebarWorkspaceViewModel] {
    workspaceTabOrder(tabs, name: { $0.name }, isPinned: { $0.appearance.isFavorite }, collections: collections)
}

@MainActor
func workspaceNavigationTabs(current: Workspace) -> [Workspace] {
    let tabs = orderedUserFacingWorkspaces(in: current.projectId, focusedWorkspace: current)
    guard config.usesBrowserTabs else { return tabs }
    let organization = workspaceSidebarOrganizationStore.state
    return workspaceTabOrder(tabs, name: { $0.name }, isPinned: { organization.workspaces[$0.name]?.isFavorite == true },
        collections: organization.collections.filter { $0.projectId == current.projectId })
}

@MainActor
func numberedWorkspaceNavigationTabs(current: Workspace) -> [Workspace] {
    config.usesBrowserTabs ? workspaceNavigationTabs(current: current) : scopedAutomaticDisplayWorkspaces(current: current)
}
