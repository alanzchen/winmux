import Foundation

/// The tab order is a presentation of the saved workspace order: pins first, as they were
/// arranged, then complete groups at their first member. Removing a pin restores its old position.
func workspaceTabOrder<T>(_ tabs: [T], name: (T) -> String, isPinned: (T) -> Bool, pinOrder: (T) -> Int? = { _ in nil },
                         collections: [WorkspaceTabCollection]) -> [T] {
    // Arranged pins first; the rest keep their tab order after them.
    let pins = tabs.enumerated().filter { isPinned($0.element) }
        .sorted { (pinOrder($0.element) ?? .max, $0.offset) < (pinOrder($1.element) ?? .max, $1.offset) }
        .map(\.element)
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
    workspaceTabOrder(tabs, name: { $0.name }, isPinned: { $0.appearance.isFavorite }, pinOrder: { $0.appearance.pinOrder },
        collections: collections)
}

/// A project's pinned tabs, in the pinned tiles' order.
@MainActor
func workspacePinnedTabs(in projectId: WorkspaceProjectId) -> [Workspace] {
    let organization = workspaceSidebarOrganizationStore.state
    return workspaceTabOrder(orderedWorkspaces(in: projectId).filter { organization.workspaces[$0.name]?.isFavorite == true },
        name: { $0.name }, isPinned: { _ in true }, pinOrder: { organization.workspaces[$0.name]?.pinOrder }, collections: [])
}

/// The pins' names in order once `tab` goes beside another pin, or nil where that changes
/// nothing: beside itself, where it already is, or beside a tab that isn't pinned.
@MainActor
func workspacePinnedTabOrder(moving tab: Workspace, beside gap: WorkspaceSidebarTabGap) -> [String]? {
    let pins = workspacePinnedTabs(in: tab.projectId).map(\.name)
    var moved = pins.filter { $0 != tab.name }
    guard gap.workspaceName != tab.name, let index = moved.firstIndex(of: gap.workspaceName) else { return nil }
    moved.insert(tab.name, at: gap.isAfter ? index + 1 : index)
    return moved == pins ? nil : moved
}

@MainActor
func workspaceNavigationTabs(current: Workspace) -> [Workspace] {
    let tabs = orderedUserFacingWorkspaces(in: current.projectId, focusedWorkspace: current)
    guard config.usesBrowserTabs else { return tabs }
    let organization = workspaceSidebarOrganizationStore.state
    return workspaceTabOrder(tabs, name: { $0.name }, isPinned: { organization.workspaces[$0.name]?.isFavorite == true },
        pinOrder: { organization.workspaces[$0.name]?.pinOrder },
        collections: organization.collections.filter { $0.projectId == current.projectId })
}

@MainActor
func numberedWorkspaceNavigationTabs(current: Workspace) -> [Workspace] {
    config.usesBrowserTabs ? workspaceNavigationTabs(current: current) : scopedAutomaticDisplayWorkspaces(current: current)
}
