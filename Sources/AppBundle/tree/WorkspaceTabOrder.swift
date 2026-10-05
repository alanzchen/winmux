import Foundation

/// The tab order is a presentation of the saved workspace order: pins first, as they were
/// arranged, then complete groups at their first member. Removing a pin restores its old position.
/// Pins in All Projects lead, each pin arranged among its own kind.
func workspaceTabOrder<T>(_ tabs: [T], name: (T) -> String, isPinned: (T) -> Bool, pinOrder: (T) -> Int? = { _ in nil },
                         isPinnedInAllProjects: (T) -> Bool = { _ in false },
                         collections: [WorkspaceTabCollection]) -> [T] {
    // Arranged pins first; the rest keep their tab order after them.
    func key(_ pin: (offset: Int, element: T)) -> (Int, Int, Int) {
        (isPinnedInAllProjects(pin.element) ? 0 : 1, pinOrder(pin.element) ?? .max, pin.offset)
    }
    let pins = tabs.enumerated().filter { isPinned($0.element) }
        .sorted { key($0) < key($1) }
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
        isPinnedInAllProjects: { $0.appearance.isPinnedInAllProjects }, collections: collections)
}

/// A project's own pinned tabs, in the pinned tiles' order. Its pins in All Projects are among
/// those instead.
@MainActor
func workspacePinnedTabs(in projectId: WorkspaceProjectId) -> [Workspace] {
    let organization = workspaceSidebarOrganizationStore.state
    return workspaceTabOrder(orderedWorkspaces(in: projectId).filter {
        organization.workspaces[$0.name]?.isFavorite == true && !workspaceIsPinnedInAllProjects($0)
    }, name: { $0.name }, isPinned: { _ in true }, pinOrder: { organization.workspaces[$0.name]?.pinOrder }, collections: [])
}

/// The pins in All Projects, in their tiles' order: as arranged, then the rest in project and tab order.
@MainActor
func workspacePinnedTabsInAllProjects() -> [Workspace] {
    let organization = workspaceSidebarOrganizationStore.state
    guard config.usesBrowserTabs, organization.workspaces.values.contains(where: \.isPinnedInAllProjects) else { return [] }
    let projects = workspaceProjectsInDisplayOrder(Array(winMuxWorkspaceState.projectsById.values),
        configuredOrder: config.workspaceSidebar.projectOrder)
    return workspaceTabOrder(projects.flatMap { orderedWorkspaces(in: $0.id) }.filter(workspaceIsPinnedInAllProjects),
        name: { $0.name }, isPinned: { _ in true }, pinOrder: { organization.workspaces[$0.name]?.pinOrder }, collections: [])
}

/// The pins' names in order once `tab` goes beside another pin, or nil where that changes
/// nothing: beside itself, where it already is, or beside a tab that isn't pinned. It goes among
/// the pins in All Projects, or `projectId`'s, its own by default, as `inAllProjects` says, by
/// default those it's among; beside a pin of the other kind it goes nowhere.
@MainActor
func workspacePinnedTabOrder(moving tab: Workspace, beside gap: WorkspaceSidebarTabGap, inAllProjects: Bool? = nil,
                             projectId: WorkspaceProjectId? = nil) -> [String]? {
    let inAllProjects = inAllProjects ?? workspaceIsPinnedInAllProjects(tab)
    let pins = (inAllProjects ? workspacePinnedTabsInAllProjects() : workspacePinnedTabs(in: projectId ?? tab.projectId))
        .map(\.name)
    var moved = pins.filter { $0 != tab.name }
    guard gap.workspaceName != tab.name, let index = moved.firstIndex(of: gap.workspaceName) else { return nil }
    moved.insert(tab.name, at: gap.isAfter ? index + 1 : index)
    return moved == pins ? nil : moved
}

/// Tabs mode: the tabs in the order the sidebar shows them, from `current`'s project as the user
/// sees it: the pins in All Projects, the project's own pins, then its other tabs.
@MainActor
func workspaceNavigationTabs(current: Workspace) -> [Workspace] {
    let projectId = workspaceContextProjectId(of: current)
    let tabs = orderedUserFacingWorkspaces(in: projectId, focusedWorkspace: current)
    guard config.usesBrowserTabs else { return tabs }
    let pinnedEverywhere = userFacingWorkspaces(workspacePinnedTabsInAllProjects(), focusedWorkspace: current)
    return workspaceTabsInSidebarOrder(pinnedEverywhere + tabs.filter { !workspaceIsPinnedInAllProjects($0) }, projectId: projectId)
}

/// The tabs `anchor`'s display lists, with `anchor` wherever it is, in the order that display's
/// sidebar shows them: those of the project the display is in, and with `includingPinsInAllProjects`
/// the pins in All Projects. Filtered to what the display lists before grouping, as the sidebar is, so
/// a group split across displays, or with a member out of the list, keeps the order shown.
@MainActor
func workspaceDisplayTabsInSidebarOrder(around anchor: Workspace, includingPinsInAllProjects: Bool,
                                        isListed: (Workspace) -> Bool) -> [Workspace] {
    let projectId = workspaceContextProjectId(of: anchor)
    let pinsInAllProjects = includingPinsInAllProjects ? workspacePinnedTabsInAllProjects() : []
    let tabs = pinsInAllProjects + orderedWorkspaces(in: projectId).filter { !workspaceIsPinnedInAllProjects($0) }
    return workspaceTabsInSidebarOrder(tabs.filter { $0 === anchor || isListed($0) && workspaceTabIsListedInSidebar($0) },
        projectId: projectId)
}

/// Whether the Tabs list shows `tab`: it has a sidebar row, and isn't left empty.
@MainActor
func workspaceTabIsListedInSidebar(_ tab: Workspace) -> Bool {
    workspaceSidebarHasRow(tab, focusedWorkspace: focus.workspace) && !workspaceTabWasLeftEmpty(tab)
}

/// `projectId`'s `tabs` in the order its sidebar shows them: pins first, then each group together.
@MainActor
func workspaceTabsInSidebarOrder(_ tabs: [Workspace], projectId: WorkspaceProjectId) -> [Workspace] {
    guard config.usesBrowserTabs else { return tabs }
    let organization = workspaceSidebarOrganizationStore.state
    return workspaceTabOrder(tabs, name: { $0.name },
        isPinned: { organization.workspaces[$0.name]?.isFavorite == true },
        pinOrder: { organization.workspaces[$0.name]?.pinOrder }, isPinnedInAllProjects: workspaceIsPinnedInAllProjects,
        collections: organization.collections.filter { $0.projectId == projectId })
}

@MainActor
func numberedWorkspaceNavigationTabs(current: Workspace) -> [Workspace] {
    config.usesBrowserTabs ? workspaceNavigationTabs(current: current) : scopedAutomaticDisplayWorkspaces(current: current)
}
